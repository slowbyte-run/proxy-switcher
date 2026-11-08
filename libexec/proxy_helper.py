#!/usr/bin/env python3
"""Read-only helpers for the proxy-switcher CLI.

The bash entry point owns command dispatch; this helper reads carrier files
and renders the status view. Nothing in this file writes to disk.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import socket
import sys
import tomllib
from urllib.parse import urlsplit

from carriers import get as get_carrier
from kdl import parse_kdl_environment

DEFAULT_ENDPOINT = "http://127.0.0.1:7890"
DEFAULT_NO_PROXY = "localhost,127.0.0.1,::1"

# Upper bound for the `status --check` connect probe, in seconds.
PROBE_TIMEOUT = 0.5

PROXY_URL_KEYS = ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY")

SHELL_SNIPPET_START = "# >>> proxy-switcher >>>"
SHELL_SNIPPET_END = "# <<< proxy-switcher <<<"


def home_dir() -> str:
    home = os.environ.get("HOME")
    if not home:
        raise SystemExit("proxy: HOME is not set")
    return home


def xdg_dir(variable: str, fallback: str) -> str:
    """Resolve an XDG base directory, ignoring relative values per the spec."""
    value = os.environ.get(variable, "")
    if value and os.path.isabs(value):
        return value
    return os.path.join(home_dir(), fallback)


def config_home() -> str:
    return xdg_dir("XDG_CONFIG_HOME", ".config")


def state_home() -> str:
    return xdg_dir("XDG_STATE_HOME", ".local/state")


def config_path() -> str:
    return os.path.join(config_home(), "proxy-switcher", "config.toml")


def state_path() -> str:
    return os.path.join(state_home(), "proxy-switcher")


class ConfigError(Exception):
    """Raised when the user configuration cannot be used."""


def load_config() -> tuple[str, str]:
    path = config_path()
    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except FileNotFoundError:
        return DEFAULT_ENDPOINT, DEFAULT_NO_PROXY
    except OSError as error:
        raise ConfigError(f"cannot read {path}: {error.strerror}") from error
    except tomllib.TOMLDecodeError as error:
        raise ConfigError(f"invalid TOML in {path}: {error}") from error

    endpoint = data.get("endpoint", DEFAULT_ENDPOINT)
    no_proxy = data.get("no_proxy", DEFAULT_NO_PROXY)

    if not isinstance(endpoint, str):
        raise ConfigError(f"endpoint in {path} must be a string")
    parsed = urlsplit(endpoint)
    if parsed.scheme != "http" or not parsed.netloc:
        raise ConfigError(
            f"endpoint in {path} must be an http URL such as {DEFAULT_ENDPOINT}"
        )
    if not isinstance(no_proxy, str):
        raise ConfigError(f"no_proxy in {path} must be a string")

    return endpoint, no_proxy


def carrier_paths() -> dict[str, str]:
    return {
        "niri": os.path.join(config_home(), "niri", "config.kdl"),
        "shell": os.path.join(home_dir(), ".zshrc"),
        "npm": os.path.join(home_dir(), ".npmrc"),
        "pnpm": os.path.join(config_home(), "pnpm", "config.yaml"),
        "ssh": os.path.join(home_dir(), ".ssh", "config"),
        "docker": "/etc/docker/daemon.json",
    }


# --- KDL ---------------------------------------------------------------


def niri_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            variables = parse_kdl_environment(handle.read())
    except OSError:
        return "off"
    for key in PROXY_URL_KEYS:
        if variables.get(key):
            return "on"
    return "off"


# --- shell rc ----------------------------------------------------------


SHELL_PROXY_VARS = PROXY_URL_KEYS + ("no_proxy", "NO_PROXY")


def extract_shell_snippet(text: str) -> str | None:
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == SHELL_SNIPPET_START and start is None:
            start = index
        elif stripped == SHELL_SNIPPET_END and start is not None:
            return "\n".join(lines[start : index + 1])
    if start is not None:
        return "\n".join(lines[start:])
    return None


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def shell_state(path: str) -> str:
    text = read_text(path)
    if text is None:
        return "off"

    snippet = extract_shell_snippet(text)
    scope = snippet if snippet is not None else text
    values: dict[str, str] = {}

    for line in scope.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        assignment = re.match(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", stripped)
        if assignment:
            name = assignment.group(1)
            if name in SHELL_PROXY_VARS:
                values[name] = unquote(assignment.group(2))
            continue
        unset = re.match(r"unset\s+(.+)$", stripped)
        if unset:
            for name in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", unset.group(1)):
                if name in SHELL_PROXY_VARS:
                    values[name] = ""

    return "on" if any(values.get(key) for key in PROXY_URL_KEYS) else "off"


# --- npm and pnpm ------------------------------------------------------


def npm_state(path: str) -> str:
    text = read_text(path)
    if text is None:
        return "off"

    values: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped[0] in "#;":
            continue
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip().lower()
        if key in ("proxy", "https-proxy"):
            values[key] = unquote(value)
    return "on" if any(values.get(key) for key in values) else "off"


def strip_yaml_comment(raw: str) -> str:
    in_single = False
    in_double = False
    index = 0
    while index < len(raw):
        char = raw[index]
        if in_single:
            if char == "'":
                in_single = False
        elif in_double:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                in_double = False
        elif char == "'":
            in_single = True
        elif char == '"':
            in_double = True
        elif char == "#" and (index == 0 or raw[index - 1] in " \t"):
            return raw[:index]
        index += 1
    return raw


def yaml_scalar(raw: str) -> str:
    value = strip_yaml_comment(raw).strip()
    if value in ("", "~", "null", "Null", "NULL"):
        return ""
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return unquote(value)


def pnpm_state(path: str) -> str:
    text = read_text(path)
    if text is None:
        return "off"

    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line or line[0] in " \t#":
            continue
        entry = re.match(r"([A-Za-z0-9_.-]+)\s*:\s*(.*)$", line)
        if not entry:
            continue
        key = entry.group(1)
        if key in ("httpProxy", "httpsProxy"):
            values[key] = yaml_scalar(entry.group(2))
    return "on" if any(values.get(key) for key in values) else "off"


# --- ssh ---------------------------------------------------------------


def ssh_blocks(text: str) -> list[dict]:
    blocks: list[dict] = []
    current: dict | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        directive = re.match(r"([A-Za-z][A-Za-z0-9]*)\s*(?:=\s*|\s+)(.*)$", stripped)
        if not directive:
            continue
        keyword = directive.group(1).lower()
        value = directive.group(2).strip()
        if keyword == "host":
            current = {"patterns": value.split(), "proxy": None}
            blocks.append(current)
        elif keyword == "match":
            current = None
        elif keyword == "proxycommand" and current is not None:
            if current["proxy"] is None:
                current["proxy"] = value
    return blocks


def ssh_state(path: str) -> str:
    text = read_text(path)
    if text is None:
        return "off"

    for block in ssh_blocks(text):
        if not any(pattern.lower() == "github.com" for pattern in block["patterns"]):
            continue
        proxy = block["proxy"]
        if not proxy or proxy.split()[0].lower() == "none":
            return "off"
        return "on"
    return "off"


# --- status ------------------------------------------------------------


def read_text(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def carrier_view(name: str, state: str, path: str, tools: list[str], note: str) -> dict:
    return {
        "name": name,
        "state": state,
        "path": path,
        "tools": tools,
        "note": note,
    }


STATE_READERS = {
    "niri": niri_state,
    "shell": shell_state,
    "npm": npm_state,
    "pnpm": pnpm_state,
    "ssh": ssh_state,
}


def carrier_state(name: str, path: str) -> str:
    """Prefer a registered carrier's own reader; fall back for the rest."""
    carrier = get_carrier(name)
    if carrier is not None:
        return carrier.read_state(path)
    reader = STATE_READERS.get(name)
    return reader(path) if reader is not None else "unmanaged"


