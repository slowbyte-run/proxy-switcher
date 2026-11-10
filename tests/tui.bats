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

@test "duplicate and unknown selection rows are dropped" {
  write_all_carriers_off
  # fzf can emit a row twice (Tab then re-select), and a stale/malformed row is
  # not a carrier name. Only known switchable names reach the CLI, once each.
  export STUB_FZF_OUTPUT=$'npm\nbogus\ndocker\nnpm\n'

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui'

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -o 'npm: on' | wc -l)" -eq 1 ]
  grep -q '^proxy=http://127.0.0.1:7890$' "$(npmrc_path)"
}

@test "a selection of only unknown rows writes nothing" {
  write_all_carriers_off
  export STUB_FZF_OUTPUT=$'docker\nbogus'
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw tui

  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing selected"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "Ctrl-C in the picker cancels without writing" {
  write_all_carriers_off
  # fzf exits 130 when it catches the interrupt; the picker maps that to a
  # cancel rather than a failure.
  export STUB_FZF_EXIT=130
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw tui

  [ "$status" -eq 0 ]
  [[ "$output" == *"cancelled"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "Ctrl-C at the confirmation cancels without writing" {
  write_all_carriers_off
  export STUB_FZF_OUTPUT="npm"
  local before fifo
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"
  fifo="$FIXTURE_ROOT/confirmation.fifo"
  mkfifo "$fifo"
  # Hold the write end open so the picker blocks in the confirmation instead of
  # reading EOF. The command runs in the foreground of `timeout`; a background
  # job would inherit SIGINT ignored and never see the interrupt.
  exec 9<> "$fifo"

  run timeout --preserve-status --signal=INT 2 "$PROXYSW_BIN" tui < "$fifo"

  exec 9>&-
  [ "$status" -eq 0 ]
  [[ "$output" == *"apply?"* ]]
  [[ "$output" == *"cancelled"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "Ctrl-C while fzf is open cancels without writing" {
  write_all_carriers_off
  # Leave fzf running until the interrupt arrives: the terminal sends Ctrl-C
  # to the picker and to fzf together, so the picker itself must also treat
  # the interrupt as a cancel.
  export STUB_FZF_SLEEP=5
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run timeout --preserve-status --signal=INT 2 "$PROXYSW_BIN" tui

  [ "$status" -eq 0 ]
  [[ "$output" == *"cancelled"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "Ctrl-C during the apply exits 1 and asks for a status check" {
  write_all_carriers_off
  export STUB_FZF_OUTPUT="niri"
  # Interrupt from the niri post-write hook: the stub runs after niri's file
  # has been written but while the picker is still blocked on the apply
  # subprocess. The picker is the stub's grandparent (stub -> CLI -> picker),
  # so the SIGINT lands exactly there instead of racing a timer against the
  # transaction. The CLI is the stub's parent and is killed by the picker.
  cat > "$FIXTURE_ROOT/bin/niri" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NIRI_STUB_LOG"
exec >/dev/null 2>&1
kill -INT "$(ps -o ppid= -p "$PPID" | tr -d ' ')"
sleep 1
STUB
  chmod +x "$FIXTURE_ROOT/bin/niri"

  # bats' parallel runner can start tests as asynchronous jobs, which leaves
  # SIGINT ignored in pipeline members; reset it so the signal exercises the
  # picker's handler instead of an inherited SIG_IGN.
  run bash -c 'printf "y\n" | env --default-signal=INT "$PROXYSW_BIN" tui'

  [ "$status" -eq 1 ]
  [[ "$output" == *"interrupted"* ]]
  [[ "$output" == *"proxysw status"* ]]
  [[ "$output" != *"Traceback"* ]]
  # niri was written before the interrupt: the run must not claim a clean
  # cancel, and the later carriers plus the manifest were never committed.
  grep -qF 'http_proxy "http://127.0.0.1:7890"' "$(niri_config_path)"
  ! grep -q '^proxy=' "$(npmrc_path)"
  [ ! -e "$(proxy_manifest_path)" ]
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

@test "an fzf that cannot start exits 2 without writing" {
  write_all_carriers_off
  # A file that exists and is executable, but whose interpreter does not:
  # exec fails before fzf ever sees a row.
  local broken_fzf="$FIXTURE_ROOT/bin/broken-fzf"
  printf '#!/no/such/interpreter\n' > "$broken_fzf"
  chmod +x "$broken_fzf"
  export PROXYSW_FZF="$broken_fzf"
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw tui

  [ "$status" -eq 2 ]
  [[ "$output" == *"could not start fzf"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "fzf failing on a non-interactive terminal exits 2 without writing" {
  write_all_carriers_off
  # This is how fzf itself behaves without a tty. The picker deliberately does
  # not pre-check the terminal: it lets fzf fail and forwards the message.
  export STUB_FZF_EXIT=2
  export STUB_FZF_STDERR="failed to open /dev/tty: No such device or address"
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw tui

  [ "$status" -eq 2 ]
  [[ "$output" == *"failed to open /dev/tty"* ]]
  [[ "$output" == *"fzf failed"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")" = "$before" ]
}

@test "an invalid config exits 1 with the CLI error and never opens fzf" {
  write_all_carriers_off
  # The TUI reads state through `status --json`; a config that CLI rejects must
  # surface the same message and exit code instead of being swallowed or shown
  # as a crash.
  write_proxy_config <<'TOML'
endpoint = "socks5://127.0.0.1:7890"
TOML
  export STUB_FZF_ARGV_LOG="$FIXTURE_ROOT/fzf-argv.log"
  local before
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw tui

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an http URL"* ]]
  [ ! -e "$STUB_FZF_ARGV_LOG" ]
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

@test "a partial failure names the failed carrier, applies the rest and exits 1" {
  write_all_carriers_off
  local npm_before
  npm_before="$(cat "$(npmrc_path)")"
  # Keep the state directory writable: the npm file lives directly in HOME and
  # fails to write there, while niri's file sits in a writable subdirectory.
  # That is one carrier failing and another succeeding in the same transaction.
  mkdir -p "$XDG_STATE_HOME"
  chmod 500 "$HOME"
  trap 'chmod 700 "$HOME"' EXIT
  export STUB_FZF_OUTPUT=$'npm\nniri'

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui'

  [ "$status" -eq 1 ]
  [[ "$output" == *"npm: failed"* ]]
  [[ "$output" == *"niri: on"* ]]
  [ "$(cat "$(npmrc_path)")" = "$npm_before" ]
  grep -qF 'http_proxy "http://127.0.0.1:7890"' "$(niri_config_path)"
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

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui --proxy http://127.0.0.1:9'

  [ "$status" -eq 0 ]
  grep -q '^proxy=http://127.0.0.1:9$' "$(npmrc_path)"
}

@test "--proxy reaches the dry-run plan, not only the apply" {
  write_all_carriers_off
  write_npm_on
  export STUB_FZF_OUTPUT="npm"

  # npm already holds the configured 7890 endpoint. A dry run that forgot
  # --proxy would plan no change, print "nothing to change" and never call
  # apply; the replacement bytes at :9 prove the dry-run call carried it.
  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui on --proxy http://127.0.0.1:9'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Will turn on: npm"* ]]
  grep -q '^proxy=http://127.0.0.1:9$' "$(npmrc_path)"
  grep -q '^https-proxy=http://127.0.0.1:9$' "$(npmrc_path)"
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
  # Port 9 stays closed unless something unusual is running locally, and the
  # whole endpoint field is asserted so a bare "down" elsewhere cannot pass.
  grep -qF 'endpoint http://127.0.0.1:9  down' "$STUB_FZF_ARGV_LOG"
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

  run bash -c 'printf "y\n" | "$PROXYSW_BIN" tui --proxy http://127.0.0.1:9'

  [ "$status" -eq 0 ]
  grep -qF 'endpoint http://127.0.0.1:9  down' "$STUB_FZF_ARGV_LOG"
  grep -q '^proxy=http://127.0.0.1:9$' "$(npmrc_path)"
}
