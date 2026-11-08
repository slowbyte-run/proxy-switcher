"""docker carrier: shown in status but deliberately not managed in v1."""

from __future__ import annotations

from proxy_common import State

from .model import Carrier

NAME = "docker"


def resolve(context) -> str:
    return "/etc/docker/daemon.json"


def read_state(path: str) -> str:
    return State.UNMANAGED.value


def render_on(text: str, context) -> str:
    return text


def render_off(text: str, context, remove_region: bool = False) -> str:
    return text


CARRIER = Carrier(
    name=NAME,
    managed=False,
    tools=("docker daemon",),
    note="read-only: needs root and a daemon restart",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    default_mode=0o644,
)
