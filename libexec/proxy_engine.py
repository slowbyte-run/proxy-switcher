#!/usr/bin/env python3
"""Shared snapshot / manifest / switch engine for proxy-switcher.

The engine owns everything that is the same for every carrier:

* resolve the carrier's file and read the bytes currently on disk;
* detect external edits by comparing against the hash of the last write;
* snapshot the original file before the first managed change;
* render the new bytes through the carrier and write them atomically;
* record original existence, original hash and written hash in the manifest.

Carriers only describe their path and how to render ``on`` / ``off``.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import stat
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime

from carriers import get as get_carrier
from proxy_common import JSON_SCHEMA, Action, State

MANIFEST_VERSION = 1

# How long a switch waits for a concurrent one before giving up. The whole
# read-modify-write transaction is covered, so a wedged process (or a slow
# niri reload) is what this bound protects against; normal contention is
# milliseconds. `PROXYSW_LOCK_TIMEOUT` overrides it for tests and scripts.
LOCK_TIMEOUT_SECONDS = 5.0
LOCK_TIMEOUT_VARIABLE = "PROXYSW_LOCK_TIMEOUT"


class EngineError(Exception):
    """A configuration or consistency problem the CLI reports with exit 1."""


class UsageError(EngineError):
    """A bad command line, reported with exit 2."""


@dataclass
class Context:
    home: str
    config_home: str
    state_root: str
    endpoint: str
    no_proxy: str
    excluded: frozenset[str] = frozenset()
    force: bool = False
    dry_run: bool = False
    verbose: bool = False
    json: bool = False

    @property
    def manifest_path(self) -> str:
        return os.path.join(self.state_root, "manifest.json")

    def warn(self, message: str) -> None:
        print(f"proxysw: warning: {message}", file=sys.stderr)

    def info(self, message: str) -> None:
        """Progress detail about a carrier's file.

        It goes to stderr because stdout belongs to the command's result: a
        ``--json`` document must stay parseable even when a carrier creates a
        file or warns about the world outside it.
        """
        print(message, file=sys.stderr)

    def progress(self, message: str) -> None:
        """A human-facing result line.

        Silent under ``--json``: the document on stdout already carries the same
        facts, and a caller parsing it should not also have to drain prose.
        """
        if not self.json:
            print(message)


@dataclass
class Plan:
    name: str
    carrier: object
    path: str
    current: bytes | None
    current_hash: str | None
    mode: int | None
    entry: dict | None
    wanted: bytes | None
    changed: bool
    original_existed: bool
    warning: str = ""
    # Filled in by ``_apply_plan`` once a real switch runs. A dry run never
    # reaches that function, so both stay false and the document says so.
    written: bool = False
    pending_reload: bool = False


def hash_bytes(data: bytes | None) -> str | None:
    if data is None:
        return None
    return "sha256:" + hashlib.sha256(data).hexdigest()


def read_bytes(path: str) -> bytes | None:
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise EngineError(f"cannot read {path}: {error.strerror}") from error


def file_mode(path: str) -> int | None:
    try:
        return stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise EngineError(f"cannot stat {path}: {error.strerror}") from error


def _fsync_directory(path: str) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write(path: str, data: bytes, mode: int) -> None:
    """Write ``data`` to ``path`` via a temporary file in the same directory."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{os.path.basename(path)}.proxy-", dir=directory
    )
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        _fsync_directory(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def remove_file(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        return
    _fsync_directory(os.path.dirname(path) or ".")


def load_manifest(context: Context) -> dict:
    try:
        with open(context.manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except FileNotFoundError:
        return {"version": MANIFEST_VERSION, "carriers": {}}
    except OSError as error:
        raise EngineError(
            f"cannot read manifest {context.manifest_path}: {error.strerror}"
        ) from error
    except json.JSONDecodeError as error:
        raise EngineError(
            f"manifest {context.manifest_path} is not valid JSON: {error}"
        ) from error

    if not isinstance(manifest, dict) or not isinstance(manifest.get("carriers"), dict):
        raise EngineError(f"manifest {context.manifest_path} has an unknown shape")
    version = manifest.setdefault("version", MANIFEST_VERSION)
    if not isinstance(version, int) or version < 1:
        raise EngineError(
            f"manifest {context.manifest_path} has an invalid version: {version!r}"
        )
    if version > MANIFEST_VERSION:
        # A newer release wrote this file. Refusing beats silently dropping the
        # fields this build does not know about when it writes the manifest back.
        raise EngineError(
            f"manifest {context.manifest_path} was written by a newer "
            f"proxy-switcher (version {version}, this build understands "
            f"{MANIFEST_VERSION}); upgrade proxy-switcher"
        )
    return manifest


def save_manifest(context: Context, manifest: dict) -> None:
    os.makedirs(context.state_root, mode=0o700, exist_ok=True)
    payload = json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True)
    atomic_write(context.manifest_path, (payload + "\n").encode(), 0o600)


def create_snapshot(
    context: Context, carrier, original: bytes | None
) -> tuple[str, str | None]:
    snapshots_dir = os.path.join(context.state_root, "snapshots")
    os.makedirs(snapshots_dir, mode=0o700, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    snapshot_dir = os.path.join(snapshots_dir, stamp)
    suffix = 1
    while os.path.exists(snapshot_dir):
        snapshot_dir = os.path.join(
            context.state_root, "snapshots", f"{stamp}-{suffix}"
        )
        suffix += 1
    os.makedirs(snapshot_dir, mode=0o700)

    snapshot_file = None
    if original is not None:
        snapshot_file = os.path.join(snapshot_dir, carrier.name)
        descriptor = os.open(snapshot_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(original)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(snapshot_file, 0o600)
    return snapshot_dir, snapshot_file


def _timestamp() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _original_region_existed(carrier, current: bytes | None) -> bool:
    if current is None:
        return False
    if carrier.region_exists is None:
        return True
    return carrier.region_exists(current.decode("utf-8"))


def select_carriers(context: Context, names: list[str]) -> tuple[list[str], list[str]]:
    """Validate names and drop excluded carriers, preserving the given order."""
    selected: list[str] = []
    skipped: list[str] = []
    seen: set[str] = set()

    for name in names:
        if name in seen:
            continue
        seen.add(name)

        carrier = get_carrier(name)
        if carrier is None:
            raise UsageError(f"unknown carrier: {name}")
        if not carrier.managed:
            raise UsageError(f"carrier {name} is read-only and cannot be switched")

        if name in context.excluded:
            skipped.append(name)
        else:
            selected.append(name)

    return selected, skipped


def resolve_action(context: Context, action: Action, selected: list[str]) -> Action:
    if action is not Action.TOGGLE:
        return action
    states = []
    for name in selected:
        carrier = get_carrier(name)
        states.append(carrier.read_state(carrier.resolve(context)))
    # Any carrier that is not fully on means "turn everything on".
    if all(state == State.ON for state in states):
        return Action.OFF
    return Action.ON


def _restore_bytes(name: str, entry: dict) -> bytes | None:
    if entry.get("original_hash") is None:
        return None
    snapshot = entry.get("snapshot")
    if not snapshot:
        raise EngineError(
            f"{name}: manifest has no snapshot to restore; "
            "remove the manifest entry and switch again"
        )
    data = read_bytes(snapshot)
    if data is None:
        raise EngineError(f"{name}: snapshot {snapshot} is missing")
    return data


def _target_bytes(
    carrier, entry: dict | None, current: bytes | None, context: Context, action: Action
) -> bytes | None:
    """Return the bytes the carrier wants on disk for this action."""
    if action is Action.RESTORE:
        if entry is None:
            raise EngineError("no snapshot to restore")
        return _restore_bytes(carrier.name, entry)

    text = "" if current is None else current.decode("utf-8")
    if action is Action.ON:
        return carrier.render_on(text, context).encode("utf-8")

    # Action.OFF: render the canonical no-proxy state. Never create a missing
    # file, and remove a managed region that ``on`` created in the first place.
    if current is None:
        return None
    if entry is not None:
        if entry.get("original_hash") is None:
            if carrier.delete_created_file:
                return None
            # Keep the shell rc: its explicit unsets override niri even though
            # ``on`` created the file.
            return carrier.render_off(text, context).encode("utf-8")
        remove_region = not entry.get("original_existed", True)
    else:
        remove_region = False
        if carrier.region_exists is not None and not carrier.region_exists(text):
            return current
    return carrier.render_off(text, context, remove_region=remove_region).encode(
        "utf-8"
    )


def _rendered_warning(carrier, wanted: bytes | None) -> str:
    """Ask the carrier whether the bytes it is about to write can work."""
    if carrier.check_rendered is None or wanted is None:
        return ""
    return carrier.check_rendered(wanted.decode("utf-8"))


def build_plans(
    context: Context,
    action: Action,
    selected: list[str],
    entries: dict,
    explicit: bool,
) -> tuple[list[Plan], list[tuple], list[tuple[str, str]], list[str]]:
    plans: list[Plan] = []
    conflicts: list[tuple] = []
    failures: list[tuple[str, str]] = []
    unstarted: list[str] = []

    for name in selected:
        carrier = get_carrier(name)
        try:
            path = carrier.resolve(context)
            current = read_bytes(path)
            current_hash = hash_bytes(current)
            mode = file_mode(path)
            entry = entries.get(name)
            expected = entry.get("written_hash") if entry else None

            if entry is not None and current_hash != expected:
                conflicts.append((name, path, expected, current_hash))

            if action is Action.RESTORE and entry is None:
                if explicit:
                    failures.append(
                        (name, "no snapshot to restore; nothing was changed")
                    )
                else:
                    unstarted.append(name)
                continue

            if entry is not None:
                original_existed = entry.get("original_existed", current is not None)
            else:
                original_existed = _original_region_existed(carrier, current)
            wanted = _target_bytes(carrier, entry, current, context, action)
            warning = _rendered_warning(carrier, wanted)
            if warning and not context.json:
                context.warn(f"{name}: {warning}")
        except UnicodeDecodeError as error:
            failures.append((name, f"{path} is not valid UTF-8: {error}"))
            continue
        except (EngineError, OSError) as error:
            failures.append((name, str(error)))
            continue

        plans.append(
            Plan(
                name=name,
                carrier=carrier,
                path=path,
                current=current,
                current_hash=current_hash,
                mode=mode,
                entry=entry,
                wanted=wanted,
                changed=wanted != current,
                original_existed=original_existed,
                warning=warning,
            )
        )

    return plans, conflicts, failures, unstarted


def report_failures(failures: list[tuple[str, str]]) -> None:
    for name, message in failures:
        print(f"proxysw: {name}: {message}", file=sys.stderr)


def report_conflicts(conflicts: list[tuple]) -> bool:
    """Print every conflict; return whether the caller may continue."""
    for name, path, expected, found in conflicts:
        print(
            f"proxysw: conflict: {name} at {path} changed since "
            "proxy-switcher last wrote it",
            file=sys.stderr,
        )
        print(
            f"proxysw:   expected {expected or 'the file to be absent'}",
            file=sys.stderr,
        )
        print(
            f"proxysw:   found    {found or 'the file to be absent'}",
            file=sys.stderr,
        )
    print(
        "proxysw: refusing to overwrite; review the file, then re-run with "
        "--force to replace it",
        file=sys.stderr,
    )
    return False


def _display_action(action: Action) -> str:
    if action is Action.RESTORE:
        return "restored"
    return action.value


def plan_document(
    context: Context,
    action: Action,
    plans: list[Plan],
    conflicts: list[tuple],
    failures: list[tuple[str, str]],
    skipped: list[str],
    unstarted: list[str],
) -> dict:
    """The machine-readable form of a switch.

    Carries the same decisions the human output prints, so a TUI, an fzf
    wrapper or a status-bar widget can preview or apply a switch without
    parsing text. ``dry_run`` says which of the two it was; every ``state`` is
    the state on disk when the command finished, and ``written`` and
    ``pending_reload`` report what this run actually did.
    """
    return {
        "schema": JSON_SCHEMA,
        "dry_run": context.dry_run,
        "action": action.value,
        "endpoint": context.endpoint,
        "no_proxy": context.no_proxy,
        "carriers": [
            {
                "name": plan.name,
                "path": plan.path,
                "state": plan.carrier.read_state(plan.path),
                "action": action.value,
                "changed": plan.changed,
                "written": plan.written,
                "pending_reload": plan.pending_reload,
                "exists": plan.current is not None,
                "warning": plan.warning,
            }
            for plan in plans
        ],
        "skipped": skipped,
        "unstarted": unstarted,
        "conflicts": [
            {
                "carrier": name,
                "path": path,
                "expected": expected,
                "found": found,
            }
            for name, path, expected, found in conflicts
        ],
        "failures": [{"carrier": name, "error": message} for name, message in failures],
    }


def emit_document(document: dict) -> None:
    """Print one JSON document on stdout, and nothing else."""
    print(json.dumps(document, ensure_ascii=False, indent=2))


def _write_mode(plan: Plan, action: Action) -> int:
    if action is Action.RESTORE:
        original = (plan.entry or {}).get("original_mode")
        if original is not None:
            return original
    return plan.mode if plan.mode is not None else plan.carrier.default_mode


def _apply_plan(context: Context, manifest: dict, action: Action, plan: Plan) -> bool:
    """Apply one plan and update the manifest in place. Returns whether it wrote."""
    entries = manifest["carriers"]
    entry = plan.entry
    new_entry = entry is None
    snapshot_file = None

    if new_entry:
        snapshot_dir, snapshot_file = create_snapshot(
            context, plan.carrier, plan.current
        )
        entry = {
            "state": action.value,
            "path": plan.path,
            "snapshot_dir": snapshot_dir,
            "snapshot": snapshot_file,
            "original_existed": plan.original_existed,
            "original_hash": plan.current_hash,
            "original_mode": plan.mode,
            "written_hash": None,
            "updated_at": _timestamp(),
        }
        entries[plan.name] = entry

    wrote = False
    if plan.changed:
        if plan.wanted is None:
            remove_file(plan.path)
        else:
            atomic_write(plan.path, plan.wanted, _write_mode(plan, action))
        wrote = True

    entry["state"] = plan.carrier.read_state(plan.path)
    entry["written_hash"] = hash_bytes(plan.wanted)
    if wrote:
        entry["updated_at"] = _timestamp()

    if context.verbose:
        if plan.changed:
            if plan.wanted is None:
                context.progress(f"proxysw: {plan.name}: removed {plan.path}")
            else:
                written = f"proxysw: {plan.name}: wrote {plan.path}"
                context.progress(f"{written} ({len(plan.wanted)} bytes)")
            if new_entry:
                if snapshot_file is None:
                    context.progress(
                        f"proxysw: {plan.name}: no snapshot (file was absent)"
                    )
                else:
                    context.progress(f"proxysw: {plan.name}: snapshot {snapshot_file}")
        else:
            context.progress(f"proxysw: {plan.name}: no change to {plan.path}")

    plan.written = wrote
    if wrote:
        context.progress(f"{plan.name}: {_display_action(action)}")
        if plan.carrier.after_write is not None:
            try:
                reloaded = plan.carrier.after_write(context)
            except Exception as error:  # noqa: BLE001 - report, do not abort
                context.warn(f"{plan.name}: post-write hook failed: {error}")
                reloaded = False
            plan.pending_reload = not reloaded
            entry["pending_reload"] = plan.pending_reload
    else:
        context.progress(f"{plan.name}: already {_display_action(action)}")

    return wrote or new_entry


def _lock_timeout() -> float:
    raw = os.environ.get(LOCK_TIMEOUT_VARIABLE, "")
    if not raw:
        return LOCK_TIMEOUT_SECONDS
    try:
        return max(0.0, float(raw))
    except ValueError:
        return LOCK_TIMEOUT_SECONDS


@contextmanager
def state_lock(context: Context):
    """Hold an exclusive lock for one read-modify-write transaction.

    The lock is taken *before* the manifest is read. A lock around
    ``save_manifest`` alone would not help: two processes could still plan
    against the same stale bytes and the later writer would silently win.

    The lock file lives outside ``state_root`` on purpose. It is runtime
    coordination, not durable state, and a switch that decides to write nothing
    (``restore`` with no snapshots) must leave the state directory untouched.

    ``flock`` releases on close, so the descriptor is the whole lifetime.
    """
    path = _lock_path(context)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + _lock_timeout()
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise EngineError(
                        f"another proxysw is switching carriers (lock: {path}); "
                        "wait for it to finish and try again"
                    ) from None
                time.sleep(0.05)
        yield
    finally:
        os.close(descriptor)


def _lock_dir() -> str:
    """Where lock files go: the runtime dir, falling back to the temp dir.

    ``$XDG_RUNTIME_DIR`` is cleared at logout, so a stale lock cannot outlive
    the session. It is not always usable, though: a container or a session
    manager that remounted ``/run`` leaves it read-only while still showing
    mode 0700, which ``os.access`` cannot detect. Creating a probe file is the
    only honest test, so each candidate is tried for real.

    Both candidates are per-user directories, and the temp-dir fallback keeps
    cron and CI working.
    """
    candidates = []
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if runtime and os.path.isabs(runtime):
        candidates.append(runtime)
    candidates.append(tempfile.gettempdir())

    for base in candidates:
        path = os.path.join(base, f"proxysw-{os.getuid()}")
        try:
            os.makedirs(path, mode=0o700, exist_ok=True)
            probe_descriptor, probe_path = tempfile.mkstemp(dir=path, prefix=".probe-")
        except OSError:
            continue
        os.close(probe_descriptor)
        os.unlink(probe_path)
        return path

    raise EngineError(
        "cannot create a lock directory in $XDG_RUNTIME_DIR or the temp "
        "directory; set XDG_RUNTIME_DIR to a writable directory"
    )


def _lock_path(context: Context) -> str:
    # One lock per state root: two checkouts with different XDG_STATE_HOME
    # never need to wait for each other.
    digest = hashlib.sha256(context.state_root.encode()).hexdigest()[:16]
    return os.path.join(_lock_dir(), f"state-{digest}.lock")


def switch(
    context: Context, action: Action, names: list[str], explicit: bool = True
) -> int:
    selected, skipped = select_carriers(context, names)
    for name in skipped:
        context.progress(f"{name}: skipped (excluded by configuration)")
    if not selected:
        if context.json:
            emit_document(plan_document(context, action, [], [], [], skipped, []))
        return 0

    if context.dry_run:
        # A preview writes nothing, so it must not create a lock file either:
        # `--dry-run` promises the state directory is untouched.
        return _switch(context, action, selected, skipped, explicit)

    with state_lock(context):
        return _switch(context, action, selected, skipped, explicit)


def _switch(
    context: Context,
    action: Action,
    selected: list[str],
    skipped: list[str],
    explicit: bool,
) -> int:
    effective = resolve_action(context, action, selected)
    manifest = load_manifest(context)
    entries = manifest["carriers"]

    plans, conflicts, failures, unstarted = build_plans(
        context, effective, selected, entries, explicit
    )

    def emit() -> None:
        """Print the document for this run, if one was asked for.

        Every exit path calls this, so the shape of `proxysw on --json` is the
        same whether it succeeded, was blocked by a conflict, or partially
        failed: only the ``failures`` and ``conflicts`` arrays differ.
        """
        if context.json:
            emit_document(
                plan_document(
                    context, effective, plans, conflicts, failures, skipped, unstarted
                )
            )

    for name in unstarted:
        context.progress(f"{name}: nothing to restore (no snapshot)")

    blocked = bool(conflicts) and not context.force
    if conflicts:
        report_conflicts(conflicts)
        if blocked:
            report_failures(failures)
            print(
                "proxysw: no carriers were changed because of the conflict(s)",
                file=sys.stderr,
            )
            emit()
            return 1

    if context.dry_run:
        for plan in plans:
            if plan.changed:
                if effective is Action.RESTORE:
                    context.progress(f"{plan.name}: would restore {plan.path}")
                else:
                    context.progress(
                        f"{plan.name}: would turn {effective.value} {plan.path}"
                    )
            else:
                context.progress(
                    f"{plan.name}: already {_display_action(effective)} {plan.path}"
                )
        if failures:
            report_failures(failures)
            not_changed = ", ".join(name for name, _ in failures) or "none"
            print(
                f"proxysw: partial completion: changed none; not changed {not_changed}",
                file=sys.stderr,
            )
            emit()
            return 1
        emit()
        return 0

    manifest_dirty = False
    changed_names: list[str] = []
    failed_names = [name for name, _ in failures]

    for plan in plans:
        try:
            if _apply_plan(context, manifest, effective, plan):
                manifest_dirty = True
            if plan.changed:
                changed_names.append(plan.name)
        except Exception as error:  # noqa: BLE001 - one carrier must not abort the rest
            failures.append((plan.name, str(error) or error.__class__.__name__))
            failed_names.append(plan.name)
            continue

    if manifest_dirty:
        try:
            save_manifest(context, manifest)
        except Exception as error:  # noqa: BLE001 - changes already happened
            failures.append(
                (
                    "manifest",
                    f"could not save {context.manifest_path}: {error}",
                )
            )
            failed_names.append("manifest")

    if failures:
        report_failures(failures)
        changed_text = ", ".join(changed_names) or "none"
        failed_text = ", ".join(dict.fromkeys(failed_names)) or "none"
        print(
            f"proxysw: partial completion: changed {changed_text}; "
            f"not changed {failed_text}",
            file=sys.stderr,
        )
        emit()
        return 1

    emit()
    return 0
