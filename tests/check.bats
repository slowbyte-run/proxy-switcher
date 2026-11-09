#!/usr/bin/env bats
#
# Black-box tests for `proxysw status --check`. The only seam is the CLI.
#
# The "up" case is proven with a real loopback TCP listener that records any
# bytes it receives: a pure connect probe must leave that record empty, which
# is how we prove no HTTP request was sent. Timeout and resolution cases stay
# offline: closed loopback ports and a hostname that fails before any DNS query.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
  PROBE_PORT_FILE="$FIXTURE_ROOT/probe.port"
  PROBE_RECEIVED_FILE="$FIXTURE_ROOT/probe.received"
  SERVER_PID=""
}

teardown() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

# Start a loopback listener on a kernel-assigned port. It accepts one
# connection, records whatever bytes arrive for a short window, then exits.
start_probe_server() {
  cat > "$FIXTURE_ROOT/probe_server.py" <<'PY'
import socket
import sys

port_file, received_file = sys.argv[1], sys.argv[2]
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.getsockname()[1]))

connection, _ = server.accept()
connection.settimeout(0.3)
data = b""
try:
    while True:
        chunk = connection.recv(4096)
        if not chunk:
            break
        data += chunk
        if len(data) >= 8:
            break
except socket.timeout:
    pass
with open(received_file, "wb") as handle:
    handle.write(data)
connection.close()
server.close()
PY
  rm -f "$PROBE_PORT_FILE" "$PROBE_RECEIVED_FILE"
  python3 "$FIXTURE_ROOT/probe_server.py" \
    "$PROBE_PORT_FILE" "$PROBE_RECEIVED_FILE" &
  SERVER_PID=$!

  local attempt
  for attempt in $(seq 1 200); do
    [[ -s "$PROBE_PORT_FILE" ]] && return 0
    sleep 0.01
  done
  return 1
}

