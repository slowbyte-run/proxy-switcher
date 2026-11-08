#!/usr/bin/env python3
"""Shared snapshot / manifest / restore engine for proxy-switcher.

The engine owns everything that is the same for every carrier:

* resolve the carrier's file and read the bytes currently on disk;
* detect external edits by comparing against the hash of the last write;
* snapshot the original file before the first managed change;
* render the new bytes through the carrier and write them atomically;
* record original existence, original hash and written hash in the manifest.

Carriers only describe their path and how to render ``on`` / ``off``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlsplit

import proxy_helper
from carriers import READ_ONLY
from carriers import get as get_carrier
from carriers import managed_names

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


def target_bytes(
    carrier, entry: dict | None, current: bytes | None, context: Context, action: str
):
    """Return the bytes the carrier wants on disk for this action."""
    if carrier.off_strategy == "restore" and action == "off":
        if entry is None:
            return current
        if not entry.get("original_existed"):
            return None
        snapshot = entry.get("snapshot")
        if not snapshot:
            raise EngineError(
                f"{carrier.name}: manifest has no snapshot to restore; "
                "re-run with --force is not enough, remove the manifest entry"
            )
        restored = read_bytes(snapshot)
        if restored is None:
            raise EngineError(f"{carrier.name}: snapshot {snapshot} is missing")
        return restored

    text = "" if current is None else current.decode("utf-8")
    if action == "on":
        return carrier.render_on(text, context).encode("utf-8")
    return carrier.render_off(text, context).encode("utf-8")


def _timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
            if name in READ_ONLY:
                raise UsageError(
                    f"carrier {name} is {READ_ONLY[name]} and cannot be switched"
                )
            raise UsageError(f"unknown carrier: {name}")
        if not carrier.managed:
            raise UsageError(f"carrier {name} is read-only and cannot be switched")

        if name in context.excluded:
            skipped.append(name)
        else:
            selected.append(name)

    return selected, skipped


def report_failures(failures: list[tuple[str, str]]) -> None:
    for name, message in failures:
        print(f"proxy: {name}: {message}", file=sys.stderr)


def switch(context: Context, action: str, names: list[str]) -> int:
    selected, skipped = select_carriers(context, names)
    manifest = load_manifest(context)
    entries = manifest["carriers"]

    for name in skipped:
        print(f"{name}: skipped (excluded by configuration)")
    if not selected:
        return 0

    effective = action
    if action == "toggle":
        states = []
        for name in selected:
            carrier = get_carrier(name)
            states.append(carrier.read_state(carrier.resolve(context)))
        # Any carrier that is not fully on means "turn everything on".
        effective = "off" if all(state == "on" for state in states) else "on"

    plans: list[dict] = []
    conflicts: list[tuple[str, str, str | None, str | None]] = []
    failures: list[tuple[str, str]] = []

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

            if (
                carrier.off_strategy == "restore"
                and effective == "off"
                and entry is None
                and carrier.read_state(path) == "on"
            ):
                failures.append(
                    (
                        name,
                        "no snapshot to restore; the file was left unchanged",
                    )
                )
                continue

            wanted = target_bytes(carrier, entry, current, context, effective)
        except UnicodeDecodeError as error:
            failures.append((name, f"{path} is not valid UTF-8: {error}"))
            continue
        except (EngineError, OSError) as error:
            failures.append((name, str(error)))
            continue

        plans.append(
            {
                "name": name,
                "carrier": carrier,
                "path": path,
                "current": current,
                "current_hash": current_hash,
                "mode": mode,
                "entry": entry,
                "wanted": wanted,
                "changed": wanted != current,
            }
        )

    if conflicts:
        for name, path, expected, found in conflicts:
            print(
                f"proxy: conflict: {name} at {path} changed since "
                "proxy-switcher last wrote it",
                file=sys.stderr,
            )
            print(f"proxy:   expected {expected or 'the file to be absent'}", file=sys.stderr)
            print(f"proxy:   found    {found or 'the file to be absent'}", file=sys.stderr)
        print(
            "proxy: refusing to overwrite; review the file, then re-run with "
            "--force to replace it",
            file=sys.stderr,
        )
        if not context.force:
            report_failures(failures)
            print(
                "proxy: no carriers were changed because of the conflict(s)",
                file=sys.stderr,
            )
            return 1

    if context.dry_run:
        for plan in plans:
            if plan["changed"]:
                print(f"{plan['name']}: would turn {effective}")
            else:
                print(f"{plan['name']}: already {effective}")
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
        name = plan["name"]
        carrier = plan["carrier"]
        entry = plan["entry"]

        try:
            new_entry = entry is None
            if new_entry:
                snapshot_dir, snapshot_file = create_snapshot(
                    context, carrier, plan["current"]
                )

            wrote = False
            if plan["changed"]:
                if plan["wanted"] is None:
                    remove_file(plan["path"])
                else:
                    if carrier.off_strategy == "restore" and effective == "off":
                        write_mode = (entry or {}).get("original_mode")
                        if write_mode is None:
                            write_mode = (
                                plan["mode"]
                                if plan["mode"] is not None
                                else carrier.default_mode
                            )
                    else:
                        write_mode = (
                            plan["mode"]
                            if plan["mode"] is not None
                            else carrier.default_mode
                        )
                    atomic_write(plan["path"], plan["wanted"], write_mode)
                wrote = True

            if new_entry:
                entry = {
                    "state": effective,
                    "path": plan["path"],
                    "snapshot_dir": snapshot_dir,
                    "snapshot": snapshot_file,
                    "original_existed": plan["current"] is not None,
                    "original_hash": plan["current_hash"],
                    "original_mode": plan["mode"],
                    "written_hash": None,
                    "updated_at": _timestamp(),
                }
                entries[name] = entry
                manifest_dirty = True

            entry["state"] = effective
            entry["written_hash"] = hash_bytes(plan["wanted"])
            if wrote:
                entry["updated_at"] = _timestamp()
                manifest_dirty = True

            if wrote:
                print(f"{name}: {effective}")
                if carrier.after_write is not None:
                    try:
                        reloaded = carrier.after_write(context)
                    except Exception as error:  # noqa: BLE001 - report, do not abort
                        context.warn(f"{name}: post-write hook failed: {error}")
                        reloaded = False
                    entry["pending_reload"] = not reloaded
                    manifest_dirty = True
            else:
                print(f"{name}: already {effective}")

            if wrote:
                changed_names.append(name)
        except Exception as error:  # noqa: BLE001 - one carrier must not abort the rest
            failures.append((name, str(error) or error.__class__.__name__))
            failed_names.append(name)
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


def build_context(arguments: list[str], action: str) -> tuple[Context, list[str]]:
    parser = argparse.ArgumentParser(prog=f"proxy {action}", add_help=False, allow_abbrev=False)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--proxy")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("carriers", nargs="*")
    try:
        options, unknown = parser.parse_known_args(arguments)
    except SystemExit:
        raise UsageError("") from None
    if unknown:
        raise UsageError(f"unknown argument: {unknown[0]}")

    settings = proxy_helper.load_settings()
    endpoint, no_proxy = settings.endpoint, settings.no_proxy
    if options.proxy is not None:
        parsed = urlsplit(options.proxy)
        if parsed.scheme != "http" or not parsed.netloc:
            raise UsageError(
                f"--proxy must be an http URL such as {proxy_helper.DEFAULT_ENDPOINT}"
            )
        endpoint = options.proxy

    names = options.carriers or managed_names()
    context = Context(
        home=proxy_helper.home_dir(),
        config_home=proxy_helper.config_home(),
        state_root=os.path.join(proxy_helper.state_home(), "proxy-switcher"),
        endpoint=endpoint,
        no_proxy=no_proxy,
        excluded=frozenset(settings.exclude),
        force=options.force,
        dry_run=options.dry_run,
        verbose=options.verbose,
    )
    return context, names


def usage() -> str:
    return """Usage: proxy <command> [options] [carrier...]

