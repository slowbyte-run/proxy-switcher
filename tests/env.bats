#!/usr/bin/env bats
#
# Black-box tests for `proxysw env`. The only seam is the CLI: real files in a
# throwaway HOME and assertions on stdout, exit code and the effect of
# evaluating the output in a shell.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

@test "env prints six exports plus the node fetch flag when the shell carrier is on" {
  write_shell_on

  run_proxysw env

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 7 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qE "^export ${key}="
  done
  printf '%s\n' "$output" | grep -qx 'export NODE_USE_ENV_PROXY=1'
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *"CARRIER"* ]]
}

@test "env output evaluates to the configured endpoint and no_proxy" {
  write_shell_on

  run_proxysw env
  [ "$status" -eq 0 ]

  eval "$output"
  [ "$http_proxy" = "http://127.0.0.1:7890" ]
  [ "$https_proxy" = "http://127.0.0.1:7890" ]
  [ "$HTTP_PROXY" = "http://127.0.0.1:7890" ]
  [ "$HTTPS_PROXY" = "http://127.0.0.1:7890" ]
  [ "$no_proxy" = "localhost,127.0.0.1,::1" ]
  [ "$NO_PROXY" = "localhost,127.0.0.1,::1" ]
  [ "$NODE_USE_ENV_PROXY" = "1" ]
}

@test "env prints six unsets when the shell carrier is off" {
  write_shell_off

  run_proxysw env

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 6 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qx "unset ${key}"
  done
  ! printf '%s\n' "$output" | grep -q 'NODE_USE_ENV_PROXY'
  [[ "$output" != *$'\033'* ]]

  export http_proxy="http://stale.invalid:1"
  eval "$output"
  [ -z "${http_proxy+x}" ]
  [ -z "${https_proxy+x}" ]
}

@test "env reports off when the shell rc is missing" {
  rm -f "$(shell_rc_path)"

  run_proxysw env

  [ "$status" -eq 0 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qx "unset ${key}"
  done
}

@test "env follows the shell carrier when niri is on but the shell is off" {
  write_niri_on
  write_shell_off

  run_proxysw env

  [ "$status" -eq 0 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qx "unset ${key}"
  done
}

@test "env quotes values so eval keeps them intact" {
  write_shell_on
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7890/odd path?q='x y'"
no_proxy = "localhost,example.test,with space"
TOML

  run_proxysw env
  [ "$status" -eq 0 ]

  eval "$output"
  [ "$http_proxy" = "http://127.0.0.1:7890/odd path?q='x y'" ]
  [ "$no_proxy" = "localhost,example.test,with space" ]
}

@test "--proxy overrides the endpoint printed by env" {
  write_shell_on

  run_proxysw env --proxy http://127.0.0.1:7999

  [ "$status" -eq 0 ]
  eval "$output"
  [ "$http_proxy" = "http://127.0.0.1:7999" ]
  [ "$HTTPS_PROXY" = "http://127.0.0.1:7999" ]
}

@test "env follows the rc file selected by SHELL" {
  SHELL=/bin/bash
  export SHELL
  cat > "$HOME/.bashrc" <<'SH'
export http_proxy="http://127.0.0.1:7899"
export https_proxy="http://127.0.0.1:7899"
SH

  run_proxysw env

  [ "$status" -eq 0 ]
  eval "$output"
  [ "$http_proxy" = "http://127.0.0.1:7890" ]
}

@test "env performs no writes and never invokes niri" {
  write_all_carriers_on
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"

  run_proxysw env

  [ "$status" -eq 0 ]
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"
  [ "$before" = "$after" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "env rejects unknown arguments and options with exit code 2" {
  run_proxysw env --nope
  [ "$status" -eq 2 ]

  run_proxysw env unexpected
  [ "$status" -eq 2 ]
}

@test "env --json lists the exports when the shell carrier is on" {
  write_shell_on

  run_proxysw env --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e . >/dev/null
  [ "$(printf '%s\n' "$output" | jq -r .schema)" = "1" ]
  [ "$(printf '%s\n' "$output" | jq -r .state)" = "on" ]
  [ "$(printf '%s\n' "$output" | jq -r '.exports.http_proxy')" = "http://127.0.0.1:7890" ]
  [ "$(printf '%s\n' "$output" | jq -r '.exports.NODE_USE_ENV_PROXY')" = "1" ]
  [ "$(printf '%s\n' "$output" | jq -r '.unsets | length')" -eq 0 ]
}

@test "env --json lists the unset variables when the shell carrier is off" {
  write_shell_off

  run_proxysw env --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r .state)" = "off" ]
  [ "$(printf '%s\n' "$output" | jq -r '.exports | length')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.unsets | join(",")')" = "http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY,no_proxy,NO_PROXY" ]
}

@test "env --json performs no writes" {
  write_all_carriers_on
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxysw env --json

  [ "$status" -eq 0 ]
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"
  [ "$before" = "$after" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "env --shell fish renders set -gx and set -e instead of export and unset" {
  write_shell_on

  run_proxysw env --shell fish

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 7 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qE "^set -gx ${key} \""
  done
  printf '%s\n' "$output" | grep -qx 'set -gx NODE_USE_ENV_PROXY "1"'
  [[ "$output" != *"export "* ]]
  [[ "$output" != *"unset "* ]]
}

@test "env --shell fish renders set -e when the shell carrier is off" {
  write_shell_off

  run_proxysw env --shell fish

  [ "$status" -eq 0 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qx "set -e ${key}"
  done
  [[ "$output" != *"set -gx"* ]]
  [[ "$output" != *"unset "* ]]
}

@test "env --shell=fish accepts the equals form" {
  write_shell_on

  run_proxysw env --shell=fish

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^set -gx http_proxy "'
}

@test "env --shell rejects an unknown shell with exit code 2" {
  run_proxysw env --shell tcsh

  [ "$status" -eq 2 ]
  [[ "$output" == *"--shell"* ]]
  [[ "$output" == *"bash, zsh, fish"* ]]
}

@test "env --shell without a value is a usage error" {
  run_proxysw env --shell

  [ "$status" -eq 2 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "env without --shell refuses to guess when SHELL is unsupported" {
  SHELL=/usr/bin/fish
  export SHELL

  run_proxysw env

  [ "$status" -eq 2 ]
  [[ "$output" == *"--shell"* ]]
  [[ "$output" != *"unset http_proxy"* ]]
}

@test "env without --shell falls back to bash when SHELL is unset" {
  unset SHELL
  write_shell_on

  run_proxysw env

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'export NODE_USE_ENV_PROXY=1'
}

@test "env follows a POSIX SHELL such as dash" {
  SHELL=/usr/bin/dash
  export SHELL
  write_shell_on

  run_proxysw env

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^export http_proxy='
}

@test "env --shell is rejected for switch commands and status" {
  run_proxysw on --shell fish
  [ "$status" -eq 2 ]

  run_proxysw status --shell fish
  [ "$status" -eq 2 ]
}

@test "env --json ignores --shell because it emits data, not code" {
  write_shell_on

  run_proxysw env --shell fish --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r .state)" = "on" ]
}

@test "env --json works even when SHELL is a shell env cannot render" {
  # JSON is data, not shell code, so the dialect never matters here. Without
  # this, a fish user piping to jq would hit the usage error meant for humans.
  SHELL=/usr/bin/fish
  export SHELL
  write_shell_on

  run_proxysw env --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e . >/dev/null
  [ "$(printf '%s\n' "$output" | jq -r .state)" = "on" ]
}