# Ask the kernel for a port that currently has no listener.
free_port() {
  python3 - <<'PY'
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

endpoint_line() {
  printf '%s\n' "$output" | grep -E '^endpoint[[:space:]]' | head -n1
}

@test "status --check marks a listening endpoint as up" {
  start_probe_server
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(cat "$PROBE_PORT_FILE")"
TOML

  run_proxysw status --check

  [ "$status" -eq 0 ]
  [[ "$(endpoint_line)" =~ ^endpoint[[:space:]]+.*[[:space:]]up$ ]]
}

@test "status --check sends no HTTP request to the endpoint" {
  start_probe_server
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(cat "$PROBE_PORT_FILE")"
TOML

  run_proxysw status --check
  [ "$status" -eq 0 ]

  local attempt
  for attempt in $(seq 1 300); do
    [[ -f "$PROBE_RECEIVED_FILE" ]] && break
    sleep 0.01
  done
  [ -f "$PROBE_RECEIVED_FILE" ]
  [ ! -s "$PROBE_RECEIVED_FILE" ]
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

@test "status --check marks a closed port as down and still exits 0" {
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(free_port)"
TOML

  run_proxysw status --check

  [ "$status" -eq 0 ]
  [[ "$(endpoint_line)" =~ ^endpoint[[:space:]]+.*[[:space:]]down$ ]]
}

@test "status --check does not report down as a failure" {
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(free_port)"
TOML

  run_proxysw status --check --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e . >/dev/null
  [ "$(printf '%s\n' "$output" | jq -r '.check.state')" = "down" ]
  [ "$(printf '%s\n' "$output" | jq -r '.carriers | length')" -eq 6 ]
}

@test "status --check --json reports up and the probed host and port" {
  start_probe_server
  local port
  port="$(cat "$PROBE_PORT_FILE")"
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:${port}"
TOML

  run_proxysw status --check --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.check.state')" = "up" ]
  [ "$(printf '%s\n' "$output" | jq -r '.check.host')" = "127.0.0.1" ]
  [ "$(printf '%s\n' "$output" | jq -r '.check.port')" -eq "$port" ]
}

@test "status --check follows --proxy instead of the configured endpoint" {
  start_probe_server
  local port
  port="$(cat "$PROBE_PORT_FILE")"
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:9"
TOML

  run_proxysw --proxy "http://127.0.0.1:${port}" status --check --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.check.state')" = "up" ]
  [ "$(printf '%s\n' "$output" | jq -r '.endpoint')" = "http://127.0.0.1:${port}" ]
}

@test "status without --check does not probe and has no check field" {
  start_probe_server
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(cat "$PROBE_PORT_FILE")"
TOML

  run_proxysw status --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r 'has("check")')" = "false" ]
  sleep 0.1
  [ ! -f "$PROBE_RECEIVED_FILE" ]
}

@test "status --check returns within one second when a loopback port is closed" {
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(free_port)"
TOML

  local started finished elapsed_ms
  started="$(date +%s%N)"
  run_proxysw status --check
  finished="$(date +%s%N)"

  [ "$status" -eq 0 ]
  elapsed_ms=$(( (finished - started) / 1000000 ))
  [ "$elapsed_ms" -lt 1000 ]
  [[ "$(endpoint_line)" =~ ^endpoint[[:space:]]+.*[[:space:]]down$ ]]
}

@test "status --check resolves a loopback hostname without external DNS" {
  start_probe_server
  local port
  port="$(cat "$PROBE_PORT_FILE")"
  write_proxy_config <<TOML
endpoint = "http://localhost:${port}"
TOML

  run_proxysw status --check

  [ "$status" -eq 0 ]
  [[ "$(endpoint_line)" =~ ^endpoint[[:space:]]+.*[[:space:]]up$ ]]
}

@test "status --check returns within one second when the hostname cannot be resolved" {
  # A label longer than 63 bytes is rejected before any DNS query, so this
  # stays offline while exercising the resolution-failure path.
  local long_label
  long_label="$(printf 'a%.0s' $(seq 1 70))"
  write_proxy_config <<TOML
endpoint = "http://${long_label}.invalid:9"
TOML

  local started finished elapsed_ms
  started="$(date +%s%N)"
  run_proxysw status --check
  finished="$(date +%s%N)"

  [ "$status" -eq 0 ]
  elapsed_ms=$(( (finished - started) / 1000000 ))
  [ "$elapsed_ms" -lt 1000 ]
  [[ "$(endpoint_line)" =~ ^endpoint[[:space:]]+.*[[:space:]]down$ ]]
}

@test "status --check performs no writes and never invokes niri" {
  write_all_carriers_on
  local before after
  before="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"

  run_proxysw status --check

  [ "$status" -eq 0 ]
  after="$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$REPO_ROOT")"
  [ "$before" = "$after" ]
  [ ! -e "$NIRI_STUB_LOG" ]
}

@test "--require-up exits 1 when the endpoint is down" {
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(free_port)"
TOML

  run_proxysw status --require-up

  [ "$status" -eq 1 ]
  [[ "$(endpoint_line)" =~ ^endpoint[[:space:]]+.*[[:space:]]down$ ]]
}

@test "--require-up exits 0 when the endpoint is up" {
  start_probe_server
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(cat "$PROBE_PORT_FILE")"
TOML

  run_proxysw status --require-up

  [ "$status" -eq 0 ]
  [[ "$(endpoint_line)" =~ ^endpoint[[:space:]]+.*[[:space:]]up$ ]]
}

@test "--require-up implies the probe instead of needing --check" {
  start_probe_server
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(cat "$PROBE_PORT_FILE")"
TOML

  run_proxysw status --require-up --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.check.state')" = "up" ]
}

@test "--require-up without --check still probes exactly once" {
  start_probe_server
  write_proxy_config <<TOML
endpoint = "http://127.0.0.1:$(cat "$PROBE_PORT_FILE")"
TOML

  run_proxysw status --require-up

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^endpoint')" -eq 1 ]
}

@test "--require-up is rejected for switch commands and env" {
  run_proxysw on --require-up
  [ "$status" -eq 2 ]

  run_proxysw env --require-up
  [ "$status" -eq 2 ]
}
