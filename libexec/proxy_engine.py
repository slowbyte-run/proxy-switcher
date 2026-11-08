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

import hashlib
import json
import os
import stat
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone

from carriers import get as get_carrier
from proxy_common import Action, State

MANIFEST_VERSION = 1


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

    @property
    def manifest_path(self) -> str:
        return os.path.join(self.state_root, "manifest.json")

    def warn(self, message: str) -> None:
        print(f"proxy: warning: {message}", file=sys.stderr)


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

    if not isinstance(manifest, dict) or not isinstance(
        manifest.get("carriers"), dict
    ):
        raise EngineError(f"manifest {context.manifest_path} has an unknown shape")
    manifest.setdefault("version", MANIFEST_VERSION)
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
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
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
        descriptor = os.open(
            snapshot_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
        )
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(original)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(snapshot_file, 0o600)
    return snapshot_dir, snapshot_file


def _timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _original_region_existed(carrier, current: bytes | None) -> bool:
    if current is None:
        return False
    if carrier.region_exists is None:
        return True
    return carrier.region_exists(current.decode("utf-8"))


def select_carriers(
    context: Context, names: list[str]
) -> tuple[list[str], list[str]]:
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
    return carrier.render_off(text, context, remove_region=remove_region).encode("utf-8")


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
            )
        )

    return plans, conflicts, failures, unstarted


def report_failures(failures: list[tuple[str, str]]) -> None:
    for name, message in failures:
        print(f"proxy: {name}: {message}", file=sys.stderr)


def report_conflicts(conflicts: list[tuple]) -> bool:
    """Print every conflict; return whether the caller may continue."""
    for name, path, expected, found in conflicts:
        print(
            f"proxy: conflict: {name} at {path} changed since "
            "proxy-switcher last wrote it",
            file=sys.stderr,
        )
        print(
            f"proxy:   expected {expected or 'the file to be absent'}",
            file=sys.stderr,
        )
        print(
            f"proxy:   found    {found or 'the file to be absent'}",
            file=sys.stderr,
        )
    print(
        "proxy: refusing to overwrite; review the file, then re-run with "
        "--force to replace it",
        file=sys.stderr,
    )
    return False


def _display_action(action: Action) -> str:
    if action is Action.RESTORE:
        return "restored"
    return action.value


def _write_mode(plan: Plan, action: Action) -> int:
    if action is Action.RESTORE:
        original = (plan.entry or {}).get("original_mode")
        if original is not None:
            return original
    return plan.mode if plan.mode is not None else plan.carrier.default_mode


def _apply_plan(
    context: Context, manifest: dict, action: Action, plan: Plan
) -> bool:
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
                print(f"proxy: {plan.name}: removed {plan.path}")
            else:
                print(
                    f"proxy: {plan.name}: wrote {plan.path} "
                    f"({len(plan.wanted)} bytes)"
                )
            if new_entry:
                if snapshot_file is None:
                    print(f"proxy: {plan.name}: no snapshot (file was absent)")
                else:
                    print(f"proxy: {plan.name}: snapshot {snapshot_file}")
        else:
            print(f"proxy: {plan.name}: no change to {plan.path}")

    if wrote:
        print(f"{plan.name}: {_display_action(action)}")
        if plan.carrier.after_write is not None:
            try:
                reloaded = plan.carrier.after_write(context)
            except Exception as error:  # noqa: BLE001 - report, do not abort
                context.warn(f"{plan.name}: post-write hook failed: {error}")
                reloaded = False
            entry["pending_reload"] = not reloaded
    else:
        print(f"{plan.name}: already {_display_action(action)}")

    return wrote or new_entry


def switch(
    context: Context, action: Action, names: list[str], explicit: bool = True
) -> int:
    selected, skipped = select_carriers(context, names)
    for name in skipped:
        print(f"{name}: skipped (excluded by configuration)")
    if not selected:
        return 0

    effective = resolve_action(context, action, selected)
    manifest = load_manifest(context)
    entries = manifest["carriers"]

    plans, conflicts, failures, unstarted = build_plans(
        context, effective, selected, entries, explicit
    )
    for name in unstarted:
        print(f"{name}: nothing to restore (no snapshot)")

    if conflicts:
        report_conflicts(conflicts)
        if not context.force:
            report_failures(failures)
            print(
                "proxy: no carriers were changed because of the conflict(s)",
                file=sys.stderr,
            )
            return 1

    if context.dry_run:
        for plan in plans:
            if plan.changed:
                if effective is Action.RESTORE:
                    print(f"{plan.name}: would restore {plan.path}")
                else:
                    print(f"{plan.name}: would turn {effective.value} {plan.path}")
            else:
                print(f"{plan.name}: already {_display_action(effective)} {plan.path}")
        if failures:
            report_failures(failures)
            not_changed = ", ".join(name for name, _ in failures) or "none"
            print(
                f"proxy: partial completion: changed none; not changed {not_changed}",
                file=sys.stderr,
            )
            return 1
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
            failures.append(
                (plan.name, str(error) or error.__class__.__name__)
            )
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
            f"proxy: partial completion: changed {changed_text}; "
            f"not changed {failed_text}",
            file=sys.stderr,
        )
        return 1

    return 0
