"""docker carrier: the container proxies in ``~/.docker/config.json``.

docker has two proxy layers. The daemon's ``pull``/``push`` proxy lives in
``/etc/docker/daemon.json`` and needs root plus a restart, so it stays
read-only (the ``docker-daemon`` carrier). This one owns the other layer: the
``proxies.default`` block the CLI reads when it creates containers and runs
builds. That file is user-owned and applies immediately, which makes it the
only docker proxy a plain switch can fix.

Two details make it unlike the other carriers:

* The endpoint is not the host endpoint. Inside a container ``127.0.0.1`` is
  the container itself, so a loopback endpoint is rewritten to the docker
  bridge gateway, and ``container_endpoint`` overrides the guess.
* The file belongs to docker: ``login``, token refresh and ``context use``
  rewrite it whole. Conflict detection therefore fingerprints only the two
  keys this carrier owns; ``auths``, per-daemon entries and ``noProxy`` are
  preserved untouched.
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import shutil
import subprocess
from urllib.parse import urlsplit, urlunsplit

from .model import Carrier, CarrierError, CarrierWarning

NAME = "docker"
# The two keys this carrier owns. ``noProxy`` is deliberately absent: the
# container-side exemption list is project-specific (service names, internal
# APIs) and must not be replaced by the host-wide one.
KEYS = ("httpProxy", "httpsProxy")
# Proxy keys docker honours that this carrier leaves alone. Their presence is
# worth a warning: after ``off`` they can still send containers through a proxy.
UNMANAGED_KEYS = ("allProxy", "ftpProxy")
DOCKER_TIMEOUT_SECONDS = 3.0


def resolve(context) -> str:
    directory = os.environ.get("DOCKER_CONFIG")
    if not directory:
        directory = os.path.join(context.home, ".docker")
    return os.path.join(os.path.expanduser(directory), "config.json")


def read_state(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return "off"
    try:
        default = _default_block(json.loads(text))
    except ValueError:
        return "off"
    if not isinstance(default, dict):
        return "off"
    return "on" if all(default.get(key) for key in KEYS) else "off"


def render_on(text: str, context) -> str:
    endpoint, problem = _container_endpoint(context)
    if endpoint is None:
        # Leave the file alone: writing the host endpoint would point containers
        # at themselves, which is worse than doing nothing. The engine turns
        # this into a plan warning, so the switch still succeeds and --json
        # reports why nothing was written.
        raise CarrierWarning(problem)
    document = _load(text)
    proxies = document.setdefault("proxies", {})
    _require_object(proxies, "proxies")
    default = proxies.setdefault("default", {})
    _require_object(default, "proxies.default")
    for key in KEYS:
        default[key] = endpoint
    return _dump(document)


def render_off(text: str, context, remove_region: bool = False) -> str:
    # Never delete the file: docker may have written auths into it after ``on``
    # created it. Removing the keys is the whole job.
    if not text.strip():
        return text
    document = _load(text)
    proxies = document.get("proxies")
    if not isinstance(proxies, dict):
        return text
    default = proxies.get("default")
    if not isinstance(default, dict):
        return text
    if not any(key in default for key in KEYS):
        return text
    for key in KEYS:
        default.pop(key, None)
    if not default:
        proxies.pop("default", None)
    if not proxies:
        document.pop("proxies", None)
    return _dump(document)


def check_rendered(text: str | None) -> str:
    if not text:
        return ""
    try:
        default = _default_block(json.loads(text))
    except ValueError:
        return "config.json is not valid JSON; docker ignores its proxies"
    if not isinstance(default, dict):
        return ""
    problems = []
    if any(key in default for key in UNMANAGED_KEYS):
        problems.append(
            "allProxy/ftpProxy are not managed; containers may still use them"
        )
    for key in KEYS:
        value = default.get(key)
        if isinstance(value, str) and _is_loopback(urlsplit(value).hostname or ""):
            problems.append(f"{key} points at loopback, which containers cannot reach")
            break
    return "; ".join(problems)


def managed_fingerprint(text: str | None) -> str | None:
    """Hash only the two keys this carrier owns.

    docker rewrites config.json on login, token refresh and context switches.
    A whole-file hash would turn every one of those into a conflict the next
    time proxysw runs, so the manifest stores this fingerprint instead.
    """
    if text is None:
        return None
    try:
        default = _default_block(json.loads(text)) if text.strip() else {}
    except ValueError as error:
        raise CarrierError(f"config.json is not valid JSON: {error}") from error
    values = [default.get(key) if isinstance(default, dict) else None for key in KEYS]
    payload = json.dumps(values, sort_keys=True)
    return "sha256:" + hashlib.sha256(payload.encode()).hexdigest()


def _default_block(document) -> dict | None:
    if not isinstance(document, dict):
        return None
    proxies = document.get("proxies")
    if not isinstance(proxies, dict):
        return None
    return proxies.get("default")


def _load(text: str) -> dict:
    if not text.strip():
        return {}
    try:
        document = json.loads(text)
    except ValueError as error:
        raise CarrierError(f"config.json is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise CarrierError("config.json must be a JSON object")
    return document


def _require_object(value, name: str) -> None:
    if not isinstance(value, dict):
        raise CarrierError(f"{name} in config.json is not a JSON object")


def _dump(document: dict) -> str:
    return json.dumps(document, indent=4, ensure_ascii=False) + "\n"


def _container_endpoint(context) -> tuple[str | None, str]:
    """The proxy address a container can reach, or ``None`` and why not."""
    configured = (getattr(context, "container_endpoint", "") or "").strip()
    if configured:
        return configured, ""
    endpoint = context.endpoint
    if not _is_loopback(urlsplit(endpoint).hostname or ""):
        return endpoint, ""
    gateway = _bridge_gateway()
    if not gateway:
        return None, (
            "cannot resolve the container-side address; start the docker "
            "daemon or set container_endpoint in config.toml"
        )
    return _replace_host(endpoint, gateway), ""


def _replace_host(endpoint: str, host: str) -> str:
    parsed = urlsplit(endpoint)
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    userinfo, at, _hostport = parsed.netloc.rpartition("@")
    hostport = host if parsed.port is None else f"{host}:{parsed.port}"
    netloc = f"{userinfo}@{hostport}" if at else hostport
    return urlunsplit(
        (parsed.scheme, netloc, parsed.path, parsed.query, parsed.fragment)
    )


def _bridge_gateway() -> str:
    """The host's address on docker's default bridge network."""
    executable = shutil.which("docker")
    if executable is None:
        return ""
    try:
        completed = subprocess.run(
            [
                executable,
                "network",
                "inspect",
                "bridge",
                "--format",
                "{{(index .IPAM.Config 0).Gateway}}",
            ],
            capture_output=True,
            text=True,
            timeout=DOCKER_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if completed.returncode != 0:
        return ""
    gateway = completed.stdout.strip()
    return gateway if gateway and "\n" not in gateway else ""


def _is_loopback(host: str) -> bool:
    if not host:
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


CARRIER = Carrier(
    name=NAME,
    managed=True,
    tools=("docker run/build", "docker compose"),
    note="new containers and builds only; pull goes through docker-daemon",
    resolve=resolve,
    read_state=read_state,
    render_on=render_on,
    render_off=render_off,
    delete_created_file=False,
    default_mode=0o600,
    check_rendered=check_rendered,
    managed_fingerprint=managed_fingerprint,
)
