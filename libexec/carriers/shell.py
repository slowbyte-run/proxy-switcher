"""shell carrier: the managed snippet in the interactive shell rc.

The snippet is delimited by start and end markers so that everything outside
it can be preserved byte for byte. ``on`` writes six ``export`` lines; ``off``
writes six explicit ``unset`` lines instead of deleting the snippet, because an
interactive shell overrides niri's ``environment {}`` block and a missing
variable would let that block's value leak through.

The rc file follows ``$SHELL``: zsh uses ``~/.zshrc``, bash uses
``~/.bashrc``, and anything else (or an unset ``SHELL``) falls back to
``~/.zshrc``.
"""

from __future__ import annotations

import os
import re

from proxy_common import (
    NODE_FETCH_VALUE,
    NODE_FETCH_VAR,
    PROXY_URL_VARS,
    PROXY_VARS,
    proxy_values,
    quote_shell_double,
    unquote,
)

from .model import Carrier

NAME = "shell"

SNIPPET_START = "# >>> proxy-switcher >>>"
SNIPPET_END = "# <<< proxy-switcher <<<"

# Set by ``resolve`` so ``after_write`` can report a freshly created rc file
# without the shared engine having to know about carrier-specific messages.
_EXISTED_ATTRIBUTE = "_shell_rc_existed"

_ASSIGNMENT = re.compile(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
_UNSET = re.compile(r"unset\s+(.+)$")


def rc_path(context) -> str:
    shell = os.path.basename(os.environ.get("SHELL", "")).lower()
    filename = ".bashrc" if shell == "bash" else ".zshrc"
    return os.path.join(context.home, filename)


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
            if name in PROXY_VARS:
                values[name] = unquote(assignment.group(2))
            continue
        unset = _UNSET.match(stripped)
        if unset:
            for name in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", unset.group(1)):
                if name in PROXY_VARS:
                    values[name] = ""

    return "on" if any(values.get(key) for key in PROXY_URL_VARS) else "off"


def _quote(value: str) -> str:
    return quote_shell_double(value)


def _snippet(context, *, on: bool) -> str:
    lines = [SNIPPET_START]
    if on:
        values = proxy_values(context.endpoint, context.no_proxy)
        lines.extend(f"export {key}={_quote(values[key])}" for key in PROXY_VARS)
        lines.append(f"export {NODE_FETCH_VAR}={NODE_FETCH_VALUE}")
    else:
        # Deliberately no ``unset NODE_USE_ENV_PROXY`` here: the flag only
        # enables Node to read the six variables, and a user may set it
        # themselves outside this snippet. Removing it on ``off`` would
        # silently override that hand-written line.
        lines.extend(f"unset {key}" for key in PROXY_VARS)
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


def _remove_snippet(text: str) -> str:
    """Remove the managed snippet, including the blank line ``_replace`` adds."""
    lines = text.splitlines(keepends=True)
    start = None
    for index, line in enumerate(lines):
        if line.strip() == SNIPPET_START:
            start = index
            break
    if start is None:
        return text

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].strip() == SNIPPET_END:
            end = index + 1
            break

    prefix = "".join(lines[:start])
    suffix = "".join(lines[end:])
    # ``_replace`` inserts one blank line before an appended snippet when the
    # file ends with a single newline. Drop that separator again.
    if prefix.endswith("\n\n"):
        prefix = prefix[:-1]
    return prefix + suffix


def render_on(text: str, context) -> str:
    return _replace(text, _snippet(context, on=True))


def render_off(text: str, context, remove_region: bool = False) -> str:
    if remove_region:
        return _remove_snippet(text)
    return _replace(text, _snippet(context, on=False))


def after_write(context) -> bool:
    """Report a newly created rc file; there is nothing to reload."""
    if not getattr(context, _EXISTED_ATTRIBUTE, True):
        print(f"shell: created {rc_path(context)}")
    return True


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("interactive shells", "git", "curl"),
    note="takes precedence over the niri environment block",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    after_write=after_write,
    delete_created_file=False,
    default_mode=0o644,
)
