"""niri carrier: the six proxy keys inside ``environment { }``."""

from __future__ import annotations

import os
import shutil
import subprocess

from kdl import parse_kdl_environment, update_environment

from .model import Carrier

NAME = "niri"
PROXY_KEYS = (
    "http_proxy",
    "https_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "no_proxy",
    "NO_PROXY",
)


def resolve(context) -> str:
    return os.path.join(context.config_home, "niri", "config.kdl")


def read_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            variables = parse_kdl_environment(handle.read())
    except OSError:
        return "off"
    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        if variables.get(key):
            return "on"
    return "off"


def _values(context, *, on: bool) -> dict[str, str | None]:
    if not on:
        return {key: None for key in PROXY_KEYS}
    return {
        "http_proxy": context.endpoint,
        "https_proxy": context.endpoint,
        "HTTP_PROXY": context.endpoint,
        "HTTPS_PROXY": context.endpoint,
        "no_proxy": context.no_proxy,
        "NO_PROXY": context.no_proxy,
    }


def render_on(text: str, context) -> str:
    return update_environment(text, _values(context, on=True))


def render_off(text: str, context) -> str:
    return update_environment(text, _values(context, on=False))


def after_write(context) -> bool:
    """Ask niri to reload; return whether the reload actually happened."""
    binary = shutil.which("niri")
    if not binary:
        context.warn(
            "niri is not available; the configuration will be picked up on the "
            "next niri reload"
        )
        return False

    try:
        completed = subprocess.run(
            [binary, "msg", "action", "load-config-file"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        context.warn(f"could not ask niri to reload the configuration: {error}")
        return False

    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        if detail:
            context.warn(f"niri did not reload the configuration: {detail}")
        else:
            context.warn(
                "niri did not reload the configuration "
                f"(exit {completed.returncode})"
            )
        return False
    return True


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("niri-spawned processes", "git", "curl", "GUI apps"),
    note="",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    after_write=after_write,
    off_strategy="render",
)
