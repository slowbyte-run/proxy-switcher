#!/usr/bin/env bats
#
# Black-box tests for `proxy env`. The only seam is the CLI: real files in a
# throwaway HOME and assertions on stdout, exit code and the effect of
# evaluating the output in a shell.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

proxy_keys() {
  printf '%s\n' \
    http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
}

@test "env prints six exports when the shell carrier is on" {
  write_shell_on

  run_proxy env

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 6 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qE "^export ${key}="
  done
  [[ "$output" != *$'\033'* ]]
  [[ "$output" != *"CARRIER"* ]]
}

@test "env output evaluates to the configured endpoint and no_proxy" {
  write_shell_on

  run_proxy env
  [ "$status" -eq 0 ]

  eval "$output"
  [ "$http_proxy" = "http://127.0.0.1:7890" ]
  [ "$https_proxy" = "http://127.0.0.1:7890" ]
  [ "$HTTP_PROXY" = "http://127.0.0.1:7890" ]
  [ "$HTTPS_PROXY" = "http://127.0.0.1:7890" ]
  [ "$no_proxy" = "localhost,127.0.0.1,::1" ]
  [ "$NO_PROXY" = "localhost,127.0.0.1,::1" ]
}

@test "env prints six unsets when the shell carrier is off" {
  write_shell_off

  run_proxy env

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 6 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qx "unset ${key}"
  done
  [[ "$output" != *$'\033'* ]]

  export http_proxy="http://stale.invalid:1"
  eval "$output"
  [ -z "${http_proxy+x}" ]
  [ -z "${https_proxy+x}" ]
}

@test "env reports off when the shell rc is missing" {
  rm -f "$(shell_rc_path)"

  run_proxy env

  [ "$status" -eq 0 ]
  for key in $(proxy_keys); do
    printf '%s\n' "$output" | grep -qx "unset ${key}"
  done
}

@test "env follows the shell carrier when niri is on but the shell is off" {
  write_niri_on
  write_shell_off

  run_proxy env

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

  run_proxy env
  [ "$status" -eq 0 ]

  eval "$output"
  [ "$http_proxy" = "http://127.0.0.1:7890/odd path?q='x y'" ]
  [ "$no_proxy" = "localhost,example.test,with space" ]
}

@test "env performs no writes and never invokes niri" {
  write_all_carriers_on
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"

  run_proxy env

  [ "$status" -eq 0 ]
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"
  [ "$before" = "$after" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "env rejects unknown arguments and options with exit code 2" {
  run_proxy env --nope
  [ "$status" -eq 2 ]

  run_proxy env unexpected
  [ "$status" -eq 2 ]
}
