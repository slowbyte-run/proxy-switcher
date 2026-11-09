# proxy-switcher

A command-line tool that switches HTTP/HTTPS proxy settings for every tool in a [niri](https://github.com/niri-wm/niri) session with one command.

[中文](README.md) | **English**

<!-- Badge Row 1: Core Info -->
[![GitHub](https://img.shields.io/badge/GitHub-slowbyte--run-181717?logo=github)](https://github.com/slowbyte-run/proxy-switcher)
[![Version](https://img.shields.io/badge/version-0.1.0-orange)](https://github.com/slowbyte-run/proxy-switcher)

<!-- Badge Row 3: Tech Stack -->
[![Python](https://img.shields.io/badge/Python-3.11%2B-3776AB?logo=python)](https://python.org)

<!-- Badge Row 4: Platforms -->
[![Linux](https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black)](https://github.com/slowbyte-run/proxy-switcher)

<!-- Badge Row 5: License -->
[![License](https://img.shields.io/badge/License-MIT-BD2D2D)](LICENSE)

## Table of Contents

- [Why this exists](#why-this-exists)
- [Features](#features)
- [How it works](#how-it-works)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Configuration](#configuration)
- [Carriers](#carriers)
- [Exit codes](#exit-codes)
- [Testing](#testing)
- [Known limitations](#known-limitations)
- [Development](#development)
- [License](#license)

## Why this exists

Proxy clients such as FlClash usually implement their "system proxy" switch by editing GNOME's gsettings or KDE's `kioslaverc`. niri is neither, and most command-line programs only read `http_proxy`, `https_proxy` and their own config files.

The result is proxy settings scattered across half a dozen unrelated places: the niri `environment {}` block, shell startup files, `~/.npmrc`, pnpm's config, `~/.ssh/config`, and docker's `daemon.json`. Turning the proxy off means editing each file by hand; miss one and you leave a stale proxy pointing at a dead port.

`proxy-switcher` treats those places as managed "carriers" and switches them with one command, snapshotting before every change.

## Features

- **One command** to turn everything on, off, or toggle it.
- **Five carriers, one source of truth**: niri environment, shell rc, npm, pnpm, ssh; docker is read-only.
- **Reversible**: `restore` recovers the exact bytes from before the switch.
- **Verifiable**: `off` removes the variables for real, so `env | grep -i proxy` proves it.
- **Node fetch included**: `on` also writes `NODE_USE_ENV_PROXY=1`, because Node 24+'s `fetch` ignores the environment by default.
- **Conflict detection**: refuses to overwrite a file edited since the last switch unless `--force` is given.
- **Atomic writes** with the original permission bits preserved.
- **No third-party runtime dependencies**: Python 3.11+ standard library only.

## How it works

A carrier is a file location that holds proxy settings. The shared engine owns snapshots, conflict detection, atomic writes and the manifest; a carrier only describes its path and how to render `on` and `off`.

| Carrier | Location | Written | Affects |
| --- | --- | --- | --- |
| `niri` | `environment {}` in `~/.config/niri/config.kdl` | six proxy keys + `NODE_USE_ENV_PROXY` | niri-spawned processes, non-interactive git/curl, GUI apps |
| `shell` | `~/.zshrc` or `~/.bashrc` | six `export` / `unset` lines + `NODE_USE_ENV_PROXY` | interactive shells, and git/curl inside them |
| `npm` | `~/.npmrc` | `proxy`, `https-proxy`, `noproxy` | npm, yarn v1 |
| `pnpm` | `~/.config/pnpm/config.yaml` | `httpProxy`, `httpsProxy`, `noProxy` | pnpm |
| `ssh` | `github.com` block in `~/.ssh/config` | `ProxyCommand` | GitHub SSH |
| `docker` | `/etc/docker/daemon.json` | read-only display | docker daemon |

**Precedence**: interactive shells follow the `shell` carrier; every other process spawned by niri follows the `niri` carrier. Both therefore write explicit `unset` / `null` when turned off, instead of relying on a missing key.

Concretely for git and curl: commands you type in a terminal belong to an interactive shell, so the `shell` carrier governs them. With `shell` off they get no proxy even when `niri` is on. Only processes that niri or a GUI app spawns directly, without going through a shell rc, belong to the `niri` carrier.

After writing the niri config the tool calls `niri msg action load-config-file`, which applies to processes spawned from then on.

## Installation

Requires Linux with niri, Python 3.11+, and optionally the `niri` binary.

```bash
git clone https://github.com/slowbyte-run/proxy-switcher
cd proxy-switcher
export PATH="$PWD/bin:$PATH"
```

No build step and no package manager. Running the tests requires [bats](https://github.com/bats-core/bats-core) and PyYAML.

## Quick start

Inspect the current state (read-only and safe):

```bash
proxy status
```

Preview what would change:

```bash
proxy --dry-run on
```

Turn every carrier on and load the state into the current shell:

```bash
proxy on
eval "$(proxy env)"
```

Turn the proxy off:

```bash
proxy off
```

Toggle only pnpm, or check whether the local proxy port is listening:

```bash
proxy toggle pnpm
proxy status --check
```

Recover the files as they were before the first switch:

```bash
proxy restore
```

## Commands

| Command | Description |
| --- | --- |
| `proxy on [carrier...]` | Turn on; no argument means every managed carrier |
| `proxy off [carrier...]` | Render the canonical no-proxy state |
| `proxy toggle [carrier...]` | Turn everything on unless every selected carrier is already on |
| `proxy restore [carrier...]` | Restore the pre-switch snapshot byte for byte |
| `proxy status [--check] [--json]` | Show state; `--check` probes the endpoint port, `--json` emits machine-readable output |
| `proxy env [--json]` | Print `export` / `unset` statements for `eval`; `--json` emits the same decisions as data |

| Option | Applies to | Description |
| --- | --- | --- |
| `--proxy <url>` | all commands | Override the configured endpoint |
| `--force` | switch and restore | Bypass conflict detection |
| `--dry-run` | switch and restore | Print carriers and files without writing |
| `-v`, `--verbose` | switch and restore | Explain what happened per carrier |
| `--check` | `status` | Bounded local TCP probe; no HTTP request |
| `--json` | `status`, `env`, `--dry-run` | Machine-readable output; carries a top-level `schema` field |
| `-V`, `--version` | all commands | Print the version and exit |
| `-h`, `--help` | all commands | Show help |

The machine-readable output is the integration surface for status bars and wrapper scripts: `proxy status --json` reports every carrier, and `proxy --dry-run on --json` returns the full change plan including conflicts and failures. Both carry `schema`, bumped whenever a field changes. There is no TUI yet.

The difference between `off` and `restore` is deliberate: `off` renders "no proxy configured", while `restore` rolls the bytes back. The original file may already contain proxy values, so making `off` a rollback would turn "off" into "put the proxy back". See [ADR 0003](docs/adr/0003-off-renders-no-proxy-restore-recovers.md).

## Configuration

The config file lives at `$XDG_CONFIG_HOME/proxy-switcher/config.toml` (usually `~/.config/proxy-switcher/config.toml`):

```toml
endpoint = "http://127.0.0.1:7890"
no_proxy = "localhost,127.0.0.1,::1"
exclude = ["ssh"]
```

| Key | Default | Description |
| --- | --- | --- |
| `endpoint` | `http://127.0.0.1:7890` | Proxy endpoint; http URLs only |
| `no_proxy` | `localhost,127.0.0.1,::1` | Domain and IP literals only; no CIDR semantics |
| `exclude` | `[]` | Carrier names that are never touched |

State and snapshots live in `$XDG_STATE_HOME/proxy-switcher/manifest.json`.

## Carriers

**niri**: rewrites only the six proxy keys and `NODE_USE_ENV_PROXY` inside `environment {}`, preserving every other variable and comment. `off` writes `null` to remove them explicitly; a block created by `on` is removed again by `off`. It affects processes niri spawns directly (GUI apps, terminal windows); git/curl only count when they bypass the shell rc.

**shell**: maintains a marked snippet. `on` writes six `export` lines plus `export NODE_USE_ENV_PROXY=1`; `off` writes six explicit `unset` lines so they override the niri block. **`off` deliberately does not unset the Node flag** — it only enables Node to read the six variables, and you may have set it yourself outside the snippet; removing it would silently override that. The rc file follows `$SHELL`: `~/.zshrc` or `~/.bashrc`, defaulting to zsh. It governs git/curl in a terminal.

**npm / pnpm**: each writes three keys to its own file. npm keeps mode 0600 and replaces existing keys instead of appending duplicates; pnpm is edited line by line so comments and indentation survive.

**ssh**: rewrites only the `ProxyCommand` inside the `github.com` block, writing `none` on `off`; every other Host block stays byte-identical. With the proxy off, GitHub SSH connects directly — if direct access is blocked, `git push` fails, and `status` says so.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Conflict or execution failure |
| `2` | Usage error |

## Testing

```bash
bats tests/
```

Every test builds a throwaway `HOME` and XDG tree under `$BATS_TEST_TMPDIR` and puts a stub `niri` first on `PATH`. The suite is offline, never uses sudo, and never touches the real user configuration or a real compositor.

```bash
bats tests/niri.bats
bats --filter 'restore' tests/
```

## Known limitations

- Linux + niri only; other desktops are untested.
- docker is read-only: editing `daemon.json` needs root and a daemon restart, which stops running containers.
- systemd `--user` services are not managed: `set-environment` cannot reach processes niri already spawned.
- Running processes are never updated; only newly spawned ones see the change.
- Apps launched from the DMS launcher inherit DMS's startup environment and may need a DMS restart.
- `all_proxy` / `ALL_PROXY` are never written, and FlClash's private config is never parsed.
- No TUI and no status-bar plugin yet.

## Development

```
bin/proxy                 launcher; only execs the Python entry point
libexec/proxy_cli.py      the single argument parser and usage text
libexec/proxy_engine.py   snapshots, conflict detection, atomic writes, manifest
libexec/proxy_helper.py   config, status output, env, port probe
libexec/proxy_common.py   the six variables, state enums, shared text helpers
libexec/kdl.py            comment- and offset-preserving KDL editing
libexec/carriers/         one module per carrier plus the registry
tests/                    bats black-box tests
```

Adding a carrier takes two steps: create a module under `libexec/carriers/` exporting `CARRIER`, then append its name to `MODULES` in `carriers/__init__.py`. The shared engine does not change.

## License

[MIT](LICENSE)
