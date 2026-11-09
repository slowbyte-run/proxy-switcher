"""npm carrier: the proxy keys in ``~/.npmrc``.

npm and yarn v1 both read this file, so the status row names both tools and the
carrier writes ``proxy``, ``https-proxy`` and ``noproxy``. ``off`` removes
those three keys: absence is npm's canonical "no proxy" state. The original
bytes are kept in the snapshot for the explicit ``restore`` command.
"""

from __future__ import annotations

import os
import re

from proxy_common import line_ending, unquote

from .model import Carrier

NAME = "npm"
KEYS = ("proxy", "https-proxy", "noproxy")

_ASSIGNMENT = re.compile(r"^\s*([^=\s][^=]*?)\s*=")


def resolve(context) -> str:
    return os.path.join(context.home, ".npmrc")


def read_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
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


def region_exists(text: str) -> bool:
    for line in text.splitlines():
        key = _key_of(line.rstrip("\r\n"))
        if key in KEYS:
            return True
    return False


def _values(context) -> dict[str, str]:
    return {
        "proxy": context.endpoint,
        "https-proxy": context.endpoint,
        "noproxy": context.no_proxy,
    }


def _key_of(body: str) -> str | None:
    stripped = body.lstrip()
    if not stripped or stripped[0] in "#;":
        return None
    match = _ASSIGNMENT.match(body)
    return match.group(1).strip().lower() if match else None


def _indent_of(body: str) -> str:
    return body[: len(body) - len(body.lstrip())]


def _update(text: str, values: dict[str, str]) -> str:
    """Replace the managed keys in place, drop duplicates, then append any missing."""
    ending = line_ending(text)
    lines = text.splitlines(keepends=True)
    seen: set[str] = set()
    updated: list[str] = []

    for line in lines:
        body = line.rstrip("\r\n")
        line_ending_ = line[len(body) :]
        key = _key_of(body)
        if key in values:
            if key in seen:
                continue
            seen.add(key)
            updated.append(
                f"{_indent_of(body)}{key}={values[key]}{line_ending_ or ending}"
            )
        else:
            updated.append(line)

    missing = [key for key in KEYS if key not in seen]
    if missing:
        if updated and not updated[-1].endswith(("\n", "\r")):
            updated[-1] += ending
        for key in missing:
            updated.append(f"{key}={values[key]}{ending}")

    return "".join(updated)


def _remove(text: str, keys: tuple[str, ...]) -> str:
    """Remove every line that assigns one of ``keys``."""
    kept: list[str] = []
    for line in text.splitlines(keepends=True):
        key = _key_of(line.rstrip("\r\n"))
        if key in keys:
            continue
        kept.append(line)
    return "".join(kept)


def render_on(text: str, context) -> str:
    path = resolve(context)
    if not os.path.exists(path):
        # Progress detail, not a result: it goes to stderr through
        # ``context.info`` so a ``--json`` document on stdout stays parseable.
        if context.dry_run:
            context.info(f"npm: {path} does not exist; it would be created")
        else:
            context.info(f"npm: {path} did not exist; creating it")
    return _update(text, _values(context))


def render_off(text: str, context, remove_region: bool = False) -> str:
    return _remove(text, KEYS)


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("npm", "yarn v1"),
    note="npm and yarn v1 share this file",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    region_exists=region_exists,
    default_mode=0o600,
)
