#!/usr/bin/env bats
#
# Black-box tests for the concurrency lock around a switch.
#
# The lock exists because a switch is a read-modify-write over the manifest:
# two processes planning against the same bytes would let the later writer
# silently discard the earlier one's carrier entry.
#
# The lock file lives in $XDG_RUNTIME_DIR (set to the fixture by fixture_init),
# not in the state directory, so a switch that writes nothing leaves the state
# directory alone.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
  LOCK_HANDLE=""
}

teardown() {
  if [[ -n "$LOCK_HANDLE" ]]; then
    exec 9>&-
    LOCK_HANDLE=""
  fi
}

# The lock path is derived from the state root, so the test globs for it rather
# than re-implementing the digest.
lock_file() {
  local matches
  matches=("$XDG_RUNTIME_DIR"/proxysw-*/state-*.lock)
  [ -e "${matches[0]}" ] || return 1
  printf '%s\n' "${matches[0]}"
}

hold_lock() {
  local path
  path="$(lock_file)" || return 1
  exec 9>"$path"
  flock -n 9
  LOCK_HANDLE="$path"
}

@test "a switch creates the lock outside the state directory" {
  write_npm_off

  run_proxysw on npm

  [ "$status" -eq 0 ]
  lock_file
  [ ! -e "$(proxy_state_root)/lock" ]
  [ ! -e "$(proxy_state_root)/state.lock" ]
}

@test "--dry-run creates no lock file" {
  write_npm_off

  run_proxysw on --dry-run

  [ "$status" -eq 0 ]
  run lock_file
  [ "$status" -ne 0 ]
}

@test "a held lock makes a concurrent switch fail with exit code 1" {
  write_npm_off
  run_proxysw on npm
  [ "$status" -eq 0 ]
  hold_lock

  PROXYSW_LOCK_TIMEOUT=0.2 run_proxysw off npm

  [ "$status" -eq 1 ]
  [[ "$output" == *"another proxysw"* ]]
  grep -qF 'proxy=http://127.0.0.1:7890' "$(npmrc_path)"
}

@test "a switch succeeds once the lock is released" {
  write_npm_off
  run_proxysw on npm
  [ "$status" -eq 0 ]
  hold_lock
  exec 9>&-
  LOCK_HANDLE=""

  run_proxysw off npm

  [ "$status" -eq 0 ]
  ! grep -qF 'proxy=' "$(npmrc_path)"
}

@test "the lock timeout is read from PROXYSW_LOCK_TIMEOUT" {
  write_npm_off
  run_proxysw on npm
  [ "$status" -eq 0 ]
  hold_lock

  local started finished elapsed_ms
  started="$(date +%s%N)"
  PROXYSW_LOCK_TIMEOUT=0.3 run_proxysw off npm
  finished="$(date +%s%N)"

  [ "$status" -eq 1 ]
  elapsed_ms=$(( (finished - started) / 1000000 ))
  # The wait honours the override instead of the 5s default.
  [ "$elapsed_ms" -lt 3000 ]
}

@test "two concurrent switches to different carriers both land in the manifest" {
  write_npm_off
  write_pnpm_off

  "$PROXYSW_BIN" on npm > "$FIXTURE_ROOT/npm.out" 2>&1 &
  local npm_pid=$!
  "$PROXYSW_BIN" on pnpm > "$FIXTURE_ROOT/pnpm.out" 2>&1 &
  local pnpm_pid=$!
  wait "$npm_pid"
  local npm_status=$?
  wait "$pnpm_pid"
  local pnpm_status=$?

  [ "$npm_status" -eq 0 ]
  [ "$pnpm_status" -eq 0 ]
  # Neither entry may be lost to the other's read-modify-write.
  [ "$(jq -r '.carriers | has("npm")' "$(proxy_manifest_path)")" = "true" ]
  [ "$(jq -r '.carriers | has("pnpm")' "$(proxy_manifest_path)")" = "true" ]

  run_proxysw status
  [ "$status" -eq 0 ]
  assert_carrier_state npm on
  assert_carrier_state pnpm on
}

@test "an unusable runtime directory falls back to the temp directory" {
  write_npm_off
  # A read-only runtime dir is a real configuration (containers, remounted
  # /run). The lock must still work rather than failing the switch.
  export XDG_RUNTIME_DIR="$FIXTURE_ROOT/read-only-run"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 500 "$XDG_RUNTIME_DIR"
  if [[ -w "$XDG_RUNTIME_DIR" ]]; then
    skip "running as root: chmod cannot make a directory unwritable"
  fi

  run_proxysw on npm

  [ "$status" -eq 0 ]
  grep -qF 'proxy=http://127.0.0.1:7890' "$(npmrc_path)"
  # Nothing was written into the unusable directory.
  [ -z "$(find "$XDG_RUNTIME_DIR" -mindepth 1)" ]
}
