#!/usr/bin/env bats
#
# Black-box tests for the aggregate commands: no-argument on/off/toggle,
# configuration exclusions, dry-run and exit codes. The only seam is the CLI:
# a throwaway HOME, real files, a stub niri and assertions on exit code,
# output and the bytes left on disk.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

carrier_path() {
  case "$1" in
    niri) niri_config_path ;;
    shell) shell_rc_path ;;
    npm) npmrc_path ;;
    pnpm) pnpm_config_path ;;
    ssh) ssh_config_path ;;
    *) return 1 ;;
  esac
}

managed_carriers() {
  printf '%s\n' niri shell npm pnpm ssh
}

copy_all_carrier_files() {
  local destination="$1" carrier
  mkdir -p "$destination"
  for carrier in $(managed_carriers); do
    cp -p "$(carrier_path "$carrier")" "$destination/$carrier"
  done
}

assert_all_carrier_files_match() {
  local directory="$1" carrier
  for carrier in $(managed_carriers); do
    if ! cmp -s "$(carrier_path "$carrier")" "$directory/$carrier"; then
      printf 'file bytes differ for %s (%s)\n' "$carrier" "$(carrier_path "$carrier")" >&2
      diff -u "$directory/$carrier" "$(carrier_path "$carrier")" >&2 || true
      return 1
    fi
    [ "$(stat -c '%a' "$(carrier_path "$carrier")")" = "$(stat -c '%a' "$directory/$carrier")" ]
  done
}

@test "on without a carrier name switches all five managed carriers in order" {
  write_all_carriers_off

  run_proxy on

  [ "$status" -eq 0 ]
  local expected actual
  expected="$(managed_carriers)"
  actual="$(printf '%s\n' "$output" \
    | grep -E '^(niri|shell|npm|pnpm|ssh): ' \
    | sed 's/:.*//')"
  [ "$actual" = "$expected" ]

  run_proxy status
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    assert_carrier_state "$carrier" on
  done
}

@test "a full on then off cycle restores all five files byte for byte" {
  write_all_carriers_off
  copy_all_carrier_files "$FIXTURE_ROOT/original"

  run_proxy on
  [ "$status" -eq 0 ]

  run_proxy off
  [ "$status" -eq 0 ]

  assert_all_carrier_files_match "$FIXTURE_ROOT/original"

  run_proxy status
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    assert_carrier_state "$carrier" off
  done
}

@test "toggle turns every carrier on from all off and back off again" {
  write_all_carriers_off
  copy_all_carrier_files "$FIXTURE_ROOT/original"

  run_proxy toggle
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    [[ "$output" == *"$carrier: on"* ]]
  done

  run_proxy status
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    assert_carrier_state "$carrier" on
  done

  run_proxy toggle
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    [[ "$output" == *"$carrier: off"* ]]
  done

  run_proxy status
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    assert_carrier_state "$carrier" off
  done
  assert_all_carrier_files_match "$FIXTURE_ROOT/original"
}

@test "toggle turns all off only when every carrier is on" {
  write_all_carriers_off

  run_proxy on
  [ "$status" -eq 0 ]

  run_proxy toggle

  [ "$status" -eq 0 ]
  run_proxy status
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    assert_carrier_state "$carrier" off
  done
}

@test "toggle turns everything on when any carrier is not on" {
  write_all_carriers_off
  write_niri_on

  run_proxy toggle

  [ "$status" -eq 0 ]
  run_proxy status
  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    assert_carrier_state "$carrier" on
  done
}

@test "the exclude list marks skipped carriers in human status" {
  write_all_carriers_off
  write_proxy_config <<'TOML'
exclude = ["ssh", "pnpm"]
TOML

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state ssh off
  assert_carrier_state pnpm off
  local ssh_line pnpm_line niri_line
  ssh_line="$(printf '%s\n' "$output" | grep -E '^ssh[[:space:]]' | head -n1)"
  pnpm_line="$(printf '%s\n' "$output" | grep -E '^pnpm[[:space:]]' | head -n1)"
  niri_line="$(printf '%s\n' "$output" | grep -E '^niri[[:space:]]' | head -n1)"
  [[ "$ssh_line" == *"excluded"* ]]
  [[ "$ssh_line" == *"skipped"* ]]
  [[ "$pnpm_line" == *"excluded"* ]]
  [[ "$pnpm_line" == *"skipped"* ]]
  [[ "$niri_line" != *"excluded"* ]]
}

@test "status --json marks excluded carriers as skipped" {
  write_all_carriers_off
  write_proxy_config <<'TOML'
exclude = ["ssh"]
TOML

  run_proxy status --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "ssh") | .skipped')" = "true" ]
  local ssh_note
  ssh_note="$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "ssh") | .note')"
  [[ "$ssh_note" == *"excluded"* ]]
  [ "$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "niri") | .skipped')" = "false" ]
}

