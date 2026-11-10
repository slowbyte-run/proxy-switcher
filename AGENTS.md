# AGENTS.md

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `slowbyte-run/proxy-switcher`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles, each label string equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.

## What this repo is

`bin/proxysw` switches HTTP/HTTPS proxy settings for five "carriers" in a niri session: the niri `environment {}` block, a shell rc snippet, `~/.npmrc`, pnpm's `config.yaml`, and the `github.com` block in `~/.ssh/config`. docker is shown read-only.

No build, no package manager. Python 3.11+ (uses `tomllib`); PyYAML is a test dependency for the pnpm assertions. `./scripts/check` is the gate — `ruff`, `shellcheck` and `bats tests/` — and it pins the same tool versions as `.pre-commit-config.yaml`. CI runs the same three tools as separate steps; change a version in all three places or none.

## Commands

- `./scripts/check` — the gate: `ruff` (check + format), `shellcheck`, then `bats tests/`. Run this before saying a change is done.
- `./scripts/check lint` — style only, ~0.2s; `PROXYSW_CHECK_JOBS=8 ./scripts/check` — parallel suite locally
- `bats tests/niri.bats` — one carrier; `bats --filter 'pattern' tests/` — one test
- `./bin/proxysw status` — read-only, safe to run on the real machine
- `./bin/proxysw on|off|toggle|restore|env [carrier...]`
- `./bin/proxysw tui [on|off|toggle]` — optional fzf picker; needs an interactive terminal and fzf (missing fzf → exit 2)

`on`/`off`/`restore` write real files. Use `--dry-run` before touching the live config. Add `--json` for a machine-readable document; the executing command and the dry run return the same shape, told apart by `dry_run`.

## Architecture

- `bin/proxysw` is a thin bash launcher: it resolves its own symlinks, then `exec`s `libexec/proxy_cli.py`. The Python file owns usage text and argument parsing. `tests/contract.bats` fails if the launcher grows a parser or the argument count bound.
- `libexec/` is implicitly on `sys.path` (script directory), so modules use flat imports (`import proxy_engine`, `from carriers import ...`); carrier modules use relative imports (`from .model import Carrier`). Keep `libexec` out of package form and skip path hacks.
- `proxy_engine.py` owns snapshots, conflict detection, atomic writes and the manifest. Carriers resolve a path, render bytes, and may declare `check_rendered` (a warning about the world outside the file, e.g. ssh's `ncat`).
- One switch runs in this order, and the order is the contract: `switch` → `select_carriers` → [`state_lock`] → `_switch` → `resolve_action` → `load_manifest` → `build_plans` → `_apply_plan` per carrier → `save_manifest`. `--dry-run` takes no lock and stops after `build_plans`. It is the largest file in `libexec/`; read that sequence before editing it, because a change in the wrong stage silently breaks the transaction.
- Three output channels, and mixing them breaks `--json`: `context.info` (progress detail, always stderr), `context.progress` (human result lines, silent under `--json`), `emit_document` (the one JSON document on stdout). A carrier or a report function that calls bare `print` corrupts the document — `tests/contract.bats` fails on that in `carriers/`.
- Adding a carrier: create `libexec/carriers/<name>.py` exporting `CARRIER = Carrier(...)`, then append the module name to `MODULES` in `carriers/__init__.py`. `tests/contract.bats` checks the registry and the directory agree in both directions.
- Config: `$XDG_CONFIG_HOME/proxy-switcher/config.toml` with `endpoint`, `no_proxy`, `exclude`. State: `$XDG_STATE_HOME/proxy-switcher/manifest.json`.
- Every `--json` document carries `schema` (`proxy_common.JSON_SCHEMA`); bump it when a field is added, removed or renamed. Status-bar widgets and TUI wrappers depend on it. `tests/schema.bats` pins the field set of each document and fails unless the code, the snapshot and the number agree — so a forgotten bump cannot pass.
- A switch is one locked transaction: `proxy_engine.state_lock` takes a global `flock` *before* `load_manifest` and holds it through `save_manifest`. The lock file lives in `$XDG_RUNTIME_DIR` (temp-dir fallback), never in the state directory — `--dry-run` and a no-op `restore` must leave that directory untouched. See ADR 0007.
- `env` renders three dialects: bash/zsh share POSIX `export`/`unset`, fish needs `set -gx`/`set -e`. An unsupported `$SHELL` is a usage error rather than a silent zsh guess. fish is not a managed carrier. See ADR 0006.
- `proxysw tui` is an optional fzf consumer, not a second writer: `libexec/tui.py` runs `bin/proxysw ... --json` subprocesses, never imports `proxy_engine`/`proxy_helper`/`carriers`, and never writes a carrier file. `tests/contract.bats` guards the import half. `--json` is for non-interactive commands, `tui` rejects it, and schema stays 2. See ADR 0008.

## Before changing how a carrier renders or how a switch commits

`CODING_STANDARDS.md` holds the behaviours that look wrong until you know what
they protect: why `off` renders instead of restoring, why pnpm's YAML is not
parsed and niri's KDL is not regexed, why fish is refused as a carrier, and which
architectural boundaries a diff must not cross. It also lists what the suite
already enforces, so a reviewer can skip re-checking those by eye.

## Testing

- Every bats test must call `fixture_init`. It points `HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_RUNTIME_DIR` at `$BATS_TEST_TMPDIR`, pins `SHELL=/bin/zsh`, puts stub `niri` and `fzf` first on `PATH`, and exports `PROXYSW_BIN`.
- Tests stay offline, avoid sudo, and touch only the fixture tree.
- Add per-carrier tests in `tests/<carrier>.bats` and cross-carrier behaviour in `tests/aggregate.bats`. Launch/install behaviour goes in `tests/launcher.bats`; architecture rules go in `tests/contract.bats`; the `--json` field snapshots go in `tests/schema.bats`; the switch lock goes in `tests/lock.bats`; the endpoint probe goes in `tests/check.bats`.
- TUI black-box tests live in `tests/tui.bats`. The real fzf is replaced by the fixture stub (it records argv/stdin, can emulate the preview, and returns a configured exit code or selection); tests assert CLI calls, output, bytes on disk, and the stub fzf's argv and emulated preview — with the fixture's stub fzf as the other collaborator. Real fzf rendering, keys and narrow terminals are a manual checklist in `docs/tui-manual-smoke.md`, not a gate.
- `run_proxysw` is `run`, which merges stderr into `$output`. When a test asserts on a `--json` document, capture stdout alone (`run bash -c '"$PROXYSW_BIN" ... 2>/dev/null'`) — otherwise a stray note makes `jq` fail and the assertion stops meaning what it says.

## Conventions

- Exit codes: `0` success, `1` conflict or execution failure, `2` usage error.
- Code and code comments are English; docs, commit messages and issue text are Chinese.
- Commit subjects carry a type prefix — `feat:`, `fix:`, `style:`, `chore:`, and `feat!:` for a breaking change (the `proxy` → `proxysw` rename), with the subject in Chinese and the body explaining why. Merge commits are the exception: they use `merge:` plus the merged topic in Chinese, and need no body because the merged commits carry the reasoning. Existing merge commits keep their subjects; do not rewrite history to fit this line.
- Work is tracked as GitHub issues and closed with a comment plus `gh issue close`.
