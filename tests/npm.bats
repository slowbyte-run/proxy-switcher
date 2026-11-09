#!/usr/bin/env bats
#
# Black-box tests for the npm carrier: ~/.npmrc holds the proxy settings for
# both npm and yarn v1. The seam is the CLI only: a throwaway HOME, real files,
# and assertions on exit code, output and the bytes left on disk.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

write_npmrc_plain() {
  cat > "$(npmrc_path)" <<'NPM'
; npm configuration kept by hand
registry=https://registry.npmmirror.com
prefix=~/.npm-global
@internal:registry=https://npm.internal.example/

# credentials live here (do not lose this comment)
NPM
  chmod 600 "$(npmrc_path)"
}

write_npmrc_with_proxy() {
  cat > "$(npmrc_path)" <<'NPM'
registry=https://registry.npmmirror.com
proxy=http://old.example:3128
https-proxy=http://old.example:3128
prefix=~/.npm-global
NPM
  chmod 600 "$(npmrc_path)"
}

assert_file_bytes() {
  local path="$1" expected="$2"
  if ! cmp -s "$path" "$expected"; then
    printf 'file bytes differ: %s\n' "$path" >&2
    diff -u "$expected" "$path" >&2 || true
    return 1
  fi
}

assert_npm_keys_once() {
  local path="$1"
  for key in proxy https-proxy noproxy; do
    [ "$(grep -cE "^${key}=" "$path")" -eq 1 ]
  done
}

@test "on writes the three keys and leaves every other byte untouched" {
  write_npmrc_plain
  cat > "$FIXTURE_ROOT/expected" <<'NPM'
; npm configuration kept by hand
registry=https://registry.npmmirror.com
prefix=~/.npm-global
@internal:registry=https://npm.internal.example/

# credentials live here (do not lose this comment)
proxy=http://127.0.0.1:7890
https-proxy=http://127.0.0.1:7890
noproxy=localhost,127.0.0.1,::1
NPM

  run_proxysw on npm

  [ "$status" -eq 0 ]
  assert_file_bytes "$(npmrc_path)" "$FIXTURE_ROOT/expected"
  assert_npm_keys_once "$(npmrc_path)"
  [ "$(stat -c '%a' "$(npmrc_path)")" = "600" ]
}

@test "on replaces existing proxy and https-proxy values instead of appending" {
  write_npmrc_with_proxy
  cat > "$FIXTURE_ROOT/expected" <<'NPM'
registry=https://registry.npmmirror.com
proxy=http://127.0.0.1:7890
https-proxy=http://127.0.0.1:7890
prefix=~/.npm-global
noproxy=localhost,127.0.0.1,::1
NPM

  run_proxysw on npm

  [ "$status" -eq 0 ]
  assert_file_bytes "$(npmrc_path)" "$FIXTURE_ROOT/expected"
  assert_npm_keys_once "$(npmrc_path)"
}

@test "on collapses duplicate proxy keys to one line each" {
  cat > "$(npmrc_path)" <<'NPM'
registry=https://registry.npmmirror.com
proxy=
https-proxy=
proxy=http://old.example:3128
https-proxy=http://old.example:3128
NPM
  chmod 600 "$(npmrc_path)"
  cat > "$FIXTURE_ROOT/expected" <<'NPM'
registry=https://registry.npmmirror.com
proxy=http://127.0.0.1:7890
https-proxy=http://127.0.0.1:7890
noproxy=localhost,127.0.0.1,::1
NPM

  run_proxysw on npm

  [ "$status" -eq 0 ]
  assert_file_bytes "$(npmrc_path)" "$FIXTURE_ROOT/expected"
  assert_npm_keys_once "$(npmrc_path)"
}

@test "off removes the proxy keys and keeps every other byte and the 600 mode" {
  write_npmrc_with_proxy
  cp "$(npmrc_path)" "$FIXTURE_ROOT/original"
  local original_hash
  original_hash="$(sha256sum "$(npmrc_path)" | cut -d' ' -f1)"

  run_proxysw on npm
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(npmrc_path)" | cut -d' ' -f1)" != "$original_hash" ]

  run_proxysw off npm

  [ "$status" -eq 0 ]
  for key in proxy https-proxy noproxy; do
    [ "$(grep -cE "^${key}=" "$(npmrc_path)")" -eq 0 ]
  done
  grep -qF 'registry=https://registry.npmmirror.com' "$(npmrc_path)"
  grep -qF 'prefix=~/.npm-global' "$(npmrc_path)"
  grep -qF 'old.example:3128' "$FIXTURE_ROOT/original"
  ! grep -qF 'old.example:3128' "$(npmrc_path)"
  [ "$(stat -c '%a' "$(npmrc_path)")" = "600" ]
}

@test "restore brings back hand-written proxy values that off removed" {
  write_npmrc_with_proxy
  cp "$(npmrc_path)" "$FIXTURE_ROOT/original"

  run_proxysw on npm
  [ "$status" -eq 0 ]
  run_proxysw off npm
  [ "$status" -eq 0 ]
  ! grep -qF 'old.example:3128' "$(npmrc_path)"

  run_proxysw restore npm

  [ "$status" -eq 0 ]
  assert_file_bytes "$(npmrc_path)" "$FIXTURE_ROOT/original"
  grep -qF 'proxy=http://old.example:3128' "$(npmrc_path)"
  [ "$(stat -c '%a' "$(npmrc_path)")" = "600" ]
}

@test "on creates a missing npmrc with 600 and says so, off removes it again" {
  rm -f "$(npmrc_path)"

  run_proxysw on npm

  [ "$status" -eq 0 ]
  [[ "$output" == *"did not exist"* ]]
  [[ "$output" == *".npmrc"* ]]
  [ -f "$(npmrc_path)" ]
  [ "$(stat -c '%a' "$(npmrc_path)")" = "600" ]
  assert_npm_keys_once "$(npmrc_path)"

  run_proxysw off npm

  [ "$status" -eq 0 ]
  [ ! -e "$(npmrc_path)" ]
}

@test "noproxy matches no_proxy and the proxies use the configured endpoint" {
  write_npmrc_plain
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7895"
no_proxy = "localhost,*.internal,10.0.0.1"
TOML

  run_proxysw on npm

  [ "$status" -eq 0 ]
  grep -qF 'proxy=http://127.0.0.1:7895' "$(npmrc_path)"
  grep -qF 'https-proxy=http://127.0.0.1:7895' "$(npmrc_path)"
  grep -qF 'noproxy=localhost,*.internal,10.0.0.1' "$(npmrc_path)"
}

@test "repeated on is idempotent and adds no duplicate keys or snapshots" {
  write_npmrc_plain
  run_proxysw on npm
  [ "$status" -eq 0 ]
  local first_hash snapshots
  first_hash="$(sha256sum "$(npmrc_path)" | cut -d' ' -f1)"
  snapshots="$(proxy_snapshot_count)"

  run_proxysw on npm

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(npmrc_path)" | cut -d' ' -f1)" = "$first_hash" ]
  [ "$(proxy_snapshot_count)" -eq "$snapshots" ]
  assert_npm_keys_once "$(npmrc_path)"
}

@test "status shows npm on and marks yarn v1 as sharing the file" {
  write_npmrc_plain

  run_proxysw on npm
  [ "$status" -eq 0 ]

  run_proxysw status

  [ "$status" -eq 0 ]
  assert_carrier_state npm on
  assert_carrier_tools npm "npm, yarn v1"
  [[ "$output" == *"share"* ]]
}
