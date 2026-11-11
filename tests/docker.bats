#!/usr/bin/env bats
#
# Black-box tests for the docker carrier: the container proxies in
# ~/.docker/config.json. The only seam is the CLI, with a throwaway HOME, a
# stub docker that answers the bridge-gateway question, and assertions on exit
# code, output and the bytes left on disk.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

docker_json() {
  jq -r "$1" "$(docker_config_path)"
}

docker_hash() {
  sha256sum "$(docker_config_path)" | cut -d' ' -f1
}

@test "on writes the container endpoint and keeps auths, noProxy and mode" {
  write_docker_on
  chmod 640 "$(docker_config_path)"

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://172.17.0.1:7890" ]
  [ "$(docker_json '.proxies.default.httpsProxy')" = "http://172.17.0.1:7890" ]
  [ "$(docker_json '.proxies.default.noProxy')" = "localhost,127.0.0.1,postgres" ]
  [ "$(docker_json '.auths["https://index.docker.io/v1/"].auth')" = "Zml4dHVyZQ==" ]
  [ "$(stat -c '%a' "$(docker_config_path)")" = "640" ]
}

@test "on asks the daemon for the bridge gateway" {
  write_docker_off
  export STUB_DOCKER_LOG="$FIXTURE_ROOT/docker-argv.log"

  run_proxysw on docker

  [ "$status" -eq 0 ]
  grep -qxF -- \
    'network inspect bridge --format {{(index .IPAM.Config 0).Gateway}}' \
    "$STUB_DOCKER_LOG"
}

@test "on reuses a non-loopback endpoint without asking the daemon" {
  write_docker_off
  write_proxy_config <<'TOML'
endpoint = "http://192.168.1.9:7890"
TOML
  export STUB_DOCKER_LOG="$FIXTURE_ROOT/docker-argv.log"

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://192.168.1.9:7890" ]
  [ ! -e "$STUB_DOCKER_LOG" ]
}

@test "container_endpoint overrides the derived address and skips docker" {
  write_docker_off
  write_proxy_config <<'TOML'
container_endpoint = "http://10.0.2.2:7891"
TOML
  export STUB_DOCKER_LOG="$FIXTURE_ROOT/docker-argv.log"

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://10.0.2.2:7891" ]
  [ "$(docker_json '.proxies.default.httpsProxy')" = "http://10.0.2.2:7891" ]
  [ ! -e "$STUB_DOCKER_LOG" ]
}

@test "an invalid container_endpoint is a configuration error" {
  write_proxy_config <<'TOML'
container_endpoint = "socks5://10.0.2.2:1080"
TOML

  run_proxysw status

  [ "$status" -eq 1 ]
  [[ "$output" == *"container_endpoint"* ]]
}

@test "--proxy moves the derived address with the port" {
  write_docker_off

  run_proxysw on docker --proxy http://127.0.0.1:7895

  [ "$status" -eq 0 ]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://172.17.0.1:7895" ]
}

@test "the container endpoint keeps userinfo in the proxy URL" {
  write_docker_off

  run_proxysw on docker --proxy http://user:secret@127.0.0.1:7890

  [ "$status" -eq 0 ]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://user:secret@172.17.0.1:7890" ]
}

@test "on creates a missing config file with mode 600" {
  run_proxysw on docker

  [ "$status" -eq 0 ]
  [ -f "$(docker_config_path)" ]
  [ "$(stat -c '%a' "$(docker_config_path)")" = "600" ]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://172.17.0.1:7890" ]
}

@test "on is idempotent" {
  write_docker_off
  run_proxysw on docker
  local before
  before="$(docker_hash)"

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [[ "$output" == *"docker: already on"* ]]
  [ "$(docker_hash)" = "$before" ]
}

@test "off removes only the two managed keys" {
  mkdir -p "$(dirname "$(docker_config_path)")"
  cat > "$(docker_config_path)" <<'JSON'
{
    "auths": {
        "https://index.docker.io/v1/": {
            "auth": "Zml4dHVyZQ=="
        }
    },
    "proxies": {
        "default": {
            "httpProxy": "http://172.17.0.1:7890",
            "httpsProxy": "http://172.17.0.1:7890",
            "noProxy": "localhost,127.0.0.1,postgres"
        },
        "tcp://remote:2375": {
            "httpProxy": "http://remote-proxy:3128"
        }
    }
}
JSON
  chmod 600 "$(docker_config_path)"

  run_proxysw off docker

  [ "$status" -eq 0 ]
  [ "$(docker_json '.proxies.default | has("httpProxy")')" = "false" ]
  [ "$(docker_json '.proxies.default | has("httpsProxy")')" = "false" ]
  [ "$(docker_json '.proxies.default.noProxy')" = "localhost,127.0.0.1,postgres" ]
  [ "$(docker_json '.proxies["tcp://remote:2375"].httpProxy')" = "http://remote-proxy:3128" ]
  [ "$(docker_json '.auths["https://index.docker.io/v1/"].auth')" = "Zml4dHVyZQ==" ]
}

@test "off drops an emptied proxies object" {
  mkdir -p "$(dirname "$(docker_config_path)")"
  cat > "$(docker_config_path)" <<'JSON'
{
    "proxies": {
        "default": {
            "httpProxy": "http://172.17.0.1:7890",
            "httpsProxy": "http://172.17.0.1:7890"
        }
    }
}
JSON

  run_proxysw off docker

  [ "$status" -eq 0 ]
  [ "$(docker_json 'has("proxies")')" = "false" ]
}

@test "off leaves a file that on created instead of deleting it" {
  run_proxysw on docker
  [ "$status" -eq 0 ]

  run_proxysw off docker

  [ "$status" -eq 0 ]
  [ -f "$(docker_config_path)" ]
  [ "$(docker_json 'has("proxies")')" = "false" ]
  [ "$(stat -c '%a' "$(docker_config_path)")" = "600" ]
}

@test "off is a byte-level no-op when the keys are already gone" {
  write_docker_off
  local before
  before="$(docker_hash)"

  run_proxysw off docker

  [ "$status" -eq 0 ]
  [ "$(docker_hash)" = "$before" ]
}

@test "restore brings back the original bytes" {
  mkdir -p "$(dirname "$(docker_config_path)")"
  cat > "$(docker_config_path)" <<'JSON'
{
    "auths": {},
    "proxies": {
        "default": {
            "httpProxy": "http://hand-written:1",
            "httpsProxy": "http://hand-written:1"
        }
    }
}
JSON
  cp "$(docker_config_path)" "$FIXTURE_ROOT/original.json"

  run_proxysw on docker
  [ "$status" -eq 0 ]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://172.17.0.1:7890" ]

  run_proxysw restore docker
  [ "$status" -eq 0 ]
  cmp -s "$(docker_config_path)" "$FIXTURE_ROOT/original.json"
}

@test "restore deletes a file that on created" {
  run_proxysw on docker
  [ "$status" -eq 0 ]

  run_proxysw restore docker

  [ "$status" -eq 0 ]
  [ ! -e "$(docker_config_path)" ]
}

@test "DOCKER_CONFIG moves the file" {
  export DOCKER_CONFIG="$FIXTURE_ROOT/docker-config"

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [ -f "$DOCKER_CONFIG/config.json" ]
  run_proxysw status
  assert_carrier_state docker on
  [[ "$output" == *"$DOCKER_CONFIG/config.json"* ]]
}

@test "an unreachable daemon warns and leaves the file alone" {
  write_docker_off
  local before
  before="$(docker_hash)"
  export STUB_DOCKER_EXIT=1

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot resolve the container-side address"* ]]
  [ "$(docker_hash)" = "$before" ]
}

@test "an unreachable daemon leaves a warning in the JSON plan" {
  write_docker_off
  export STUB_DOCKER_EXIT=1

  run bash -c '"$PROXYSW_BIN" on docker --json 2>/dev/null'

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e . >/dev/null
  [ "$(printf '%s\n' "$output" | jq -r '.carriers[0].changed')" = "false" ]
  [ "$(printf '%s\n' "$output" | jq -r '.carriers[0].warning')" != "" ]
}

@test "an empty gateway answer warns and leaves the file alone" {
  write_docker_off
  export STUB_DOCKER_STDOUT=""

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot resolve the container-side address"* ]]
  [ "$(docker_json '.proxies.default // empty')" = "" ]
}

@test "invalid JSON fails the carrier without a traceback" {
  mkdir -p "$(dirname "$(docker_config_path)")"
  printf '{"auths": {' > "$(docker_config_path)"

  run_proxysw on docker

  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]]
  [[ "$output" != *"Traceback"* ]]

  run_proxysw status
  [ "$status" -eq 0 ]
  assert_carrier_state docker off
  [[ "$output" == *"not valid JSON"* ]]
}

@test "docker rewriting auths is not a conflict" {
  write_docker_off
  run_proxysw on docker
  [ "$status" -eq 0 ]

  # What `docker login` or a token refresh does: rewrite the whole file.
  local temporary="$FIXTURE_ROOT/rewritten.json"
  jq '.auths["https://example.com"] = {"auth": "bmV3"}' \
    "$(docker_config_path)" > "$temporary"
  mv "$temporary" "$(docker_config_path)"

  run_proxysw on docker

  [ "$status" -eq 0 ]
  [[ "$output" != *"conflict"* ]]
  [ "$(docker_json '.auths["https://example.com"].auth')" = "bmV3" ]
}

@test "editing a managed key is a conflict" {
  write_docker_off
  run_proxysw on docker
  [ "$status" -eq 0 ]

  local temporary="$FIXTURE_ROOT/edited.json"
  jq '.proxies.default.httpProxy = "http://hand-edited:1"' \
    "$(docker_config_path)" > "$temporary"
  mv "$temporary" "$(docker_config_path)"

  run_proxysw on docker

  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict: docker"* ]]
  [ "$(docker_json '.proxies.default.httpProxy')" = "http://hand-edited:1" ]
}

@test "status warns about a loopback proxy and unmanaged keys" {
  mkdir -p "$(dirname "$(docker_config_path)")"
  cat > "$(docker_config_path)" <<'JSON'
{
    "proxies": {
        "default": {
            "httpProxy": "http://127.0.0.1:7890",
            "httpsProxy": "http://127.0.0.1:7890",
            "allProxy": "socks5://127.0.0.1:1080"
        }
    }
}
JSON

  run_proxysw status

  [ "$status" -eq 0 ]
  [[ "$output" == *"loopback"* ]]
  [[ "$output" == *"not managed"* ]]
}

@test "status reports on and off from the two keys" {
  write_docker_on
  run_proxysw status
  assert_carrier_state docker on

  write_docker_off
  run_proxysw status
  assert_carrier_state docker off
}

@test "status --json carries the docker row with its path and schema" {
  write_docker_off

  run_proxysw status --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e . >/dev/null
  [ "$(printf '%s\n' "$output" | jq -r .schema)" -eq 2 ]
  [ "$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "docker") | .path')" = "$(docker_config_path)" ]
  [ "$(printf '%s\n' "$output" | jq -r \
    '.carriers[] | select(.name == "docker-daemon") | .state')" = "unmanaged" ]
}

@test "--dry-run writes nothing and names the file" {
  write_docker_off
  local before
  before="$(docker_hash)"

  run_proxysw on docker --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"would turn on"* ]]
  [[ "$output" == *"$(docker_config_path)"* ]]
  [ "$(docker_hash)" = "$before" ]
}
