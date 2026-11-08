"""Carrier registry.

Adding a carrier means adding ``libexec/carriers/<name>.py`` and appending its
module name to ``MODULES`` below. Nothing in the shared engine changes.
"""

from __future__ import annotations

import importlib

MODULES = (
    "niri",
    "npm",
    "ssh",
)

# Carriers that are shown in status but deliberately cannot be switched in v1.
READ_ONLY = {
    "docker": "read-only: needs root and a daemon restart",
}


def _load():
    carriers = {}
    for module_name in MODULES:
        module = importlib.import_module(f"{__name__}.{module_name}")
        carrier = module.CARRIER
        carriers[carrier.name] = carrier
    return carriers


CARRIERS = _load()


def get(name: str):
    return CARRIERS.get(name)


def names() -> list[str]:
    return list(CARRIERS)


def managed_names() -> list[str]:
    return [name for name, carrier in CARRIERS.items() if carrier.managed]
