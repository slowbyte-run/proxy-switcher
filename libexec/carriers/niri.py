"""niri carrier: the six proxy keys inside ``environment { }``."""

from __future__ import annotations

import os
import shutil
import subprocess

from kdl import (
    environment_block_exists,
    parse_kdl_environment,
    remove_environment_block,
    update_environment,
)
from proxy_common import (
    NODE_FETCH_VALUE,
    NODE_FETCH_VAR,
    PROXY_URL_VARS,
    PROXY_VARS,
    proxy_values,
)

from .model import Carrier

NAME = "niri"


def resolve(context) -> str:
    return os.path.join(context.config_home, "niri", "config.kdl")


def read_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            variables = parse_kdl_environment(handle.read())
    except OSError:
        return "off"
    for key in PROXY_URL_VARS:
        if variables.get(key):
            return "on"
    return "off"


def region_exists(text: str) -> bool:
    return environment_block_exists(text)


def _values(context) -> dict[str, str | None]:
    values: dict[str, str | None] = dict(
        proxy_values(context.endpoint, context.no_proxy)
    )
    values[NODE_FETCH_VAR] = NODE_FETCH_VALUE
    return values


def render_on(text: str, context) -> str:
    return update_environment(text, _values(context))


def render_off(text: str, context, remove_region: bool = False) -> str:
    if remove_region:
        return remove_environment_block(text)
    keys = (*PROXY_VARS, NODE_FETCH_VAR)
    return update_environment(text, {key: None for key in keys})


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
                f"niri did not reload the configuration (exit {completed.returncode})"
            )
        return False
    return True


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("niri-spawned processes", "non-interactive git/curl", "GUI apps"),
    note="",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    after_write=after_write,
    region_exists=region_exists,
)