def probe_endpoint(endpoint: str) -> dict:
    """Probe the endpoint with a bounded loopback-style TCP connect.

    Only a TCP handshake is attempted: no bytes are written, so no HTTP
    request is made. Unreachable is a valid result, not an error.
    """
    parsed = urlsplit(endpoint)
    try:
        port = parsed.port
    except ValueError as error:
        raise ConfigError(f"endpoint {endpoint} has an invalid port") from error
    host = parsed.hostname or ""
    if port is None:
        port = 80

    state = "down"
    try:
        with socket.create_connection((host, port), timeout=PROBE_TIMEOUT):
            state = "up"
    except (OSError, ValueError):
        state = "down"

    return {"state": state, "host": host, "port": port}


def collect_status(check: bool = False) -> dict:
    endpoint, no_proxy = load_config()
    paths = carrier_paths()
    ssh = carrier_state("ssh", paths["ssh"])
    ssh_note = ""
    if ssh == "off":
        ssh_note = "GitHub SSH will connect directly; direct access is unreachable"
    status = {
        "endpoint": endpoint,
        "no_proxy": no_proxy,
        "carriers": [
            carrier_view(
                "niri",
                carrier_state("niri", paths["niri"]),
                paths["niri"],
                ["niri-spawned processes", "git", "curl", "GUI apps"],
                "",
            ),
            carrier_view(
                "shell",
                carrier_state("shell", paths["shell"]),
                paths["shell"],
                ["interactive shells"],
                "",
            ),
            carrier_view(
                "npm",
                carrier_state("npm", paths["npm"]),
                paths["npm"],
                ["npm", "yarn v1"],
                "npm and yarn v1 share this file",
            ),
            carrier_view(
                "pnpm",
                carrier_state("pnpm", paths["pnpm"]),
                paths["pnpm"],
                ["pnpm"],
                "",
            ),
            carrier_view(
                "ssh",
                ssh,
                paths["ssh"],
                ["GitHub SSH (github.com)"],
                ssh_note,
            ),
            carrier_view(
                "docker",
                "unmanaged",
                paths["docker"],
                ["docker daemon"],
                "read-only: needs root and a daemon restart",
            ),
        ],
    }
    if check:
        status["check"] = probe_endpoint(endpoint)
    return status


