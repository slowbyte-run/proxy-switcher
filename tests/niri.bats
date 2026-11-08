#!/usr/bin/env bats
#
# Black-box tests for switching the niri carrier on and off. The only seam is
# the CLI: real files in a throwaway HOME, a stub niri, and assertions on exit
# code, output, the stub's argv and the bytes left on disk.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

proxy_keys() {
  printf '%s\n' \
    http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
}

@test "on writes the six proxy keys and preserves other environment entries" {
  write_niri_plain
  local before_input after_input
  before_input="$(sed -n '/^input {/,$p' "$(niri_config_path)")"

  run_proxy on niri

  [ "$status" -eq 0 ]
  after_input="$(sed -n '/^input {/,$p' "$(niri_config_path)")"
  [ "$before_input" = "$after_input" ]

  for key in $(proxy_keys); do
    grep -qE "^[[:space:]]+${key} \"" "$(niri_config_path)"
  done
  grep -qF 'LANG "zh_CN.UTF-8"' "$(niri_config_path)"
  grep -qF 'QT_QPA_PLATFORM "wayland"' "$(niri_config_path)"
  grep -qF 'GODEBUG "http2client=0"' "$(niri_config_path)"
  grep -qF '// keep this comment' "$(niri_config_path)"
  ! grep -q 'all_proxy' "$(niri_config_path)"

  [ "$(grep -cE "^[[:space:]]+(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY) " "$(niri_config_path)")" -eq 6 ]
}

@test "off writes null for all six keys instead of deleting them" {
  write_niri_plain
  run_proxy on niri
  [ "$status" -eq 0 ]

  run_proxy off niri

  [ "$status" -eq 0 ]
  for key in $(proxy_keys); do
    grep -qE "^[[:space:]]+${key} null$" "$(niri_config_path)"
  done
  grep -qF 'LANG "zh_CN.UTF-8"' "$(niri_config_path)"
  grep -qF '// keep this comment' "$(niri_config_path)"
  ! grep -q 'http://127.0.0.1:7890' "$(niri_config_path)"

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state niri off
}

@test "on creates a valid environment block when the config has none" {
  write_niri_without_environment_block

  run_proxy on niri

  [ "$status" -eq 0 ]
  grep -qE '^environment \{' "$(niri_config_path)"
  for key in $(proxy_keys); do
    grep -qE "^[[:space:]]+${key} \"" "$(niri_config_path)"
  done
  grep -qF '// no environment block here' "$(niri_config_path)"
  grep -qF 'input {' "$(niri_config_path)"

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state niri on
}

@test "on leaves a file that already contains the same values byte-identical" {
  write_niri_on
  local before
  before="$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)"

  run_proxy on niri

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)" = "$before" ]
}

@test "repeated on is idempotent and creates no extra snapshot" {
  write_niri_plain
  run_proxy on niri
  [ "$status" -eq 0 ]
  local first_hash first_snapshots
  first_hash="$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)"
  first_snapshots="$(proxy_snapshot_count)"
  [ "$first_snapshots" -eq 1 ]

  run_proxy on niri

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)" = "$first_hash" ]
  [ "$(proxy_snapshot_count)" -eq "$first_snapshots" ]
}

@test "the manifest records original existence, original hash and written hash" {
  write_niri_plain
  local original_hash written_hash snapshot
  original_hash="sha256:$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)"

  run_proxy on niri
  [ "$status" -eq 0 ]

  written_hash="sha256:$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)"
  jq -e . "$(proxy_manifest_path)" >/dev/null
  [ "$(jq -r '.carriers.niri.state' "$(proxy_manifest_path)")" = "on" ]
  [ "$(jq -r '.carriers.niri.original_existed' "$(proxy_manifest_path)")" = "true" ]
  [ "$(jq -r '.carriers.niri.original_hash' "$(proxy_manifest_path)")" = "$original_hash" ]
  [ "$(jq -r '.carriers.niri.written_hash' "$(proxy_manifest_path)")" = "$written_hash" ]

  snapshot="$(jq -r '.carriers.niri.snapshot' "$(proxy_manifest_path)")"
  [ -f "$snapshot" ]
  [ "$(sha256sum "$snapshot" | cut -d' ' -f1)" = "${original_hash#sha256:}" ]
}

@test "the manifest records a missing original file as absent" {
  rm -f "$(niri_config_path)"

  run_proxy on niri

  [ "$status" -eq 0 ]
  [ -f "$(niri_config_path)" ]
  [ "$(jq -r '.carriers.niri.original_existed' "$(proxy_manifest_path)")" = "false" ]
  [ "$(jq -r '.carriers.niri.original_hash' "$(proxy_manifest_path)")" = "null" ]
  [ "$(jq -r '.carriers.niri.snapshot' "$(proxy_manifest_path)")" = "null" ]
}

@test "off refuses to overwrite an externally modified file with exit code 1" {
  write_niri_plain
  run_proxy on niri
  [ "$status" -eq 0 ]
  printf '\n// edited by hand\n' >> "$(niri_config_path)"
  local before
  before="$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)"

  run_proxy off niri

  [ "$status" -eq 1 ]
  [[ "$output" == *"$(niri_config_path)"* ]]
  [[ "$output" == *"--force"* ]]
  [ "$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)" = "$before" ]
}

@test "--force completes a switch over an externally modified file" {
  write_niri_plain
  run_proxy on niri
  [ "$status" -eq 0 ]
  printf '\n// edited by hand\n' >> "$(niri_config_path)"

  run_proxy off niri --force

  [ "$status" -eq 0 ]
  for key in $(proxy_keys); do
    grep -qE "^[[:space:]]+${key} null$" "$(niri_config_path)"
  done
  grep -qF '// edited by hand' "$(niri_config_path)"
}

