"""The small interface every proxy carrier implements.

A carrier describes one place that holds proxy settings. It resolves its path,
reads its current switch state, renders the file contents for ``on`` and
``off``, and may run a hook after a successful write. The shared engine in
``engine.py`` owns snapshots, conflict detection, atomic writes and the
manifest; carriers know nothing about those.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable


@dataclass(frozen=True)
class Carrier:
    name: str
    managed: bool
    tools: tuple[str, ...]
    note: str
    resolve: Callable[[Any], str]
    read_state: Callable[[str], str]
    render_on: Callable[[str, Any], str]
    render_off: Callable[[str, Any], str]
    after_write: Callable[[Any], None] | None = None
    # ``render`` writes an explicit off value (niri uses ``null``);
    # ``restore`` puts the pre-switch snapshot back byte for byte.
    off_strategy: str = "render"
    default_mode: int = 0o644
