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
    arguments = ["status", "--json"]
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


def _switchable(status: dict) -> list[dict]:
    return [
        carrier
        for carrier in status.get("carriers", [])
        if not carrier.get("skipped") and carrier.get("state") != "unmanaged"
    ]


def _rows(carriers: list[dict]) -> str:
    return "".join(f"{carrier['name']}\t{carrier['state']}\n" for carrier in carriers)


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

    status = _status(proxy)
    if status is None:
        return 1

    carriers = _switchable(status)
    if not carriers:
        print("proxysw: no switchable carriers", file=sys.stderr)
        return 0

    completed = subprocess.run(
        [
            fzf,
            "--multi",
            "--layout=reverse",
            "--prompt",
            f"proxysw {action}> ",
            "--bind",
            "ctrl-a:select-all",
        ],
        input=_rows(carriers),
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
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

    code, plan, stderr = _switch(action, names, proxy, dry_run=True)
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

    if not _confirm(plan["action"], changed):
        print("proxysw: cancelled", file=sys.stderr)
        return 0

    code, result, stderr = _switch(action, names, proxy, dry_run=False)
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
