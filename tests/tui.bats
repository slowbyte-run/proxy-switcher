#!/usr/bin/env bats
#
# Black-box tests for `proxysw tui`. fzf is replaced by the stub in the shared
# fixture: it records its argv and the list it was fed, then prints whatever
# selection the test configured. The picker is observed only through the CLI's
# exit code, its output, and the bytes left on disk.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

@test "tui lists the switchable carriers and passes the action to fzf" {
  write_all_carriers_off
  export STUB_FZF_EXIT=130
  export STUB_FZF_STDIN_LOG="$FIXTURE_ROOT/fzf-stdin.log"
  export STUB_FZF_ARGV_LOG="$FIXTURE_ROOT/fzf-argv.log"

  run_proxysw tui off

  [ "$status" -eq 0 ]
  [[ "$output" == *"cancelled"* ]]
  grep -q '^niri' "$STUB_FZF_STDIN_LOG"
  grep -q '^shell' "$STUB_FZF_STDIN_LOG"
  grep -q '^npm' "$STUB_FZF_STDIN_LOG"
  grep -q '^pnpm' "$STUB_FZF_STDIN_LOG"
  grep -q '^ssh' "$STUB_FZF_STDIN_LOG"
  ! grep -q '^docker' "$STUB_FZF_STDIN_LOG"
  grep -q 'proxysw off>' "$STUB_FZF_ARGV_LOG"
}

@test "tui toggles the selected carrier after confirmation" {
  write_all_carriers_off
  export STUB_FZF_OUTPUT="npm"

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui'

  [ "$status" -eq 0 ]
  [[ "$output" == *"npm: on"* ]]
  grep -q '^proxy=http://127.0.0.1:7890$' "$(npmrc_path)"
}

@test "tui off turns the selected carrier off" {
  write_all_carriers_on
  export STUB_FZF_OUTPUT="npm"

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui off'

  [ "$status" -eq 0 ]
  [[ "$output" == *"npm: off"* ]]
  grep -q '^registry=' "$(npmrc_path)"
  ! grep -q '^proxy=' "$(npmrc_path)"
}

@test "declining the confirmation leaves the carrier untouched" {
  write_all_carriers_off
  export STUB_FZF_OUTPUT="npm"
  local before
  before="$(cat "$(npmrc_path)")"

  run bash -c 'printf "n\n" | "$PROXYSW_BIN" tui'

  [ "$status" -eq 0 ]
  [[ "$output" == *"cancelled"* ]]
  [ "$(cat "$(npmrc_path)")" = "$before" ]
  ! grep -q '^proxy=http' "$(npmrc_path)"
}