@test "a successful on asks niri to load the config exactly once" {
  write_niri_plain

  run_proxy on niri

  [ "$status" -eq 0 ]
  [ -f "$NIRI_STUB_LOG" ]
  [ "$(wc -l < "$NIRI_STUB_LOG")" -eq 1 ]
  [ "$(cat "$NIRI_STUB_LOG")" = "msg action load-config-file" ]
  [ "$(jq -r '.carriers.niri.pending_reload' "$(proxy_manifest_path)")" = "false" ]
}

@test "niri being unavailable warns but still exits 0" {
  write_niri_plain
  mkdir -p "$FIXTURE_ROOT/no-niri-bin"
  ln -s "$(command -v bash)" "$FIXTURE_ROOT/no-niri-bin/bash"
  ln -s "$(command -v python3)" "$FIXTURE_ROOT/no-niri-bin/python3"
  ln -s "$(command -v dirname)" "$FIXTURE_ROOT/no-niri-bin/dirname"

  run env PATH="$FIXTURE_ROOT/no-niri-bin" "$PROXY_BIN" on niri

  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]]
  [[ "$output" == *"niri"* ]]
  for key in $(proxy_keys); do
    grep -qE "^[[:space:]]+${key} \"" "$(niri_config_path)"
  done
}

@test "a falsy niri reload attempts one call, warns, and still exits 0" {
  write_niri_plain
  cat > "$FIXTURE_ROOT/bin/niri" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NIRI_STUB_LOG"
echo "no compositor" >&2
exit 1
STUB
  chmod +x "$FIXTURE_ROOT/bin/niri"

  run_proxy on niri

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NIRI_STUB_LOG")" -eq 1 ]
  [[ "$output" == *"warning"* ]]
  [ "$(jq -r '.carriers.niri.pending_reload' "$(proxy_manifest_path)")" = "true" ]
}

@test "writing preserves the existing file permissions" {
  write_niri_plain
  chmod 600 "$(niri_config_path)"

  run_proxy on niri

  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$(niri_config_path)")" = "600" ]

  run_proxy off niri
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$(niri_config_path)")" = "600" ]
}

@test "repeated off is idempotent and creates no extra snapshot" {
  write_niri_plain
  run_proxy on niri
  [ "$status" -eq 0 ]
  run_proxy off niri
  [ "$status" -eq 0 ]
  local first_hash first_snapshots
  first_hash="$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)"
  first_snapshots="$(proxy_snapshot_count)"

  run_proxy off niri

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(niri_config_path)" | cut -d' ' -f1)" = "$first_hash" ]
  [ "$(proxy_snapshot_count)" -eq "$first_snapshots" ]
}

@test "--dry-run writes nothing, takes no snapshot and does not call niri" {
  write_niri_plain
  local before
  before="$(snapshot_tree "$HOME" "$XDG_STATE_HOME")"

  run_proxy on niri --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"would"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_STATE_HOME")" = "$before" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "on without a carrier name switches every managed carrier" {
  write_niri_plain

  run_proxy on

  [ "$status" -eq 0 ]
  run_proxy status
  assert_carrier_state niri on
}

@test "on uses the endpoint from the XDG config" {
  write_niri_plain
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7895"
no_proxy = "localhost,example.test"
TOML

  run_proxy on niri

  [ "$status" -eq 0 ]
  grep -qF 'http_proxy "http://127.0.0.1:7895"' "$(niri_config_path)"
  grep -qF 'HTTPS_PROXY "http://127.0.0.1:7895"' "$(niri_config_path)"
  grep -qF 'NO_PROXY "localhost,example.test"' "$(niri_config_path)"
}

@test "global options are accepted before the command" {
  write_niri_plain

  run_proxy --proxy http://127.0.0.1:7999 on niri

  [ "$status" -eq 0 ]
  grep -qF 'http_proxy "http://127.0.0.1:7999"' "$(niri_config_path)"
}

@test "off creates an environment block when the config is missing" {
  rm -f "$(niri_config_path)"

  run_proxy off niri

  [ "$status" -eq 0 ]
  [ -f "$(niri_config_path)" ]
  for key in $(proxy_keys); do
    grep -qE "^[[:space:]]+${key} null$" "$(niri_config_path)"
  done
  [ "$(jq -r '.carriers.niri.original_existed' "$(proxy_manifest_path)")" = "false" ]
}

@test "unknown carriers and unmanaged carriers are usage errors" {
  run_proxy on nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown carrier"* ]]

  run_proxy on docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"read-only"* ]]
}

@test "commented and slashdashed proxy entries are left untouched" {
  write_niri_commented_proxies

  run_proxy on niri

  [ "$status" -eq 0 ]
  grep -qF '// http_proxy "http://127.0.0.1:7890"' "$(niri_config_path)"
  grep -qF '/* https_proxy "http://127.0.0.1:7890" */' "$(niri_config_path)"
  grep -qF '/- HTTP_PROXY "http://127.0.0.1:7890"' "$(niri_config_path)"
  grep -qE '^[[:space:]]+no_proxy "localhost,127.0.0.1,::1"$' "$(niri_config_path)"
  grep -qE '^[[:space:]]+http_proxy "http://127.0.0.1:7890"$' "$(niri_config_path)"
  [ "$(grep -cE '^[[:space:]]+(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY) ' "$(niri_config_path)")" -eq 6 ]
}
