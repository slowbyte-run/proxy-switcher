"""The small interface every proxy carrier implements.

A carrier describes one place that holds proxy settings. It resolves its path,
reads its current switch state, renders the file contents for ``on`` and
``off``, and may run a hook after a successful write. The shared engine in
``proxy_engine.py`` owns snapshots, conflict detection, atomic writes and the
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
    render_on: Callable[..., str]
    render_off: Callable[..., str]
    after_write: Callable[[Any], bool] | None = None
    # Shown instead of ``note`` while the carrier is off (for consequences that
    # only apply to the off state, such as ssh direct access being unreachable).
    note_off: str = ""
    # Whether the carrier's managed region already existed in the original
    # text. Only carriers that can create a new region (niri, ssh) need this;
    # the others default to the whole file's existence.
    region_exists: Callable[[str], bool] | None = None
    # Whether ``off`` should delete a file that ``on`` created. The shell rc is
    # the exception: its explicit ``unset`` lines are what override niri, so the
    # file must stay even when it did not exist before ``on``.
    delete_created_file: bool = True
    default_mode: int = 0o644
