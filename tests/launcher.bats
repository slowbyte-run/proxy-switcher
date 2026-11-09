#!/usr/bin/env bats
#
# Black-box tests for the `bin/proxy` launcher itself. The launcher must find
# `libexec/proxy_cli.py` from the checkout, not from the directory the binary
# was invoked from -- otherwise the only sane install (a symlink in
# ~/.local/bin) cannot start.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

@test "the launcher runs from the checkout without a link" {
  run_proxy status

  [ "$status" -eq 0 ]
  [[ "$output" == *"CARRIER"* ]]
}

@test "the launcher follows an absolute symlink to the checkout" {
  ln -s "$PROXY_BIN" "$FIXTURE_ROOT/bin/proxy-link"

  run "$FIXTURE_ROOT/bin/proxy-link" status

  [ "$status" -eq 0 ]
  [[ "$output" == *"CARRIER"* ]]
}

@test "the launcher follows a relative symlink to the checkout" {
  local relative
  relative="$(realpath --relative-to="$FIXTURE_ROOT/bin" "$PROXY_BIN")"
  ln -s "$relative" "$FIXTURE_ROOT/bin/proxy-link"

  run "$FIXTURE_ROOT/bin/proxy-link" status

  [ "$status" -eq 0 ]
  [[ "$output" == *"CARRIER"* ]]
}

@test "the launcher follows a chain of symlinks" {
  ln -s "$PROXY_BIN" "$FIXTURE_ROOT/bin/proxy-hop"
  ln -s "proxy-hop" "$FIXTURE_ROOT/bin/proxy-link"

  run "$FIXTURE_ROOT/bin/proxy-link" status

  [ "$status" -eq 0 ]
  [[ "$output" == *"CARRIER"* ]]
}

@test "switching through a symlinked launcher writes to the fixture HOME" {
  ln -s "$PROXY_BIN" "$FIXTURE_ROOT/bin/proxy-link"
  write_npm_off

  run "$FIXTURE_ROOT/bin/proxy-link" on npm

  [ "$status" -eq 0 ]
  grep -q 'proxy=http://127.0.0.1:7890' "$(npmrc_path)"
}