@test "an empty selection writes nothing" {
  write_all_carriers_off
  export STUB_FZF_EXIT=1
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw tui

  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing selected"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "missing fzf exits 2 without writing" {
  write_all_carriers_off
  export PROXYSW_FZF="$FIXTURE_ROOT/no-such-fzf"
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw tui

  [ "$status" -eq 2 ]
  [[ "$output" == *"needs fzf"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "a conflict exits 1 and leaves the edited file alone" {
  write_all_carriers_off
  run_proxysw on npm
  [ "$status" -eq 0 ]
  printf '\n# edited by hand\n' >> "$(npmrc_path)"
  local before
  before="$(cat "$(npmrc_path)")"
  export STUB_FZF_OUTPUT="npm"

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui'

  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
  [ "$(cat "$(npmrc_path)")" = "$before" ]
  grep -q '^# edited by hand$' "$(npmrc_path)"
}

@test "a partial failure names the failed carrier and exits 1" {
  write_all_carriers_off
  chmod 500 "$HOME"
  trap 'chmod 700 "$HOME"' EXIT
  export STUB_FZF_OUTPUT="npm"

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui'

  [ "$status" -eq 1 ]
  [[ "$output" == *"npm: failed"* ]]
  chmod 700 "$HOME"
  trap - EXIT
}

@test "tui rejects non-interactive options and invalid actions" {
  run_proxysw tui --json
  [ "$status" -eq 2 ]

  run_proxysw tui --force
  [ "$status" -eq 2 ]

  run_proxysw tui --dry-run
  [ "$status" -eq 2 ]

  run_proxysw tui status
  [ "$status" -eq 2 ]

  run_proxysw tui on off
  [ "$status" -eq 2 ]
}

@test "tui passes --proxy through to the switch" {
  write_all_carriers_off
  export STUB_FZF_OUTPUT="npm"

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui --proxy http://127.0.0.1:9999'

  [ "$status" -eq 0 ]
  grep -q '^proxy=http://127.0.0.1:9999$' "$(npmrc_path)"
}

@test "tui exits 0 without opening fzf when every carrier is excluded" {
  write_all_carriers_off
  write_proxy_config <<'TOML'
exclude = ["niri", "shell", "npm", "pnpm", "ssh"]
TOML
  export STUB_FZF_ARGV_LOG="$FIXTURE_ROOT/fzf-argv.log"

  run_proxysw tui

  [ "$status" -eq 0 ]
  [[ "$output" == *"no switchable carriers"* ]]
  [ ! -e "$STUB_FZF_ARGV_LOG" ]
}

@test "the header shows the endpoint, probe, docker and excluded carriers" {
  write_all_carriers_off
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:9"
exclude = ["ssh"]
TOML
  export STUB_FZF_EXIT=130
  export STUB_FZF_ARGV_LOG="$FIXTURE_ROOT/fzf-argv.log"
  export STUB_FZF_STDIN_LOG="$FIXTURE_ROOT/fzf-stdin.log"

  run_proxysw tui

  [ "$status" -eq 0 ]
  grep -qF 'http://127.0.0.1:9' "$STUB_FZF_ARGV_LOG"
  grep -qF 'down' "$STUB_FZF_ARGV_LOG"
  grep -qF 'docker: unmanaged' "$STUB_FZF_ARGV_LOG"
  grep -qF 'excluded: ssh' "$STUB_FZF_ARGV_LOG"
  grep -qF 'Tab' "$STUB_FZF_ARGV_LOG"
  grep -qF 'Ctrl-A' "$STUB_FZF_ARGV_LOG"
  grep -qF 'Enter' "$STUB_FZF_ARGV_LOG"
  grep -qF 'Esc' "$STUB_FZF_ARGV_LOG"
  grep -qF 'proxysw toggle>' "$STUB_FZF_ARGV_LOG"
  # Only managed, non-excluded carriers are selectable; docker stays in the
  # header, ssh is named as excluded and does not become a row.
  [ "$(cut -f1 "$STUB_FZF_STDIN_LOG")" = "$(printf 'niri\nshell\nnpm\npnpm')" ]
}

@test "rows keep a stable order and color on green and off yellow" {
  write_all_carriers_off
  write_niri_on
  export STUB_FZF_EXIT=130
  export STUB_FZF_ARGV_LOG="$FIXTURE_ROOT/fzf-argv.log"
  export STUB_FZF_STDIN_LOG="$FIXTURE_ROOT/fzf-stdin.log"

  run_proxysw tui

  [ "$status" -eq 0 ]
  [ "$(cut -f1 "$STUB_FZF_STDIN_LOG")" \
    = "$(printf 'niri\nshell\nnpm\npnpm\nssh')" ]
  grep -qF -- $'\t\x1b[32mon\x1b[0m\t' "$STUB_FZF_STDIN_LOG"
  grep -qF -- $'\t\x1b[33moff\x1b[0m\t' "$STUB_FZF_STDIN_LOG"
  grep -qxF -- '--ansi' "$STUB_FZF_ARGV_LOG"
  grep -qxF -- '--multi' "$STUB_FZF_ARGV_LOG"
  grep -qxF -- '--layout=reverse' "$STUB_FZF_ARGV_LOG"
  grep -qxF -- '--with-nth=1,2,3' "$STUB_FZF_ARGV_LOG"
  grep -qxF -- '--delimiter=\t' "$STUB_FZF_ARGV_LOG"
  grep -qxF -- 'ctrl-a:select-all' "$STUB_FZF_ARGV_LOG"
  # Only options fzf has carried for years; no footer, border or other
  # recent additions, so no version floor is promised.
  ! grep -q -- '--footer' "$STUB_FZF_ARGV_LOG"
  ! grep -q -- '--border' "$STUB_FZF_ARGV_LOG"
}

@test "the preview shows path, tools, note and flags without file contents" {
  write_all_carriers_off
  # A credential that must never reach the screen: the preview reads only the
  # metadata in status --json, never the carrier file.
  printf '//registry.npmjs.org/:_authToken=super-secret-token\n' >> "$(npmrc_path)"
  cat > "$FIXTURE_ROOT/bin/niri" <<'STUB'
#!/usr/bin/env bash
echo "no compositor" >&2
exit 1
STUB
  chmod +x "$FIXTURE_ROOT/bin/niri"
  run_proxysw on niri
  [ "$status" -eq 0 ]

  export STUB_FZF_EXIT=130
  export STUB_FZF_PREVIEW_LOG="$FIXTURE_ROOT/fzf-preview.log"

  run_proxysw tui

  [ "$status" -eq 0 ]
  grep -qE '^path +/' "$STUB_FZF_PREVIEW_LOG"
  grep -qE '^tools +' "$STUB_FZF_PREVIEW_LOG"
  grep -qE '^note +' "$STUB_FZF_PREVIEW_LOG"
  grep -qE '^flags +' "$STUB_FZF_PREVIEW_LOG"
  grep -qF "$(niri_config_path)" "$STUB_FZF_PREVIEW_LOG"
  grep -qF "$(npmrc_path)" "$STUB_FZF_PREVIEW_LOG"
  grep -qF 'niri-spawned processes' "$STUB_FZF_PREVIEW_LOG"
  grep -qF 'npm, yarn v1' "$STUB_FZF_PREVIEW_LOG"
  grep -qF 'npm and yarn v1 share this file' "$STUB_FZF_PREVIEW_LOG"
  grep -qF 'reload pending' "$STUB_FZF_PREVIEW_LOG"
  grep -qxE 'state +on' "$STUB_FZF_PREVIEW_LOG"
  grep -qxE 'state +off' "$STUB_FZF_PREVIEW_LOG"
  ! grep -qF 'super-secret-token' "$STUB_FZF_PREVIEW_LOG"
  ! grep -qF 'registry=' "$STUB_FZF_PREVIEW_LOG"
  # The coloured field stays in the list; the preview shows plain metadata.
  ! grep -q $'\x1b' "$STUB_FZF_PREVIEW_LOG"
}

@test "a mixed toggle confirms the effective action and only the carriers that change" {
  write_all_carriers_off
  write_niri_on
  export STUB_FZF_OUTPUT=$'niri\nshell'

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui'

  [ "$status" -eq 0 ]
  # niri is already on, so the group decision is "on" and only shell moves.
  [[ "$output" == *"Will turn on: shell"* ]]
  [[ "$output" != *"Will turn on: niri"* ]]
  grep -qF 'export http_proxy="http://127.0.0.1:7890"' "$(shell_rc_path)"
  grep -qF 'http_proxy "http://127.0.0.1:7890"' "$(niri_config_path)"
}

@test "--proxy is shown in the header and applies to the switch" {
  write_all_carriers_off
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7890"
TOML
  export STUB_FZF_OUTPUT="npm"
  export STUB_FZF_ARGV_LOG="$FIXTURE_ROOT/fzf-argv.log"

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui --proxy http://127.0.0.1:9999'

  [ "$status" -eq 0 ]
  grep -qF 'endpoint http://127.0.0.1:9999' "$STUB_FZF_ARGV_LOG"
  grep -qF 'down' "$STUB_FZF_ARGV_LOG"
  grep -q '^proxy=http://127.0.0.1:9999$' "$(npmrc_path)"
}
