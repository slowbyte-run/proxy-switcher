#!/usr/bin/env bats
#
# Black-box tests for `proxy status`. The only seam is the CLI: real files in
# a throwaway HOME, a stub niri, and assertions on exit code / output / disk.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

@test "status reports niri on when the environment block sets proxy variables" {
  write_niri_on

  run_proxy status

  [ "$status" -eq 0 ]
  [[ "$output" == *"http://127.0.0.1:7890"* ]]
  assert_carrier_state niri on
  assert_carrier_tools niri "niri-spawned processes"
  assert_carrier_state shell off
  assert_carrier_state npm off
  assert_carrier_state pnpm off
  assert_carrier_state ssh off
  assert_carrier_state docker unmanaged
}

@test "status reports niri off when the environment block writes null" {
  write_niri_off

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state niri off
}

@test "status reports niri off when the environment block is missing" {
  write_niri_without_environment_block

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state niri off
}

@test "status ignores proxy entries inside KDL comments and slashdash" {
  write_niri_commented_proxies

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state niri off
}

@test "status reports shell on when the managed snippet exports proxies" {
  write_shell_on

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state shell on
  assert_carrier_tools shell "interactive shells"
}

@test "status reports shell off for explicit unsets and ignores NODE_USE_ENV_PROXY" {
  write_shell_off

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state shell off
}

@test "status reports shell on for proxy exports outside the managed snippet" {
  write_shell_raw_exports

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state shell on
}

@test "status reports shell off when the rc file is missing" {
  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state shell off
}

@test "status reports npm on and marks npm with yarn v1" {
  write_npm_on

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state npm on
  assert_carrier_tools npm "npm, yarn v1"
}

@test "status reports npm off when proxy keys are absent or missing" {
  write_npm_off
  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state npm off

  rm -f "$(npmrc_path)"
  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state npm off
}

@test "status uses the last value of duplicated npmrc keys" {
  write_npm_duplicate_keys_off

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state npm off
}

@test "status reports pnpm on for quoted camelCase keys with inline comments" {
  write_pnpm_quoted

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state pnpm on
  assert_carrier_tools pnpm "pnpm"
}

@test "status reports pnpm off when proxy keys are absent or the file is missing" {
  write_pnpm_off
  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state pnpm off

  rm -f "$(pnpm_config_path)"
  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state pnpm off
}

@test "status reports ssh on only from the github.com block" {
  write_ssh_on

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state ssh on
  assert_carrier_tools ssh "GitHub SSH"
}

@test "status reports ssh off for ProxyCommand none and warns that direct access fails" {
  write_ssh_off

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state ssh off
  [[ "$output" == *"direct"* ]]
}

@test "status ignores proxy commands in other ssh host blocks" {
  write_ssh_other_host_proxy_only

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state ssh off
}

@test "status reports ssh off when the config file is missing" {
  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state ssh off
}

@test "status always shows docker as unmanaged with the reason" {
  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state docker unmanaged
  [[ "$output" == *"root"* ]]
  [[ "$output" == *"daemon"* ]]
}

@test "status reports all five carriers on for a fully enabled fixture" {
  write_all_carriers_on

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state niri on
  assert_carrier_state shell on
  assert_carrier_state npm on
  assert_carrier_state pnpm on
  assert_carrier_state ssh on
}

@test "status reads endpoint and no_proxy from XDG config" {
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7891"
no_proxy = "localhost,10.0.0.0/8"
TOML

  run_proxy status

  [ "$status" -eq 0 ]
  [[ "$output" == *"http://127.0.0.1:7891"* ]]
  [[ "$output" == *"localhost,10.0.0.0/8"* ]]
  [[ "$output" != *"127.0.0.1:7890"* ]]
}

@test "status falls back to HOME/.config when XDG_CONFIG_HOME is unset" {
  unset XDG_CONFIG_HOME
  mkdir -p "$HOME/.config/proxy-switcher"
  cat > "$HOME/.config/proxy-switcher/config.toml" <<'TOML'
endpoint = "http://127.0.0.1:9999"
TOML

  run_proxy status

  [ "$status" -eq 0 ]
  [[ "$output" == *"http://127.0.0.1:9999"* ]]
}

@test "status ignores a relative XDG_CONFIG_HOME" {
  XDG_CONFIG_HOME="relative/config"
  export XDG_CONFIG_HOME

  run_proxy status

  [ "$status" -eq 0 ]
  [[ "$output" == *"http://127.0.0.1:7890"* ]]
}

@test "status rejects a non-http endpoint with exit code 1" {
  write_proxy_config <<'TOML'
endpoint = "https://127.0.0.1:7890"
TOML

  run_proxy status

  [ "$status" -eq 1 ]
  [[ "$output" == *"endpoint"* ]]
}

@test "status --json emits a machine-readable view matching the human output" {
  write_all_carriers_on

  run_proxy status --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e . >/dev/null
  [ "$(printf '%s\n' "$output" | jq -r .endpoint)" = "http://127.0.0.1:7890" ]
  [ "$(printf '%s\n' "$output" | jq -r .no_proxy)" = "localhost,127.0.0.1,::1" ]
  [ "$(printf '%s\n' "$output" | jq -r '.carriers | length')" -eq 6 ]
  for carrier in niri shell npm pnpm ssh; do
    [ "$(printf '%s\n' "$output" | jq -r --arg name "$carrier" \
      '.carriers[] | select(.name == $name) | .state')" = "on" ]
  done
  [ "$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "docker") | .state')" = "unmanaged" ]
  [ "$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "npm") | .tools | join(", ")')" = "npm, yarn v1" ]
  [ "$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "niri") | .path')" = "$(niri_config_path)" ]
}

@test "status --json is valid when every carrier file is missing" {
  run_proxy status --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e . >/dev/null
  [ "$(printf '%s\n' "$output" | jq -r '[.carriers[] | select(.state == "off")] | length')" -eq 5 ]
}

@test "status performs no writes and never invokes niri" {
  write_all_carriers_on
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"

  run_proxy status

  [ "$status" -eq 0 ]
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"
  [ "$before" = "$after" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "status --json performs no writes either" {
  write_all_carriers_on
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxy status --json

  [ "$status" -eq 0 ]
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"
  [ "$before" = "$after" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "unknown commands and options exit with code 2" {
  run_proxy status --nope
  [ "$status" -eq 2 ]

  run_proxy status unexpected
  [ "$status" -eq 2 ]

  run_proxy frobnicate
  [ "$status" -eq 2 ]
}

@test "running proxy without a command prints usage and exits 2" {
  run_proxy
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
}

@test "proxy --help exits 0" {
  run_proxy --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"status"* ]]
}