Commands:
  on [carrier...]     Turn managed carriers on (default: every managed carrier)
  off [carrier...]    Turn managed carriers off
  toggle [carrier...] Turn on unless every selected carrier is already on
  status [--json]     Show the state of every proxy carrier

Options for on/off/toggle:
  --force            Overwrite a file that changed since the last switch
  --dry-run          Show what would change without writing
  --proxy <url>      Override the configured proxy endpoint
  -v, --verbose      Explain what was done

Configuration:
  $XDG_CONFIG_HOME/proxy-switcher/config.toml accepts endpoint, no_proxy
  and exclude (a list of carrier names to leave alone).

Exit status: 0 success, 1 conflict/failure, 2 usage error.
"""


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write(usage())
        return 2
    action = argv[0]
    if action not in ("on", "off", "toggle"):
        print(f"proxy: unknown command: {action}", file=sys.stderr)
        sys.stderr.write(usage())
        return 2

    try:
        context, names = build_context(argv[1:], action)
    except proxy_helper.ConfigError as error:
        print(f"proxy: {error}", file=sys.stderr)
        return 1
    except UsageError as error:
        if str(error):
            print(f"proxy: {error}", file=sys.stderr)
        sys.stderr.write(usage())
        return 2

    try:
        return switch(context, action, names)
    except UsageError as error:
        print(f"proxy: {error}", file=sys.stderr)
        sys.stderr.write(usage())
        return 2
    except EngineError as error:
        print(f"proxy: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
