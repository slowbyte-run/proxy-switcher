#!/usr/bin/env bats
#
# Black-box tests for the pnpm carrier. The only seam is the CLI: real files
# in a throwaway HOME/XDG tree, assertions on exit code and the bytes left on
# disk. Comments, quoting, key order and indentation must survive a switch.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

write_pnpm_hand_edited() {
  cat > "$(pnpm_config_path)" <<'YAML'
# pnpm settings
httpProxy: 'http://127.0.0.1:9999' # previous endpoint
httpsProxy: "http://127.0.0.1:9999"
noProxy: "localhost,old.test"
strictPeerDependencies: false

packageExtensions:
    "@scope/pkg":
        peerDependencies:
            react: "*"
YAML
}

@test "on writes the three camelCase keys and keeps other keys and comments" {
  cat > "$(pnpm_config_path)" <<'YAML'
# pnpm settings
strictPeerDependencies: false
# end of settings
YAML

  run_proxy on pnpm

  [ "$status" -eq 0 ]
  grep -qE '^httpProxy: "http://127\.0\.0\.1:7890"$' "$(pnpm_config_path)"
  grep -qE '^httpsProxy: "http://127\.0\.0\.1:7890"$' "$(pnpm_config_path)"
  grep -qE '^noProxy: "localhost,127\.0\.0\.1,::1"$' "$(pnpm_config_path)"
  grep -qF 'strictPeerDependencies: false' "$(pnpm_config_path)"
  grep -qF '# pnpm settings' "$(pnpm_config_path)"
  grep -qF '# end of settings' "$(pnpm_config_path)"
  ! grep -qE '^(http-proxy|https-proxy|noproxy):' "$(pnpm_config_path)"
  [ "$(grep -cE '^(httpProxy|httpsProxy|noProxy):' "$(pnpm_config_path)")" -eq 3 ]

  python3 - "$(pnpm_config_path)" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
assert data["httpProxy"] == "http://127.0.0.1:7890", data
assert data["httpsProxy"] == "http://127.0.0.1:7890", data
assert data["noProxy"] == "localhost,127.0.0.1,::1", data
assert data["strictPeerDependencies"] is False, data
PY
}

@test "on rewrites existing values in place, preserving inline comments and quote style" {
  write_pnpm_hand_edited
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7895"
no_proxy = "localhost,example.test"
TOML

  run_proxy on pnpm

  [ "$status" -eq 0 ]
  grep -qF "httpProxy: 'http://127.0.0.1:7895' # previous endpoint" \
    "$(pnpm_config_path)"
  grep -qF 'httpsProxy: "http://127.0.0.1:7895"' "$(pnpm_config_path)"
  grep -qF 'noProxy: "localhost,example.test"' "$(pnpm_config_path)"
  grep -qF 'strictPeerDependencies: false' "$(pnpm_config_path)"
  grep -qF '# pnpm settings' "$(pnpm_config_path)"
  [ "$(grep -cE '^(httpProxy|httpsProxy|noProxy):' "$(pnpm_config_path)")" -eq 3 ]
}

@test "on leaves an already-on file byte-identical" {
  write_pnpm_on
  local before
  before="$(sha256sum "$(pnpm_config_path)" | cut -d' ' -f1)"

  run_proxy on pnpm

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(pnpm_config_path)" | cut -d' ' -f1)" = "$before" ]
}

@test "repeated on is idempotent and creates no extra snapshot" {
  write_pnpm_off
  run_proxy on pnpm
  [ "$status" -eq 0 ]
  local first_hash first_snapshots
  first_hash="$(sha256sum "$(pnpm_config_path)" | cut -d' ' -f1)"
  first_snapshots="$(proxy_snapshot_count)"

  run_proxy on pnpm

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(pnpm_config_path)" | cut -d' ' -f1)" = "$first_hash" ]
  [ "$(proxy_snapshot_count)" -eq "$first_snapshots" ]
}

@test "off restores the original file byte for byte, including old proxy values" {
  write_pnpm_hand_edited
  chmod 600 "$(pnpm_config_path)"
  local before
  before="$(sha256sum "$(pnpm_config_path)" | cut -d' ' -f1)"

  run_proxy on pnpm
  [ "$status" -eq 0 ]
  grep -qF "httpProxy: 'http://127.0.0.1:7890'" "$(pnpm_config_path)"

  run_proxy off pnpm

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(pnpm_config_path)" | cut -d' ' -f1)" = "$before" ]
  grep -qF "httpProxy: 'http://127.0.0.1:9999' # previous endpoint" \
    "$(pnpm_config_path)"
  [ "$(stat -c '%a' "$(pnpm_config_path)")" = "600" ]
}

@test "off removes the config file when it did not exist before on" {
  rm -f "$(pnpm_config_path)"

  run_proxy on pnpm
  [ "$status" -eq 0 ]
  [ -f "$(pnpm_config_path)" ]

  run_proxy off pnpm

  [ "$status" -eq 0 ]
  [ ! -e "$(pnpm_config_path)" ]
  [ "$(jq -r '.carriers.pnpm.original_existed' "$(proxy_manifest_path)")" = "false" ]
}

@test "on creates a valid YAML file when the config is missing" {
  rm -f "$(pnpm_config_path)"

  run_proxy on pnpm

  [ "$status" -eq 0 ]
  [ -f "$(pnpm_config_path)" ]
  python3 - "$(pnpm_config_path)" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
assert data == {
    "httpProxy": "http://127.0.0.1:7890",
    "httpsProxy": "http://127.0.0.1:7890",
    "noProxy": "localhost,127.0.0.1,::1",
}, data
PY
}

@test "on leaves nested blocks and their indentation untouched" {
  write_pnpm_hand_edited
  local before_nested after_nested
  before_nested="$(sed -n '/^packageExtensions:/,$p' "$(pnpm_config_path)")"

  run_proxy on pnpm

  [ "$status" -eq 0 ]
  after_nested="$(sed -n '/^packageExtensions:/,$p' "$(pnpm_config_path)")"
  [ "$before_nested" = "$after_nested" ]
}

@test "on preserves CRLF line endings in the original file" {
  printf '# pnpm settings\r\nstrictPeerDependencies: false\r\n' \
    > "$(pnpm_config_path)"

  run_proxy on pnpm

  [ "$status" -eq 0 ]
  python3 - "$(pnpm_config_path)" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
assert b"\r\n" in data, data
assert data.replace(b"\r\n", b"").find(b"\n") == -1, data
assert b"httpProxy:" in data, data
PY
}

@test "status reports pnpm on after on and off after off" {
  write_pnpm_off
  run_proxy on pnpm
  [ "$status" -eq 0 ]

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state pnpm on

  run_proxy off pnpm
  [ "$status" -eq 0 ]

  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state pnpm off
}
