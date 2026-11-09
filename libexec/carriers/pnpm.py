"""pnpm carrier: ``httpProxy`` / ``httpsProxy`` / ``noProxy`` in config.yaml.

The edit is line based on purpose. A PyYAML round trip would drop comments,
normalise quoting and reflow the document; pnpm users hand-edit this file, so
the carrier only rewrites the value part of the three top-level keys and
appends missing keys. Everything else -- comments, key order, quoting,
indentation, nested blocks and line endings -- stays byte for byte. ``off``
removes the three keys; the snapshot is only used by ``restore``.
"""

from __future__ import annotations

import os
import re

from proxy_common import line_ending

from .model import Carrier

NAME = "pnpm"
KEY_NAMES = ("httpProxy", "httpsProxy", "noProxy")
URL_KEYS = ("httpProxy", "httpsProxy")

# A top-level ``key: value`` line. Quoted keys are legal YAML and pnpm
# accepts them, so they are matched too. Indented lines belong to a nested
# mapping and are deliberately left alone.
_LINE_RE = re.compile(
    r"^(?P<indent>[ \t]*)"
    r"(?P<key>\"(?:[^\"\\]|\\.)*\"|'(?:[^']|'')*'|[A-Za-z0-9_.-]+)"
    r"(?P<sep>[ \t]*):(?P<rest>.*)$"
)


def resolve(context) -> str:
    return os.path.join(context.config_home, "pnpm", "config.yaml")


def _unquote_key(token: str) -> str:
    if token.startswith('"') and token.endswith('"'):
        return token[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if token.startswith("'") and token.endswith("'"):
        return token[1:-1].replace("''", "'")
    return token


def _comment_start(raw: str) -> int:
    """Index where a YAML comment starts, or ``len(raw)`` when there is none."""
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
            return index
        index += 1
    return len(raw)


def _yaml_scalar(raw: str) -> str | None:
    value = raw[: _comment_start(raw)].strip()
    if value in ("", "~", "null", "Null", "NULL"):
        return None
    if value.startswith("'") and value.endswith("'") and len(value) >= 2:
        return value[1:-1].replace("''", "'")
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        body = value[1:-1]
        escaped = {
            "n": "\n",
            "t": "\t",
            "r": "\r",
            '"': '"',
            "\\": "\\",
            "/": "/",
            "0": "\0",
        }
        out: list[str] = []
        index = 0
        while index < len(body):
            char = body[index]
            if char == "\\" and index + 1 < len(body):
                out.append(escaped.get(body[index + 1], body[index + 1]))
                index += 2
                continue
            out.append(char)
            index += 1
        return "".join(out)
    return value


def _parse_top_level(text: str) -> dict[str, str | None]:
    values: dict[str, str | None] = {}
    for line in text.splitlines():
        match = _LINE_RE.match(line)
        if not match or match.group("indent"):
            continue
        values[_unquote_key(match.group("key"))] = _yaml_scalar(match.group("rest"))
    return values


def _needs_quotes(value: str) -> bool:
    if not value or value != value.strip():
        return True
    if value[0] in "-?:,[]{}#&*!|>'\"%@`":
        return True
    return ": " in value or " #" in value or "\n" in value or "\t" in value


def _quoted(value: str, style: str | None) -> str:
    if style == "'":
        return "'" + value.replace("'", "''") + "'"
    if style is None and not _needs_quotes(value):
        return value
    body = value.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + body + '"'


def _style(core: str) -> str | None:
    if core.startswith("'"):
        return "'"
    if core.startswith('"'):
        return '"'
    return None


def _rewrite_line(line: str, key: str, value: str) -> str | None:
    """Return ``line`` with the value of ``key`` replaced, or ``None``."""
    ending = line[len(line.rstrip("\r\n")) :]
    body = line[: len(line) - len(ending)] if ending else line
    match = _LINE_RE.match(body)
    if not match or match.group("indent"):
        return None
    if _unquote_key(match.group("key")) != key:
        return None

    rest = match.group("rest")
    comment_at = _comment_start(rest)
    region = rest[:comment_at]
    comment = rest[comment_at:]

    leading_length = len(region) - len(region.lstrip(" \t"))
    leading = region[:leading_length]
    core = region[leading_length:].rstrip(" \t")
    trailing = region[leading_length + len(core) :]

    if core:
        rendered = _quoted(value, _style(core))
        replacement = leading + rendered + trailing
    else:
        rendered = _quoted(value, '"')
        replacement = (leading or " ") + rendered

    if comment:
        if not replacement.endswith((" ", "\t")):
            replacement += " "
        replacement += comment

    return body[: match.start("rest")] + replacement + ending


def _set_keys(text: str, values: dict[str, str]) -> str:
    present: set[str] = set()
    lines: list[str] = []
    for line in text.splitlines(keepends=True):
        rewritten = None
        match = _LINE_RE.match(line.rstrip("\r\n"))
        if match and not match.group("indent"):
            name = _unquote_key(match.group("key"))
            if name in values:
                rewritten = _rewrite_line(line, name, values[name])
        if rewritten is None:
            lines.append(line)
        else:
            present.add(name)
            lines.append(rewritten)

    result = "".join(lines)
    missing = [name for name in KEY_NAMES if name not in present]
    if missing:
        newline = line_ending(text)
        rendered = [(name, _quoted(values[name], '"')) for name in missing]
        additions = newline.join(f"{name}: {value}" for name, value in rendered)
        if result and not result.endswith("\n"):
            result += newline
        result += additions + newline
    return result


def read_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            values = _parse_top_level(handle.read())
    except OSError:
        return "off"
    for key in URL_KEYS:
        if values.get(key):
            return "on"
    return "off"


def region_exists(text: str) -> bool:
    return any(key in _parse_top_level(text) for key in KEY_NAMES)


def _remove_keys(text: str, keys: tuple[str, ...]) -> str:
    """Remove top-level lines for ``keys`` while keeping everything else."""
    kept: list[str] = []
    for line in text.splitlines(keepends=True):
        match = _LINE_RE.match(line.rstrip("\r\n"))
        if (
            match
            and not match.group("indent")
            and _unquote_key(match.group("key")) in keys
        ):
            continue
        kept.append(line)
    return "".join(kept)


def render_on(text: str, context) -> str:
    return _set_keys(
        text,
        {
            "httpProxy": context.endpoint,
            "httpsProxy": context.endpoint,
            "noProxy": context.no_proxy,
        },
    )


def render_off(text: str, context, remove_region: bool = False) -> str:
    return _remove_keys(text, KEY_NAMES)


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("pnpm",),
    note="",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    region_exists=region_exists,
)
