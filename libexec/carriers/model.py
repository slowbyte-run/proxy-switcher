"""The small interface every proxy carrier implements.

A carrier describes one place that holds proxy settings. It resolves its path,
reads its current switch state, renders the file contents for ``on`` and
``off``, and may run a hook after a successful write. The shared engine in
``proxy_engine.py`` owns snapshots, conflict detection, atomic writes and the
manifest; carriers know nothing about those.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


class CarrierError(Exception):
    """A carrier cannot read or render its file.

    Reported as a per-carrier failure (exit 1) rather than a crash: a broken
    ``~/.docker/config.json`` must not take the whole switch down with a
    traceback, and the other carriers still need their chance to run.
    """


class CarrierWarning(Exception):
    """The carrier cannot act right now, but the switch should still succeed.

    Docker raises it when the daemon is unreachable and the container-side
    address cannot be derived. The file is left alone and the message travels
    in the plan's ``warning`` field, so ``--json`` and the TUI see it too.
    """


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
    # Rendered content can depend on something outside the file -- ssh shells
    # out to ``ncat``. Called with the text the carrier is about to write (or,
    # for ``status``, the text already on disk) and returns a warning, which the
    # engine prints before writing and ``status`` appends to the note.
    check_rendered: Callable[[str | None], str] | None = None
    # Conflict detection hashes the whole file by default. A carrier whose file
    # another tool rewrites in full (docker rewrites config.json on login, token
    # refresh and context switches) can fingerprint only the region it owns, so
    # unrelated edits do not look like a conflict. The engine compares and
    # stores this value in place of the file hash; ``restore`` still replays the
    # whole-file snapshot.
    managed_fingerprint: Callable[[str | None], str | None] | None = None
