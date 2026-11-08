#!/usr/bin/env python3
"""Minimal, comment-preserving KDL helpers used by the niri carrier.

The functions here operate on text, never on disk. ``strip_kdl_comments``
replaces comments with spaces so that byte offsets in the stripped text still
point at the same characters in the original text; the editing helpers rely on
that property to leave comments and unrelated nodes untouched.
"""

from __future__ import annotations

import re


def strip_kdl_comments(text: str) -> str:
    """Remove // and /* */ comments while leaving string literals intact."""
    out: list[str] = []
    i = 0
    length = len(text)
    in_string = False
    in_block = False

    while i < length:
        char = text[i]

        if in_block:
            if text.startswith("*/", i):
                in_block = False
                out.append("  ")
                i += 2
            else:
                out.append("\n" if char == "\n" else " ")
                i += 1
            continue

        if in_string:
            out.append(char)
            if char == "\\" and i + 1 < length:
                out.append(text[i + 1])
                i += 2
                continue
            if char == '"':
                in_string = False
            i += 1
            continue

        if text.startswith("//", i):
            while i < length and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if text.startswith("/*", i):
            in_block = True
            out.append("  ")
            i += 2
            continue
        if char == '"':
            in_string = True
        out.append(char)
        i += 1

    return "".join(out)


def find_matching_brace(text: str, opening: int) -> int | None:
    depth = 0
    in_string = False
    i = opening
    while i < len(text):
        char = text[i]
        if in_string:
            if char == "\\":
                i += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def kdl_string_value(raw: str) -> str | None:
    raw = raw.strip()
    if raw == "null" or raw.startswith("null ") or raw.startswith("null;"):
        return None
    if not raw.startswith('"'):
        return None
    value: list[str] = []
    i = 1
    while i < len(raw):
        char = raw[i]
        if char == "\\" and i + 1 < len(raw):
            escape = raw[i + 1]
            mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
            value.append(mapping.get(escape, escape))
            i += 2
            continue
        if char == '"':
            return "".join(value)
        value.append(char)
        i += 1
    return None


def parse_kdl_environment(text: str) -> dict[str, str | None]:
    """Return the effective environment variables from niri config.kdl."""
    stripped = strip_kdl_comments(text)
    variables: dict[str, str | None] = {}

    block_re = re.compile(r"(?:^|\n)[ \t]*environment[ \t]*\{")
    for match in block_re.finditer(stripped):
        opening = stripped.index("{", match.start())
        closing = find_matching_brace(stripped, opening)
        if closing is None:
            continue
        body = stripped[opening + 1 : closing]
        for statement in re.split(r"[\n;]", body):
            statement = statement.strip()
            if not statement or statement.startswith("/-"):
                continue
            node = re.match(r"([A-Za-z_][A-Za-z0-9_-]*)[ \t]+(.*)$", statement)
            if not node:
                continue
            name, rest = node.group(1), node.group(2)
            variables[name] = kdl_string_value(rest)
    return variables


def _environment_block(stripped: str) -> tuple[int, int, int] | None:
    """Return ``(line_start, opening_brace, closing_brace)``."""
    match = re.search(r"(?:^|\n)[ \t]*environment[ \t]*\{", stripped)
    if not match:
        return None
    opening = stripped.index("{", match.start())
    closing = find_matching_brace(stripped, opening)
    if closing is None:
        return None
    line_start = match.start()
    if stripped[line_start] == "\n":
        line_start += 1
    return line_start, opening, closing


def environment_block_exists(text: str) -> bool:
    return _environment_block(strip_kdl_comments(text)) is not None


def remove_environment_block(text: str) -> str:
    """Remove the first ``environment {}`` block and its line.

    Used when ``on`` created the block and ``off`` must return the file to a
    state without it. Everything outside the block is preserved.
    """
    found = _environment_block(strip_kdl_comments(text))
    if found is None:
        return text
    line_start, _, closing = found
    end = closing + 1
    if text[end : end + 2] == "\r\n":
        end += 2
    elif text[end : end + 1] == "\n":
        end += 1
    return text[:line_start] + text[end:]


def _statements(stripped: str, start: int, end: int) -> list[tuple[int, int]]:
    """Split a block body into top-level statements, respecting strings/braces."""
    result: list[tuple[int, int]] = []
    depth = 0
    in_string = False
    i = start
    statement_start = start

    while i < end:
        char = stripped[i]
        if in_string:
            if char == "\\" and i + 1 < end:
                i += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
        elif depth == 0 and char in "\n;":
            result.append((statement_start, i))
            statement_start = i + 1
        i += 1

    result.append((statement_start, end))
    return result


def format_value(value: str | None) -> str:
    if value is None:
        return "null"
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def _indent_for(stripped: str, body_start: int, body_end: int, close: int) -> str:
    body = stripped[body_start:body_end]
    for line in body.splitlines():
        if line.strip() and not line.lstrip().startswith("/-"):
            match = re.match(r"[ \t]*", line)
            if match:
                return match.group(0)
    line_start = stripped.rfind("\n", 0, close) + 1
    closing_indent = stripped[line_start:close]
    if closing_indent.strip() == "":
        return closing_indent + "    "
    return "    "


def update_environment(text: str, values: dict[str, str | None]) -> str:
    """Set ``values`` inside the first ``environment {}`` block.

    Existing entries for the same names are replaced in place. Missing names
    are appended to the block. Everything outside the modified values, and all
    comments, is preserved byte for byte. A block is appended when absent.
    """
    stripped = strip_kdl_comments(text)
    block = _environment_block(stripped)

    if block is None:
        lines = ["environment {"]
        lines.extend(f"    {name} {format_value(value)}" for name, value in values.items())
        lines.append("}")
        addition = "\n".join(lines)
        if text and not text.endswith("\n"):
            addition = "\n\n" + addition
        elif text:
            addition = addition + "\n"
        return text + addition

    opening, closing = block[1], block[2]
    body_start = opening + 1
    body_end = closing
    edits: list[tuple[int, int, str]] = []
    present: set[str] = set()

    for start, end in _statements(stripped, body_start, body_end):
        raw = stripped[start:end]
        node = re.match(r"[ \t]*([A-Za-z_][A-Za-z0-9_-]*)", raw)
        if not node:
            continue
        name = node.group(1)
        if name not in values:
            continue
        present.add(name)

        key_end = start + node.end(1)
        rest = stripped[key_end:end]
        trimmed = rest.rstrip()
        if trimmed.endswith(";"):
            trimmed = trimmed[:-1].rstrip()

        rendered = format_value(values[name])
        if not trimmed:
            edits.append((key_end, key_end, " " + rendered))
            continue

        leading = len(trimmed) - len(trimmed.lstrip())
        value_start = key_end + leading
        value_end = key_end + len(trimmed)
        edits.append((value_start, value_end, rendered))

    missing = [name for name in values if name not in present]
    if missing:
        indent = _indent_for(stripped, body_start, body_end, closing)
        lines = [f"{indent}{name} {format_value(values[name])}" for name in missing]
        body = text[body_start:body_end]
        if body.endswith("\n"):
            insertion = "\n".join(lines) + "\n"
        elif body:
            insertion = "\n" + "\n".join(lines) + "\n"
        else:
            insertion = "\n" + "\n".join(lines) + "\n"
        edits.append((closing, closing, insertion))

    result = text
    for start, end, replacement in sorted(edits, key=lambda edit: (edit[0], edit[1]), reverse=True):
        result = result[:start] + replacement + result[end:]
    return result
