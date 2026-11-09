"""Constants and text helpers shared by every carrier and command.

This module is the single source of truth for the six proxy variables, the
variable-to-value mapping, line-ending detection, unquoting and shell escaping.
Carriers import these instead of keeping private copies.
"""

from __future__ import annotations

from enum import Enum

PROXY_VARS = (
    "http_proxy",
    "https_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "no_proxy",
    "NO_PROXY",
)

# The four variables that actually point at a proxy. ``no_proxy``/``NO_PROXY``
# only describe exclusions, so they never turn a carrier "on" by themselves.
PROXY_URL_VARS = PROXY_VARS[:4]

# Node's built-in fetch ignores the environment unless this opt-in flag is set
# (Node 24+). It is not a proxy value: it only enables reading the others, so
# it never counts towards a carrier's state.
NODE_FETCH_VAR = "NODE_USE_ENV_PROXY"
NODE_FETCH_VALUE = "1"

# Bumped whenever a `--json` document gains, loses or renames a field. Scripts
# and status-bar widgets compare this before trusting the rest of the document.
JSON_SCHEMA = 1

# Printed by `proxy --version`; keep in step with the README badge.
VERSION = "0.1.0"


class Action(str, Enum):
    """A switch action. String values keep manifest JSON readable."""

    ON = "on"
    OFF = "off"
    TOGGLE = "toggle"
    RESTORE = "restore"


class State(str, Enum):
    """The observable state of a carrier."""

    ON = "on"
    OFF = "off"
    UNMANAGED = "unmanaged"


def proxy_values(endpoint: str, no_proxy: str) -> dict[str, str]:
    """The canonical six-variable mapping used by niri and the shell rc."""
    return {
        "http_proxy": endpoint,
        "https_proxy": endpoint,
        "HTTP_PROXY": endpoint,
        "HTTPS_PROXY": endpoint,
        "no_proxy": no_proxy,
        "NO_PROXY": no_proxy,
    }


def line_ending(text: str) -> str:
    """The line ending a file already uses, defaulting to LF."""
    return "\r\n" if "\r\n" in text else "\n"


def unquote(value: str) -> str:
    """Strip one matching pair of single or double quotes."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def escape_shell_double(value: str) -> str:
    """Escape a value so it can live inside a double-quoted shell string."""
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("$", "\\$")
        .replace("`", "\\`")
    )


def quote_shell_double(value: str) -> str:
    return f'"{escape_shell_double(value)}"'
