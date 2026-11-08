"""shell carrier: the managed snippet in the interactive shell rc.

The snippet is delimited by start and end markers so that everything outside
it can be preserved byte for byte. ``on`` writes six ``export`` lines; ``off``
writes six explicit ``unset`` lines instead of deleting the snippet, because an
interactive shell overrides niri's ``environment {}`` block and a missing
variable would let that block's value leak through.
"""

from __future__ import annotations

import os
import re

from .model import Carrier

NAME = "shell"
PROXY_KEYS = (
    "http_proxy",
    "https_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "no_proxy",
    "NO_PROXY",
)
PROXY_URL_KEYS = ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY")

SNIPPET_START = "# >>> proxy-switcher >>>"
SNIPPET_END = "# <<< proxy-switcher <<<"

# Set by ``resolve`` so ``after_write`` can report a freshly created rc file
# without the shared engine having to know about carrier-specific messages.
_EXISTED_ATTRIBUTE = "_shell_rc_existed"

_ASSIGNMENT = re.compile(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
_UNSET = re.compile(r"unset\s+(.+)$")


def rc_path(context) -> str:
    return os.path.join(context.home, ".zshrc")


def resolve(context) -> str:
    path = rc_path(context)
    setattr(context, _EXISTED_ATTRIBUTE, os.path.exists(path))
    return path


def _extract_snippet(text: str) -> str | None:
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.strip() == SNIPPET_START:
            start = index
        elif line.strip() == SNIPPET_END and start is not None:
            return "\n".join(lines[start : index + 1])
    if start is not None:
        return "\n".join(lines[start:])
    return None


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def read_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return "off"

    snippet = _extract_snippet(text)
    scope = snippet if snippet is not None else text
    values: dict[str, str] = {}

    for line in scope.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        assignment = _ASSIGNMENT.match(stripped)
        if assignment:
            name = assignment.group(1)
            if name in PROXY_KEYS:
                values[name] = _unquote(assignment.group(2))
            continue
        unset = _UNSET.match(stripped)
        if unset:
            for name in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", unset.group(1)):
                if name in PROXY_KEYS:
                    values[name] = ""

    return "on" if any(values.get(key) for key in PROXY_URL_KEYS) else "off"


def _quote(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("$", "\\$")
        .replace("`", "\\`")
    )
    return f'"{escaped}"'


def _snippet(context, *, on: bool) -> str:
    lines = [SNIPPET_START]
    if on:
        values = {
            "http_proxy": context.endpoint,
            "https_proxy": context.endpoint,
            "HTTP_PROXY": context.endpoint,
            "HTTPS_PROXY": context.endpoint,
            "no_proxy": context.no_proxy,
            "NO_PROXY": context.no_proxy,
        }
        lines.extend(f"export {key}={_quote(values[key])}" for key in PROXY_KEYS)
    else:
        lines.extend(f"unset {key}" for key in PROXY_KEYS)
    lines.append(SNIPPET_END)
    return "\n".join(lines) + "\n"


def _replace(text: str, block: str) -> str:
    lines = text.splitlines(keepends=True)
    start = None
    for index, line in enumerate(lines):
        if line.strip() == SNIPPET_START:
            start = index
            break

    if start is None:
        if not text:
            return block
        if not text.endswith("\n"):
            text += "\n"
        if not text.endswith("\n\n"):
            text += "\n"
        return text + block

    prefix = "".join(lines[:start])
    for index in range(start + 1, len(lines)):
        if lines[index].strip() == SNIPPET_END:
            suffix = "".join(lines[index + 1 :])
            return prefix + block + suffix

    # A start marker without an end marker: everything from the marker on is
    # the managed region, so rewrite it rather than appending a second snippet.
    return prefix + block


def render_on(text: str, context) -> str:
    return _replace(text, _snippet(context, on=True))


def render_off(text: str, context) -> str:
    return _replace(text, _snippet(context, on=False))


def after_write(context) -> bool:
    """Report a newly created rc file; there is nothing to reload."""
    if not getattr(context, _EXISTED_ATTRIBUTE, True):
        print(f"shell: created {rc_path(context)}")
    return True


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("interactive shells",),
    note="takes precedence over the niri environment block",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    after_write=after_write,
    off_strategy="render",
    default_mode=0o644,
)
