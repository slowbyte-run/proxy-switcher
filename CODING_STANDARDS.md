# Coding standards

Read during review, not during implementation. Every rule here is a **judgement
call** — something no linter can decide. The mechanical rules that used to sit
beside them are now checks; they are listed in the last section so a reviewer
knows what the suite already covers and does not re-litigate it by eye.

`AGENTS.md` carries the navigation pointer to this file. If this file grows past
roughly a thousand lines, split it by area and point at the pieces from here.

## What a reviewer is for

A review checks the things a diff can reveal but a test cannot: whether the
change belongs where it was made, whether it preserved a deliberate trade-off,
and whether the reasoning in the commit body matches the code. A reviewer that
re-derives what `./scripts/check` already proves is spending its budget in the
wrong place.

## Deliberate trade-offs — do not "simplify" these

Each of these looks like an implementation quirk until you know why it is there.
A diff that removes one is a regression even when every test passes, because the
tests encode the current behaviour, not the reasoning.

- **`off` renders the no-proxy state; `restore` rolls back.** `off` never
  restores the snapshot. A machine whose original files held hand-written proxy
  values would otherwise turn "switch the proxy off" into "switch it back on".
  See ADR 0003. The pairing is covered end to end by
  `tests/aggregate.bats` ("on -> off -> restore returns all five files to their
  initial bytes", "restore brings back hand-written proxy values that off
  discarded").
- **pnpm's YAML is edited line by line.** A PyYAML round-trip drops comments and
  reflows the whole file, so a proxy switch would rewrite bytes it has no
  business touching. `tests/pnpm.bats` asserts the comments and quote style
  survive; a parser rewrite can pass those and still reformat unrelated keys, so
  this one needs the reviewer's eye, not just a green suite.
- **niri KDL goes through `libexec/kdl.py`.** It preserves comments and byte
  offsets. Reaching for a regex over the config is the failure mode
  `tests/niri.bats` ("commented and slashdashed proxy entries are left
  untouched") guards against; the comment-preservation assertions would not
  catch a regex that happens to leave comments alone but reflows the block, so
  this one is on the reviewer too.
- **fish is not a managed carrier.** `config.fish` has no "last executed wins"
  guarantee, so a snippet cannot promise it overrides a later hand-written
  `set -gx`. `env --shell fish` renders the dialect; writing `config.fish` is
  refused on purpose. See ADR 0006.
- **The lock is global, and lives outside the state directory.** It is taken
  before `load_manifest` because the conflict window sits between the read and
  the write; it lives in `$XDG_RUNTIME_DIR` so a switch that writes nothing
  leaves the state directory untouched. See ADR 0007.
- **The TUI is a consumer of the CLI, not a second writer.** `libexec/tui.py`
  runs `proxysw ... --json` subprocesses; it does not import `proxy_engine`,
  `proxy_helper` or `carriers`, and it does not write a carrier file. Reaching
  into the engine "to save one subprocess" would bypass the lock, snapshot,
  conflict detection and atomic write, and would make an fzf UI a second
  writer. `tests/contract.bats` guards the import half; `tests/tui.bats`
  observes only CLI calls, output and bytes on disk, with the fixture's stub
  fzf as the other collaborator. See ADR 0008.

## Rules with a known soft edge

These have a check, and the check does not cover the whole rule. Read them
yourself when a diff touches the area.

- **`off` never creates a carrier that was not there.** `delete_created_file`
  defaults to `True` and removes a file `on` created; `shell.py` is the single
  exception (`delete_created_file=False`) because its explicit `unset` lines are
  what override the niri block, so that file must stay. `tests/pnpm.bats` and
  `tests/ssh.bats` each cover the removal half for their carrier. When a new
  carrier arrives this is a decision to make deliberately, not a default to
  inherit.
- **`NODE_USE_ENV_PROXY` is an enabler, not a value.** `on` writes it to both env
  carriers; `off` removes it from the niri block but must not unset it in the
  shell snippet, because that would clobber a line the user wrote by hand.
  `tests/status.bats` asserts it does not affect carrier state; the asymmetry
  itself has no test, so it is on the reviewer. See ADR 0004.

## Reviewing the `--json` surface

The documents are a public contract (`schema`, now at 2). `tests/schema.bats`
pins each document's field set and fails both when a field moves without a bump
and when the number moves without the snapshot. What it cannot judge:

- Whether a new field belongs on the document at all, or is leaking an
  implementation detail into a widget's API.
- Whether a value that used to be prose in `note` should now be a real field.
  It generally should: `pending_reload` was a phrase a consumer had to
  substring-match until it became a boolean.
- Whether a new command should be scriptable. `tui` deliberately is not: it
  rejects `--json`, `--dry-run`, `--force`, `--verbose`, `--check`, `--short`,
  `--require-up` and `--shell`, and only accepts an optional action plus
  `--proxy`. It consumes the same documents as any other wrapper, which is why
  the schema stayed at 2 for #11–#13.

## Architectural boundaries a reviewer should hold

- A carrier resolves a path, renders bytes, and may declare `check_rendered`.
  It knows nothing about snapshots, conflicts, atomic writes or the manifest —
  those live in `proxy_engine.py`. A carrier importing `json`, `hashlib`, or the
  state directory is a boundary break even if it works.
- `proxy_cli.py` owns every argument and every line of usage text. A `--flag`
  understood anywhere else means two parsers have appeared.
- Human output goes through `context.info` (stderr), `context.progress` (silent
  under `--json`) or `emit_document` (the single JSON document). A new channel
  is a design change, not a convenience. `tests/contract.bats` enforces the
  bare-`print` half of this inside `carriers/` only.
- `libexec/tui.py` may spawn the launcher and parse its `--json` documents; it
  may not import the engine, the state helper or the carrier registry, and may
  not write a carrier file. Its only external collaborator besides the CLI is
  fzf, which tests replace with the shared stub.

## Already enforced by the suite — do not re-review by eye

Listed so a reviewer can skip them. If a diff removes one of these protections,
that is the finding.

| Rule | Guard |
| --- | --- |
| Six proxy variable names live in one module | `tests/contract.bats` |
| The launcher stays a thin `exec` with no parser | `tests/contract.bats` |
| Carrier registry and `carriers/` agree both ways | `tests/contract.bats` |
| Every carrier exports a `CARRIER` from the shared model | `tests/contract.bats` |
| No `carriers/` module calls bare `print` | `tests/contract.bats` |
| Exit codes stay `0` / `1` / `2` | `tests/contract.bats` |
| Every test uses the fixture and no real system path | `tests/contract.bats` |
| The TUI never imports the engine, helper or carriers | `tests/contract.bats` |
| `--json` field sets and the schema number agree | `tests/schema.bats` |
| npm keeps mode 0600 and replaces keys in place | `tests/npm.bats` |
| ssh leaves every other Host block byte-identical | `tests/ssh.bats` (`ssh -G`) |
| A newer manifest is refused rather than rewritten | `tests/aggregate.bats` |
| Style, shell style, and the suite itself | `./scripts/check` |