@test "excluded carriers are skipped by dry-run and by a real aggregate switch" {
  write_all_carriers_off
  write_proxy_config <<'TOML'
exclude = ["ssh", "pnpm"]
TOML
  cp -p "$(ssh_config_path)" "$FIXTURE_ROOT/ssh.original"
  cp -p "$(pnpm_config_path)" "$FIXTURE_ROOT/pnpm.original"

  run_proxy on --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh: skipped"* ]]
  [[ "$output" == *"pnpm: skipped"* ]]
  [[ "$output" != *"ssh: would"* ]]
  [[ "$output" != *"pnpm: would"* ]]
  cmp -s "$(ssh_config_path)" "$FIXTURE_ROOT/ssh.original"
  cmp -s "$(pnpm_config_path)" "$FIXTURE_ROOT/pnpm.original"

  run_proxy on

  [ "$status" -eq 0 ]
  cmp -s "$(ssh_config_path)" "$FIXTURE_ROOT/ssh.original"
  cmp -s "$(pnpm_config_path)" "$FIXTURE_ROOT/pnpm.original"

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state niri on
  assert_carrier_state shell on
  assert_carrier_state npm on
  assert_carrier_state ssh off
  assert_carrier_state pnpm off
}

@test "an explicitly named excluded carrier is skipped, not switched" {
  write_all_carriers_off
  write_proxy_config <<'TOML'
exclude = ["ssh"]
TOML
  cp -p "$(ssh_config_path)" "$FIXTURE_ROOT/ssh.original"

  run_proxy on ssh

  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh: skipped"* ]]
  cmp -s "$(ssh_config_path)" "$FIXTURE_ROOT/ssh.original"
}

@test "--dry-run writes nothing and never calls niri" {
  write_all_carriers_off
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"

  run_proxy on --dry-run

  [ "$status" -eq 0 ]
  for carrier in $(managed_carriers); do
    [[ "$output" == *"$carrier: would turn on"* ]]
  done
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"
  [ "$before" = "$after" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "a conflict returns 1, changes nothing and says so" {
  write_all_carriers_off
  run_proxy on niri
  [ "$status" -eq 0 ]
  printf '\n// edited by hand\n' >> "$(niri_config_path)"

  run_proxy on

  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
  [[ "$output" == *"no carriers were changed"* ]]

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state niri on
  assert_carrier_state shell off
  assert_carrier_state npm off
  assert_carrier_state pnpm off
  assert_carrier_state ssh off
}

@test "--dry-run uses the same conflict exit code as a real switch" {
  write_all_carriers_off
  run_proxy on niri
  [ "$status" -eq 0 ]
  printf '\n// edited by hand\n' >> "$(niri_config_path)"
  local before
  before="$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)"

  run_proxy off --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
  [ "$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)" = "$before" ]

  run_proxy off
  [ "$status" -eq 1 ]
}

@test "--dry-run predicts a planning failure with exit code 1 and writes nothing" {
  write_all_carriers_off
  rm -f "$(pnpm_config_path)"
  mkdir "$(pnpm_config_path)"
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"

  run_proxy on --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"pnpm"* ]]
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME")"
  [ "$before" = "$after" ]
}

@test "a failing carrier is reported while the others are changed" {
  write_all_carriers_off
  rm -f "$(pnpm_config_path)"
  mkdir "$(pnpm_config_path)"

  run_proxy on

  [ "$status" -eq 1 ]
  [[ "$output" == *"pnpm"* ]]
  [[ "$output" == *"proxy: partial completion: changed niri, shell, npm, ssh; not changed pnpm"* ]]

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state niri on
  assert_carrier_state shell on
  assert_carrier_state npm on
  assert_carrier_state pnpm off
  assert_carrier_state ssh on
}

@test "off reports a restore carrier without a snapshot instead of pretending" {
  write_npm_on

  run_proxy off npm

  [ "$status" -eq 1 ]
  [[ "$output" == *"npm"* ]]
  [[ "$output" == *"no snapshot"* ]]
  grep -qF 'proxy=http://127.0.0.1:7890' "$(npmrc_path)"

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state npm on
}

@test "toggle usage errors exit with code 2" {
  run_proxy toggle docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"read-only"* ]]

  run_proxy toggle nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown carrier"* ]]

  run_proxy toggle --nope
  [ "$status" -eq 2 ]

  run_proxy toggle --proxy
  [ "$status" -eq 2 ]
}

@test "an invalid exclude list is a configuration error with exit code 1" {
  write_proxy_config <<'TOML'
exclude = ["nope"]
TOML

  run_proxy on

  [ "$status" -eq 1 ]
  [[ "$output" == *"exclude"* ]]

  write_proxy_config <<'TOML'
exclude = "ssh"
TOML

  run_proxy status
  [ "$status" -eq 1 ]
  [[ "$output" == *"exclude"* ]]
}
