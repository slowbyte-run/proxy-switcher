"""ssh carrier: ``ProxyCommand`` inside the github.com host block.

Only the first ``github.com`` block is edited, and only its first
``ProxyCommand`` directive. Every other line -- other host blocks, comments,
indentation and line endings -- is copied through unchanged.
"""

from __future__ import annotations

import os
import re
import shutil
from dataclasses import dataclass
from urllib.parse import urlsplit

from proxy_common import line_ending

from .model import Carrier

NAME = "ssh"
HOST = "github.com"
PROXY_VALUE_NONE = "none"

_DIRECTIVE_RE = re.compile(
    r"^([ \t]*)([A-Za-z][A-Za-z0-9]*)([ \t]*=[ \t]*|[ \t]+)(.*)$"
)
_INDENT_RE = re.compile(r"^[ \t]*")


@dataclass(frozen=True)
class _Line:
    text: str
    ending: str


@dataclass(frozen=True)
class _Block:
    host_index: int
    start: int
    end: int


def resolve(context) -> str:
    return os.path.join(context.home, ".ssh", "config")


def _split_lines(text: str) -> list[_Line]:
    parts = text.split("\n")
    lines: list[_Line] = []
    for index, part in enumerate(parts):
        last = index == len(parts) - 1
        if last and part == "":
            break
        ending = "" if last else "\n"
        if part.endswith("\r") and not last:
            part = part[:-1]
            ending = "\r\n"
        lines.append(_Line(part, ending))
    return lines


def _join(lines: list[_Line]) -> str:
    return "".join(line.text + line.ending for line in lines)


def _newline(lines: list[_Line]) -> str:
    return line_ending("".join(line.ending for line in lines))


def _directive(line: _Line):
    stripped = line.text.strip()
    if not stripped or stripped.startswith("#"):
        return None
    match = _DIRECTIVE_RE.match(line.text)
    if not match:
        return None
    return match.group(2), match.group(4).strip(), match


def _blocks(lines: list[_Line]) -> list[_Block]:
    blocks: list[_Block] = []
    current: _Block | None = None
    for index, line in enumerate(lines):
        directive = _directive(line)
        keyword = directive[0].lower() if directive else None
        if keyword == "host":
            if current is not None:
                blocks.append(_Block(current.host_index, current.start, index))
            current = _Block(index, index + 1, len(lines))
        elif keyword == "match" and current is not None:
            blocks.append(_Block(current.host_index, current.start, index))
            current = None
    if current is not None:
        blocks.append(current)
    return blocks


def _github_block(lines: list[_Line]) -> _Block | None:
    for block in _blocks(lines):
        directive = _directive(lines[block.host_index])
        if directive is None:
            continue
        patterns = directive[1].split()
        if any(pattern.lower() == HOST for pattern in patterns):
            return block
    return None


def _proxy_value(lines: list[_Line], block: _Block) -> str | None:
    for index in range(block.start, block.end):
        directive = _directive(lines[index])
        if directive is not None and directive[0].lower() == "proxycommand":
            return directive[1]
    return None


def read_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return "off"

    lines = _split_lines(text)
    block = _github_block(lines)
    if block is None:
        return "off"
    value = _proxy_value(lines, block)
    if not value:
        return "off"
    if value.split()[0].lower() == PROXY_VALUE_NONE:
        return "off"
    return "on"


def region_exists(text: str) -> bool:
    return _github_block(_split_lines(text)) is not None


def _proxy_command(context) -> str:
    endpoint = urlsplit(context.endpoint)
    return f"ncat --proxy {endpoint.netloc} --proxy-type http %h %p"


def check_rendered(text: str | None) -> str:
    """Warn when the github.com ProxyCommand names a binary that is missing.

    The rendered value shells out to ``ncat`` (nmap). Without it ssh fails at
    connect time with a confusing error, so the caller gets told up front --
    both before ``on`` writes and from ``status``.
    """
    if not text:
        return ""
    lines = _split_lines(text)
    block = _github_block(lines)
    if block is None:
        return ""
    value = _proxy_value(lines, block)
    if not value:
        return ""
    command = value.split()[0]
    if command.lower() == PROXY_VALUE_NONE or shutil.which(command):
        return ""
    return (
        f"ProxyCommand runs {command}, which is not on PATH; "
        "install nmap-ncat or GitHub SSH will fail"
    )


def _render(text: str, value: str) -> str:
    lines = _split_lines(text)
    block = _github_block(lines)

    if block is None:
        return _append_block(text, value)

    for index in range(block.start, block.end):
        directive = _directive(lines[index])
        if directive is not None and directive[0].lower() == "proxycommand":
            match = directive[2]
            lines[index] = _Line(
                match.group(1) + match.group(2) + match.group(3) + value,
                lines[index].ending,
            )
            return _join(lines)

    return _insert_proxy(lines, block, value)


def _insert_proxy(lines: list[_Line], block: _Block, value: str) -> str:
    target: int | None = None
    for index in range(block.start, block.end):
        stripped = lines[index].text.strip()
        if not stripped or stripped.startswith("#"):
            continue
        target = index

    if target is None:
        insert_at = block.start
        indent = "    "
    else:
        insert_at = target + 1
        indent = _INDENT_RE.match(lines[target].text).group(0) or "    "

    newline = _newline(lines)
    inserted = _Line(f"{indent}ProxyCommand {value}", newline)

    if insert_at > 0 and lines[insert_at - 1].ending == "":
        # Keep a file that did not end in a newline that way.
        previous = lines[insert_at - 1]
        lines[insert_at - 1] = _Line(previous.text, newline)
        inserted = _Line(inserted.text, "")

    lines.insert(insert_at, inserted)
    return _join(lines)


def _append_block(text: str, value: str) -> str:
    newline = line_ending(text)
    block = f"Host {HOST}{newline}    ProxyCommand {value}{newline}"
    if not text:
        return block
    if text.endswith(newline + newline):
        return text + block
    if text.endswith(newline):
        return text + newline + block
    return text + newline + newline + block


def _remove_block(text: str) -> str:
    """Remove the github.com block that ``on`` appended."""
    lines = _split_lines(text)
    block = _github_block(lines)
    if block is None:
        return text
    start = block.host_index
    # ``_append_block`` may have inserted one blank separator line.
    if start > 0 and lines[start - 1].text == "":
        start -= 1
    return _join(lines[:start] + lines[block.end :])


def render_on(text: str, context) -> str:
    return _render(text, _proxy_command(context))


def render_off(text: str, context, remove_region: bool = False) -> str:
    if remove_region:
        return _remove_block(text)
    return _render(text, PROXY_VALUE_NONE)


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("GitHub SSH (github.com)",),
    note="",
    note_off="GitHub SSH will connect directly; direct access is unreachable",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    region_exists=region_exists,
    check_rendered=check_rendered,
    default_mode=0o600,
)
