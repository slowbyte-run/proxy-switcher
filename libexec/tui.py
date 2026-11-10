#!/usr/bin/env python3
"""Interactive carrier picker for proxy-switcher.

The picker is a consumer of the CLI's ``--json`` documents: it reads status and
switch plans through subprocesses, never imports the engine, and never writes a
carrier file itself. fzf is an optional external program; when it is missing the
command reports a usage error instead of drawing its own UI.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

FZF_MISSING = "proxysw: tui needs fzf; install fzf or set PROXYSW_FZF to its path"
INTERRUPTED_DRY_RUN = "proxysw: interrupted; nothing was changed"
# An apply is not atomic across carriers: the CLI writes one carrier at a
# time, so an interrupt can leave some of them switched and the manifest
# unsaved. Reporting a clean cancel would hide that.
INTERRUPTED_APPLY = "proxysw: interrupted; run `proxysw status`"


def _cli_path() -> str:
    return os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "proxysw")
    )


def _find_fzf() -> str | None:
    override = os.environ.get("PROXYSW_FZF")
    if override:
        return shutil.which(override)
    return shutil.which("fzf")


def _run_cli(arguments: list[str]) -> tuple[int, str, str]:
    completed = subprocess.run(
        [_cli_path(), *arguments],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return completed.returncode, completed.stdout, completed.stderr


def _document(arguments: list[str]) -> tuple[int, dict | None, str]:
    code, stdout, stderr = _run_cli(arguments)
    try:
        document = json.loads(stdout)
    except json.JSONDecodeError:
        document = None
    return code, document, stderr


def _status(proxy: str | None) -> dict | None:
    # The picker always probes: the header's job is to tell "configured" apart
    # from "something is listening", and a down endpoint is a warning, not a
    # reason to refuse. The probe is bounded by the CLI's own timeout.
    arguments = ["status", "--check", "--json"]
    if proxy:
        arguments += ["--proxy", proxy]
    code, document, stderr = _document(arguments)
    if code != 0:
        if stderr:
            sys.stderr.write(stderr)
        return None
    if document is None:
        print("proxysw: status returned invalid JSON", file=sys.stderr)
        return None
    return document


def _is_unmanaged(carrier: dict) -> bool:
    return carrier.get("state") == "unmanaged"


def _is_skipped(carrier: dict) -> bool:
    """Excluded by config: named in the header, never a selectable row."""
    return bool(carrier.get("skipped"))


def _switchable(status: dict) -> list[dict]:
    return [
        carrier
        for carrier in status.get("carriers", [])
        if not _is_skipped(carrier) and not _is_unmanaged(carrier)
    ]


STATE_COLORS = {"on": "\x1b[32m", "off": "\x1b[33m"}
COLOR_RESET = "\x1b[0m"


def _colored_state(state: str) -> str:
    # Colour is the fast way to scan a mixed list; fzf is told to interpret
    # ANSI because the rows carry the escapes, not fzf itself.
    color = STATE_COLORS.get(state)
    return f"{color}{state}{COLOR_RESET}" if color else state


def _flag_text(carrier: dict) -> str:
    # Rows are already filtered to switchable carriers, so a skipped row can
    # never reach this function; the header names excluded carriers instead.
    # The flag comes from the structured ``pending_reload`` field rather than
    # from substring-matching ``note``, which carries the CLI's own prose
    # about the same fact.
    return "reload pending" if carrier.get("pending_reload") else "-"


# Row columns, in order. The list shows only the first three; the preview
# reads the rest through fzf's numeric placeholders. Indices are derived from
# this tuple so the row builder, ``--with-nth`` and the preview cannot drift
# apart.
ROW_COLUMNS = ("name", "state", "note", "path", "tools", "flags", "state_text")
LIST_COLUMNS = ("name", "state", "note")
PREVIEW_COLUMNS = ("path", "tools", "note", "flags", "state_text")


def _placeholder(column: str) -> str:
    return f"{{{ROW_COLUMNS.index(column) + 1}}}"


WITH_NTH = ",".join(str(ROW_COLUMNS.index(column) + 1) for column in LIST_COLUMNS)

KEY_HINTS = "Tab multi-select | Ctrl-A select all | Enter apply | Esc cancel"

# fzf substitutes each {n} with the nth tab-separated field of the selected
# row, shell-quoted. Only metadata from `status --json` is printed; the file
# itself is never read, so npm/ssh credentials cannot reach the screen.
PREVIEW_COMMAND = (
    "printf 'path   %s\\ntools  %s\\nnote   %s\\nflags  %s\\nstate  %s\\n' "
    + " ".join(_placeholder(column) for column in PREVIEW_COLUMNS)
)


def _row_values(carrier: dict) -> dict[str, str]:
    return {
        "name": carrier["name"],
        "state": _colored_state(carrier["state"]),
        "note": carrier.get("note") or "",
        "path": carrier.get("path") or "",
        "tools": ", ".join(carrier.get("tools") or []),
        "flags": _flag_text(carrier),
        "state_text": carrier["state"],
    }


def _rows(carriers: list[dict]) -> str:
    """Tab-separated rows built in ``ROW_COLUMNS`` order.

    fzf shows the first three fields (``--with-nth``) and keeps the rest as the
    source for the preview's placeholders. Nothing here reads a carrier file:
    every value comes from the ``status --json`` document.
    """
    lines = []
    for carrier in carriers:
        values = _row_values(carrier)
        lines.append("\t".join(values[column] for column in ROW_COLUMNS) + "\n")
    return "".join(lines)


def _header(status: dict) -> str:
    """Two unselectable header lines: context, then the keys that work.

    docker and the carriers skipped by ``exclude`` are context, not choices:
    the first is read-only and the second would be silently skipped by the
    CLI, so neither may become a row the user can select.
    """
    probe = (status.get("check") or {}).get("state", "unknown")
    line = f"endpoint {status['endpoint']}  {probe}"
    for carrier in status.get("carriers", []):
        if _is_unmanaged(carrier):
            line += f" | {carrier['name']}: unmanaged (read-only)"
    excluded = [
        carrier["name"]
        for carrier in status.get("carriers", [])
        if _is_skipped(carrier)
    ]
    line += " | excluded: " + (", ".join(excluded) if excluded else "none")
    return f"{line}\n{KEY_HINTS}"


def _selected_names(stdout: str, carriers: list[dict]) -> list[str]:
    known = {carrier["name"] for carrier in carriers}
    names: list[str] = []
    for line in stdout.splitlines():
        name = line.split("\t", 1)[0].strip()
        if name in known and name not in names:
            names.append(name)
    return names


def _switch(
    action: str, names: list[str], proxy: str | None, *, dry_run: bool
) -> tuple[int, dict | None, str]:
    arguments = [action, *names]
    if dry_run:
        arguments.append("--dry-run")
    arguments.append("--json")
    if proxy:
        arguments += ["--proxy", proxy]
    return _document(arguments)


def _confirm(effective: str, changed: list[str]) -> bool:
    sys.stderr.write(f"Will turn {effective}: {', '.join(changed)} — apply? [Y/n]")
    sys.stderr.flush()
    answer = sys.stdin.readline()
    if answer == "":
        return False
    return answer.strip().lower() in ("", "y", "yes")


def _confirm_with_interrupt(effective: str, changed: list[str]) -> bool:
    try:
        return _confirm(effective, changed)
    except KeyboardInterrupt:
        # Ctrl-C answers the prompt with "no". It arrives before the apply
        # call, so nothing has been written yet.
        sys.stderr.write("\n")
        return False


def _report_outcome(document: dict, action: str) -> None:
    effective = document.get("action") or action
    failed = {failure["carrier"] for failure in document.get("failures") or []}
    conflicted = {conflict["carrier"] for conflict in document.get("conflicts") or []}
    for carrier in document.get("carriers") or []:
        if carrier["name"] in failed:
            # The error itself goes to stderr; calling a failed carrier
            # "already on" here would contradict it. `written`, not `changed`,
            # is what this run actually did: a conflict can block a plan that
            # still says `changed`.
            line = f"{carrier['name']}: failed"
        elif carrier["name"] in conflicted:
            line = f"{carrier['name']}: conflict"
        elif carrier.get("written"):
            line = f"{carrier['name']}: {effective}"
            if carrier.get("pending_reload"):
                line += " (reload pending)"
        else:
            line = f"{carrier['name']}: already {effective}"
        if carrier.get("warning"):
            line += f" (warning: {carrier['warning']})"
        print(line)
    skipped = document.get("skipped") or []
    if skipped:
        print(f"skipped by config: {', '.join(skipped)}")


def run(action: str, proxy: str | None) -> int:
    fzf = _find_fzf()
    if fzf is None:
        print(FZF_MISSING, file=sys.stderr)
        return 2

    try:
        status = _status(proxy)
    except KeyboardInterrupt:
        # The probe writes nothing, so this is the same safe cancel as Esc.
        print("proxysw: cancelled", file=sys.stderr)
        return 0
    if status is None:
        return 1

    carriers = _switchable(status)
    if not carriers:
        print("proxysw: no switchable carriers", file=sys.stderr)
        return 0

    try:
        completed = subprocess.run(
            [
                fzf,
                "--multi",
                "--ansi",
                "--layout=reverse",
                "--delimiter=\\t",
                # The list shows only name, state and note; path, tools and
                # flags stay in the row for the preview, which reads the raw
                # fields.
                f"--with-nth={WITH_NTH}",
                "--prompt",
                f"proxysw {action}> ",
                "--bind",
                "ctrl-a:select-all",
                "--header",
                _header(status),
                "--preview",
                PREVIEW_COMMAND,
                "--preview-window=right:50%",
            ],
            input=_rows(carriers),
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except OSError as error:
        # The binary was executable enough for `which` but exec still failed
        # (bad interpreter, wrong architecture). That is a broken optional
        # dependency, not a switch failure, so keep it a usage error.
        print(f"proxysw: could not start fzf: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        # Ctrl-C reaches the picker as well as fzf, which share the foreground
        # process group; subprocess.run has already killed the child. Nothing
        # has been written yet, so this is the same cancel as fzf exiting 130.
        print("proxysw: cancelled", file=sys.stderr)
        return 0
    if completed.returncode == 130:
        print("proxysw: cancelled", file=sys.stderr)
        return 0
    if completed.returncode == 1:
        print("proxysw: nothing selected", file=sys.stderr)
        return 0
    if completed.returncode != 0:
        if completed.stderr:
            sys.stderr.write(completed.stderr)
        print("proxysw: fzf failed", file=sys.stderr)
        return 2

    names = _selected_names(completed.stdout, carriers)
    if not names:
        print("proxysw: nothing selected", file=sys.stderr)
        return 0

    try:
        code, plan, stderr = _switch(action, names, proxy, dry_run=True)
    except KeyboardInterrupt:
        # The plan is a preview, so no carrier changed; but the command did not
        # finish its own job, so it is not the clean 0-exit cancel path either.
        print(INTERRUPTED_DRY_RUN, file=sys.stderr)
        return 1
    if plan is None:
        if stderr:
            sys.stderr.write(stderr)
        else:
            print("proxysw: could not read the switch plan", file=sys.stderr)
        return 1
    if code != 0:
        if stderr:
            sys.stderr.write(stderr)
        else:
            print("proxysw: switch failed", file=sys.stderr)
        return 1

    changed = [carrier["name"] for carrier in plan["carriers"] if carrier["changed"]]
    if not changed:
        print("nothing to change")
        return 0

    if not _confirm_with_interrupt(plan["action"], changed):
        print("proxysw: cancelled", file=sys.stderr)
        return 0

    try:
        code, result, stderr = _switch(action, names, proxy, dry_run=False)
    except KeyboardInterrupt:
        print(INTERRUPTED_APPLY, file=sys.stderr)
        return 1
    if result is None:
        if stderr:
            sys.stderr.write(stderr)
        else:
            print("proxysw: could not read the switch result", file=sys.stderr)
        return 1
    _report_outcome(result, action)
    if code != 0:
        if stderr:
            sys.stderr.write(stderr)
        else:
            print("proxysw: switch failed", file=sys.stderr)
        return 1
    return 0