def render_human(status: dict) -> str:
    endpoint_line = f"endpoint  {status['endpoint']}"
    if "check" in status:
        endpoint_line += f"  {status['check']['state']}"
    lines = [
        endpoint_line,
        f"no_proxy  {status['no_proxy']}",
        "",
    ]
    headers = ["CARRIER", "STATE", "PATH", "TOOLS", "NOTE"]
    rows = [
        [
            carrier["name"],
            carrier["state"],
            carrier["path"],
            ", ".join(carrier["tools"]),
            carrier["note"],
        ]
        for carrier in status["carriers"]
    ]
    widths = [len(header) for header in headers]
    for row in rows:
        for index in range(len(headers) - 1):
            widths[index] = max(widths[index], len(row[index]))

    def format_row(row: list[str]) -> str:
        cells = [
            row[index].ljust(widths[index]) for index in range(len(headers) - 1)
        ]
        cells.append(row[-1])
        return "  ".join(cells).rstrip()

    lines.append(format_row(headers))
    lines.extend(format_row(row) for row in rows)
    return "\n".join(lines)


def command_status(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="proxy status", add_help=False, allow_abbrev=False
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--check", action="store_true")
    try:
        options, unknown = parser.parse_known_args(arguments)
    except SystemExit:
        return 2
    if unknown:
        print(f"proxy status: unknown argument: {unknown[0]}", file=sys.stderr)
        return 2

    try:
        status = collect_status(check=options.check)
    except ConfigError as error:
        print(f"proxy: {error}", file=sys.stderr)
        return 1

    if options.json:
        import json

        print(json.dumps(status, ensure_ascii=False, indent=2))
    else:
        print(render_human(status))
    return 0


def command_env(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="proxy env", add_help=False, allow_abbrev=False)
    try:
        _, unknown = parser.parse_known_args(arguments)
    except SystemExit:
        return 2
    if unknown:
        print(f"proxy env: unknown argument: {unknown[0]}", file=sys.stderr)
        return 2

    try:
        endpoint, no_proxy = load_config()
        # `env` feeds the current interactive shell, and the shell carrier is
        # the one that owns that state: it overrides the niri environment block.
        state = carrier_state("shell", carrier_paths()["shell"])
    except ConfigError as error:
        print(f"proxy: {error}", file=sys.stderr)
        return 1

    values = {
        "http_proxy": endpoint,
        "https_proxy": endpoint,
        "HTTP_PROXY": endpoint,
        "HTTPS_PROXY": endpoint,
        "no_proxy": no_proxy,
        "NO_PROXY": no_proxy,
    }
    if state == "on":
        for name in SHELL_PROXY_VARS:
            print(f"export {name}={shlex.quote(values[name])}")
    else:
        for name in SHELL_PROXY_VARS:
            print(f"unset {name}")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("status", "env"):
        print("proxy: helper expects the status or env command", file=sys.stderr)
        return 2
    if argv[0] == "env":
        return command_env(argv[1:])
    return command_status(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
