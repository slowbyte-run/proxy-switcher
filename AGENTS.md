# AGENTS.md

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `slowbyte-run/proxy-switcher`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.

## What this repo is

`bin/proxy` switches HTTP/HTTPS proxy settings for five "carriers" in a niri session: the niri `environment {}` block, a shell rc snippet, `~/.npmrc`, pnpm's `config.yaml`, and the `github.com` block in `~/.ssh/config`. docker is shown read-only.

No build, no package manager. Python 3.11+ (uses `tomllib`); PyYAML is a test dependency for the pnpm assertions. The gate is `bats tests/` plus `ruff` and `shellcheck`; `.pre-commit-config.yaml` and `.github/workflows/test.yml` both run all three.

## Commands

- `./bin/proxy status` — read-only, safe to run on the real machine
- `./bin/proxy on|off|toggle|restore|env [carrier...]`
- `bats tests/` — full suite, the main gate (`bats --jobs 4` locally when `flock` exists; CI and pre-commit use plain `bats`)
- `bats tests/niri.bats` — one carrier; `bats --filter 'pattern' tests/` — one test
- `uvx ruff check libexec && uvx ruff format --check libexec` — style gate
- `shellcheck -x bin/proxy tests/helpers/fixture.bash` — shell gate

`on`/`off`/`restore` write real files. Use `--dry-run` before touching the live config; add `--json` for a machine-readable plan.

## Architecture

- `bin/proxy` is a thin bash launcher: it resolves its own symlinks, then `exec`s `libexec/proxy_cli.py`. The Python file owns usage text and argument parsing. `tests/contract.bats` fails if the launcher grows a parser or the argument count bound.
- `libexec/` is implicitly on `sys.path` (script directory), so modules use flat imports (`import proxy_engine`, `from carriers import ...`); carrier modules use relative imports (`from .model import Carrier`). Keep `libexec` out of package form and skip path hacks.
- `proxy_engine.py` owns snapshots, conflict detection, atomic writes and the manifest. Carriers resolve a path, render bytes, and may declare `check_rendered` (a warning about the world outside the file, e.g. ssh's `ncat`).
- Adding a carrier: create `libexec/carriers/<name>.py` exporting `CARRIER = Carrier(...)`, then append the module name to `MODULES` in `carriers/__init__.py`. `tests/contract.bats` checks the registry and the directory agree in both directions.
- Config: `$XDG_CONFIG_HOME/proxy-switcher/config.toml` with `endpoint`, `no_proxy`, `exclude`. State: `$XDG_STATE_HOME/proxy-switcher/manifest.json`.
- Every `--json` document carries `schema` (`proxy_common.JSON_SCHEMA`); bump it when a field is added, removed or renamed. Status-bar widgets and TUI wrappers depend on it.

## Semantics that are easy to break

- `off` renders the canonical no-proxy state (niri `null`, shell explicit `unset`, ssh `ProxyCommand none`, npm/pnpm remove their keys). It does **not** restore the snapshot; `restore` does. This is deliberate — see ADR 0003. Do not "fix" `off` into a snapshot restore.
- `off` must never create a file or block that did not exist. `Carrier.delete_created_file` handles this; the shell rc is the deliberate exception because its `unset` lines are what override the niri block.
- The six proxy variables, their value mapping, line-ending detection and quoting live in `proxy_common.py`. `tests/contract.bats` fails on a carrier that spells a variable name out.
- `NODE_USE_ENV_PROXY` is an enabler, not a proxy value: `on` writes it to both env carriers, `off` removes it only from the niri block and never unsets it in the shell snippet (that would clobber a hand-written line). It never affects carrier state. See ADR 0004.
- Edit niri KDL through `libexec/kdl.py`; it preserves comments and offsets. Do not regex the config.
- pnpm's YAML is edited line by line on purpose: a PyYAML round-trip drops comments and reflows the file. Do not simplify it into a parser round-trip.
- npm must preserve mode 0600 and replace existing keys in place instead of appending duplicates.
- ssh must leave every other Host block byte-identical. Tests assert `ssh -G -F <fixture>` because `ssh -G` ignores `$HOME`.
- A newer manifest (`version` above `MANIFEST_VERSION`) is refused with exit 1 rather than rewritten; `status` degrades to "nothing pending" instead of failing, because it is a read-only view.

## Testing

- Every bats test must call `fixture_init`. It points `HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at `$BATS_TEST_TMPDIR` and puts a stub `niri` first on `PATH`.
- Tests stay offline, avoid sudo, and touch only the fixture tree.
- Use the fixture's `run_proxy` helper; shared helpers live in `tests/helpers/fixture.bash`.
- Add per-carrier tests in `tests/<carrier>.bats` and cross-carrier behaviour in `tests/aggregate.bats`. Launch/install behaviour goes in `tests/launcher.bats`; architecture rules go in `tests/contract.bats`.

## Conventions

- Exit codes: `0` success, `1` conflict or execution failure, `2` usage error.
- Code and code comments are English; docs, commit messages and issue text are Chinese.
- Work is tracked as GitHub issues and closed with a comment plus `gh issue close`.
