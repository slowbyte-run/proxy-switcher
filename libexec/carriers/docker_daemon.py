"""docker-daemon carrier: the daemon's own proxy, shown read-only.

``/etc/docker/daemon.json`` can carry a ``proxies`` block that dockerd uses for
``pull``/``push``. Editing it needs root and a daemon restart, and a restart
stops running containers, so it stays read-only (ADR 0002). The user-level
half -- the proxy environment containers get -- is the ``docker`` carrier.
"""

from __future__ import annotations

from proxy_common import State

from .model import Carrier

NAME = "docker-daemon"


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
    note="read-only: pull/push need root and a daemon restart",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    default_mode=0o644,
)
