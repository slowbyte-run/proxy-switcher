#!/usr/bin/env python3
"""Single command-line entry point for proxy-switcher.

Keeping option parsing and usage in one file means the bash launcher cannot
drift from the Python engine. The launcher only execs this module.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from urllib.parse import urlsplit

import proxy_engine
import proxy_helper
from carriers import managed_names
from proxy_common import VERSION, Action
from proxy_engine import Context, EngineError, UsageError

USAGE = """Usage: proxy <command> [options] [carrier...]

Commands:
  on [carrier...]       Turn managed carriers on (default: every managed carrier)
  off [carrier...]      Render the canonical no-proxy state
  toggle [carrier...]   Turn on unless every selected carrier is already on
  restore [carrier...]  Restore the pre-switch snapshot byte for byte
  status [--check] [--json]
                        Show the state of every proxy carrier
  env [--json]          Print export/unset statements for eval

Options:
  --proxy <url>         Override the configured proxy endpoint (all commands)
  --json                Machine-readable output (status, env, --dry-run)
  -V, --version         Show the version and exit
  -h, --help            Show this help

Options for on/off/toggle/restore:
  --force               Overwrite a file that changed since the last switch
  --dry-run             Show what would change without writing
  -v, --verbose         Explain what was done for each carrier

Options for status:
  --check               Probe the endpoint with a bounded local TCP connect

Configuration:
  $XDG_CONFIG_HOME/proxy-switcher/config.toml accepts endpoint, no_proxy
  and exclude (a list of carrier names to leave alone).

Exit status: 0 success, 1 conflict/failure, 2 usage error.
"""

SWITCH_COMMANDS = {
    "on": Action.ON,
    "off": Action.OFF,
    "toggle": Action.TOGGLE,
    "restore": Action.RESTORE,
}
READ_COMMANDS = {"status", "env"}


@dataclass
class Parsed:
    command: str | None = None
    carriers: list[str] | None = None
    proxy: str | None = None
    force: bool = False
    dry_run: bool = False
    verbose: bool = False
    check: bool = False
    json: bool = False
    help: bool = False
    version: bool = False


def _parse_proxy(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme != "http" or not parsed.netloc:
        raise UsageError(
            f"--proxy must be an http URL such as {proxy_helper.DEFAULT_ENDPOINT}"
        )
    return value


def parse(argv: list[str]) -> Parsed:
    parsed = Parsed(carriers=[])
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument in ("-h", "--help"):
            parsed.help = True
            index += 1
        elif argument in ("-V", "--version"):
            parsed.version = True
            index += 1
        elif argument == "--proxy":
            if index + 1 >= len(argv):
                raise UsageError("--proxy requires an argument")
            parsed.proxy = _parse_proxy(argv[index + 1])
            index += 2
        elif argument.startswith("--proxy="):
            parsed.proxy = _parse_proxy(argument.split("=", 1)[1])
            index += 1
        elif argument == "--force":
            parsed.force = True
            index += 1
        elif argument == "--dry-run":
            parsed.dry_run = True
            index += 1
        elif argument in ("-v", "--verbose"):
            parsed.verbose = True
            index += 1
        elif argument == "--check":
            parsed.check = True
            index += 1
        elif argument == "--json":
            parsed.json = True
            index += 1
        elif argument.startswith("-"):
            raise UsageError(f"unknown argument: {argument}")
        elif parsed.command is None:
            parsed.command = argument
            index += 1
        else:
            parsed.carriers.append(argument)
            index += 1
    return parsed


def _reject_options(parsed: Parsed, command: str) -> None:
    if parsed.command == "status":
        if parsed.force or parsed.dry_run or parsed.verbose:
            raise UsageError(
                "--force, --dry-run and --verbose are only for switch commands"
            )
        if parsed.carriers:
            raise UsageError(f"unknown argument: {parsed.carriers[0]}")
        return
    if parsed.command == "env":
        if parsed.force or parsed.dry_run or parsed.verbose:
            raise UsageError(
                "--force, --dry-run and --verbose are only for switch commands"
            )
        if parsed.check:
            raise UsageError("--check is only for status")
        if parsed.carriers:
            raise UsageError(f"unknown argument: {parsed.carriers[0]}")
        return
    if parsed.check:
        raise UsageError("--check is only for status")
    if parsed.json and not parsed.dry_run:
        raise UsageError("--json is only for status, env and --dry-run")


def _settings_endpoint(override: str | None) -> tuple[str, str, tuple[str, ...]]:
    settings = proxy_helper.load_settings()
    endpoint = override or settings.endpoint
    return endpoint, settings.no_proxy, settings.exclude


def _build_context(
    proxy: str | None, force: bool, dry_run: bool, verbose: bool, as_json: bool
) -> tuple[Context, str, str]:
    endpoint, no_proxy, excluded = _settings_endpoint(proxy)
    context = Context(
        home=proxy_helper.home_dir(),
        config_home=proxy_helper.config_home(),
        state_root=proxy_helper.state_path(),
        endpoint=endpoint,
        no_proxy=no_proxy,
        excluded=frozenset(excluded),
        force=force,
        dry_run=dry_run,
        verbose=verbose,
        json=as_json,
    )
    return context, endpoint, no_proxy


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write(USAGE)
        return 2

    try:
        parsed = parse(argv)
        if parsed.version:
            print(f"proxy-switcher {VERSION}")
            return 0
        if parsed.help or parsed.command == "help":
            print(USAGE, end="")
            return 0
        if parsed.command is None:
            sys.stderr.write(USAGE)
            return 2
        if (
            parsed.command not in SWITCH_COMMANDS
            and parsed.command not in READ_COMMANDS
        ):
            print(f"proxy: unknown command: {parsed.command}", file=sys.stderr)
            sys.stderr.write(USAGE)
            return 2

        _reject_options(parsed, parsed.command)

        if parsed.command == "status":
            print(
                proxy_helper.status_output(
                    check=parsed.check,
                    as_json=parsed.json,
                    endpoint=parsed.proxy,
                )
            )
            return 0

        if parsed.command == "env":
            endpoint, no_proxy, _ = _settings_endpoint(parsed.proxy)
            print(proxy_helper.env_output(endpoint, no_proxy, as_json=parsed.json))
            return 0

        context, _, _ = _build_context(
            parsed.proxy, parsed.force, parsed.dry_run, parsed.verbose, parsed.json
        )
        action = SWITCH_COMMANDS[parsed.command]
        explicit = bool(parsed.carriers)
        names = parsed.carriers or managed_names()
        return proxy_engine.switch(context, action, names, explicit=explicit)
    except proxy_helper.ConfigError as error:
        print(f"proxy: {error}", file=sys.stderr)
        return 1
    except UsageError as error:
        if str(error):
            print(f"proxy: {error}", file=sys.stderr)
        sys.stderr.write(USAGE)
        return 2
    except EngineError as error:
        print(f"proxy: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
