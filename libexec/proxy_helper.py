#!/usr/bin/env python3
"""Read-only helpers for the proxy-switcher CLI.

The CLI entry point owns command dispatch; this helper reads carrier files and
renders the status / env views. Nothing in this file writes to disk.
"""

from __future__ import annotations

import ipaddress
import json
import os
import shlex
import socket
import threading
import time
import tomllib
from dataclasses import dataclass
from urllib.parse import urlsplit

import carriers
from carriers import get as get_carrier
from carriers import names as carrier_names
from proxy_common import PROXY_VARS, State, proxy_values

DEFAULT_ENDPOINT = "http://127.0.0.1:7890"
DEFAULT_NO_PROXY = "localhost,127.0.0.1,::1"

# Upper bound for the whole `status --check` probe (DNS + TCP connect), in
# seconds. The contract is "returns within one second"; leave margin for
# process startup.
PROBE_TIMEOUT = 0.5


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


@dataclass(frozen=True)
class Settings:
    endpoint: str
    no_proxy: str
    exclude: tuple[str, ...] = ()


@dataclass
class StatusContext:
    home: str
    config_home: str


def _known_carriers() -> set[str]:
    return set(carrier_names())


def _exclude_list(path: str, raw) -> tuple[str, ...]:
    if not isinstance(raw, list) or not all(isinstance(name, str) for name in raw):
        raise ConfigError(f"exclude in {path} must be an array of carrier names")
    known = _known_carriers()
    unknown = [name for name in raw if name not in known]
    if unknown:
        raise ConfigError(
            f"exclude in {path} names unknown carrier: {unknown[0]}"
        )
    # Preserve the user's order while dropping duplicates.
    return tuple(dict.fromkeys(raw))


def load_settings() -> Settings:
    path = config_path()
    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except FileNotFoundError:
        return Settings(DEFAULT_ENDPOINT, DEFAULT_NO_PROXY)
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

    excluded = _exclude_list(path, data.get("exclude", []))
    return Settings(endpoint, no_proxy, excluded)


def carrier_view(
    name: str,
    state: str,
    path: str,
    tools: tuple[str, ...],
    note: str,
    skipped: bool = False,
) -> dict:
    if skipped:
        note = (note + "; " if note else "") + "excluded by configuration; skipped"
    return {
        "name": name,
        "state": state,
        "path": path,
        "tools": list(tools),
        "note": note,
        "skipped": skipped,
    }


def _is_ip_literal(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def _resolve(host: str, port: int, deadline: float):
    """Resolve ``host`` within the deadline, or return ``None``."""
    if _is_ip_literal(host):
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        return [(family, (host, port))]

    result: list = []

    def worker() -> None:
        try:
            result.extend(
                (info[0], info[4][:2])
                for info in socket.getaddrinfo(
                    host, port, type=socket.SOCK_STREAM
                )
            )
        except (OSError, UnicodeError, ValueError):
            pass

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    thread.join(max(0.0, deadline - time.monotonic()))
    if thread.is_alive() or not result:
        return None
    return result


def probe_endpoint(endpoint: str) -> dict:
    """Probe the endpoint with a bounded, local-only TCP connect.

    Only a TCP handshake is attempted: no bytes are written, so no HTTP
    request is made. DNS resolution shares the same timeout budget, so an
    unreachable resolver or host reports ``down`` instead of hanging.
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
    deadline = time.monotonic() + PROBE_TIMEOUT
    addresses = _resolve(host, port, deadline)
    for family, address in addresses or ():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock = socket.socket(family, socket.SOCK_STREAM)
        sock.settimeout(remaining)
        try:
            sock.connect(address)
            state = "up"
            break
        except OSError:
            continue
        finally:
            sock.close()

    return {"state": state, "host": host, "port": port}


def collect_status(check: bool = False, endpoint: str | None = None) -> dict:
    settings = load_settings()
    chosen = endpoint or settings.endpoint
    no_proxy = settings.no_proxy
    excluded = set(settings.exclude)
    context = StatusContext(home=home_dir(), config_home=config_home())

    rows = []
    for carrier in carriers.all_carriers():
        path = carrier.resolve(context)
        state = carrier.read_state(path)
        note = carrier.note_off if state == State.OFF and carrier.note_off else carrier.note
        rows.append(
            carrier_view(
                carrier.name,
                state,
                path,
                carrier.tools,
                note,
                skipped=carrier.name in excluded,
            )
        )

    status = {
        "endpoint": chosen,
        "no_proxy": no_proxy,
        "carriers": rows,
    }
    if check:
        status["check"] = probe_endpoint(chosen)
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


def status_output(check: bool, as_json: bool, endpoint: str | None) -> str:
    status = collect_status(check=check, endpoint=endpoint)
    if as_json:
        return json.dumps(status, ensure_ascii=False, indent=2)
    return render_human(status)


def env_output(endpoint: str, no_proxy: str) -> str:
    context = StatusContext(home=home_dir(), config_home=config_home())
    carrier = get_carrier("shell")
    path = carrier.resolve(context)
    state = carrier.read_state(path)
    values = proxy_values(endpoint, no_proxy)
    lines = []
    if state == State.ON:
        for name in PROXY_VARS:
            lines.append(f"export {name}={shlex.quote(values[name])}")
    else:
        for name in PROXY_VARS:
            lines.append(f"unset {name}")
    return "\n".join(lines)
