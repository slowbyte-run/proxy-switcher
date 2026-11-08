#!/usr/bin/env bats
#
# Black-box tests for the ssh carrier. The only seam is the CLI: a throwaway
# HOME holding an ssh config, assertions on exit code, output and the bytes
# left on disk. `ssh -G` is used as an independent reader of the final file.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

# A config where every block is distinguishable: only the github.com block is
# allowed to change.
write_ssh_tricky() {
  cat > "$(ssh_config_path)" <<'SSH'
# global settings
Host example.com
    HostName example.com
    User git
    ProxyCommand ncat --proxy 127.0.0.1:9999 --proxy-type http %h %p

Host github.com
    HostName ssh.github.com
    User git
    Port 443
    # route GitHub SSH through the local proxy
    ProxyCommand none

Host internal.example
    HostName 10.0.0.1
    ProxyCommand none
SSH
}

write_ssh_proxy_on() {
  cat > "$(ssh_config_path)" <<'SSH'
# global settings
Host example.com
    HostName example.com
    User git
    ProxyCommand ncat --proxy 127.0.0.1:9999 --proxy-type http %h %p

Host github.com
    HostName ssh.github.com
    User git
    Port 443
    ProxyCommand ncat --proxy 127.0.0.1:7895 --proxy-type http %h %p

Host internal.example
    HostName 10.0.0.1
    ProxyCommand none
SSH
}

# The github.com block exists but carries no ProxyCommand yet.
write_ssh_without_github_proxy() {
  cat > "$(ssh_config_path)" <<'SSH'
Host example.com
    HostName example.com
    ProxyCommand ncat --proxy 127.0.0.1:9999 --proxy-type http %h %p

Host github.com
    HostName ssh.github.com
    User git
    Port 443

Host internal.example
    HostName 10.0.0.1
SSH
}

# Body of one Host block, excluding the Host line itself.
host_block() {
  local want="$1"
  awk -v want="$want" '
    tolower($1) == "host" { inside = ($2 == want); next }
    inside { print }
  ' "$(ssh_config_path)"
}

proxy_line() {
  printf '%s\n' "$1" | grep -E '^[[:space:]]*ProxyCommand ' | head -n1
}

@test "on writes the ncat ProxyCommand only inside the github.com block" {
  write_ssh_tricky
  local before_example before_internal
  before_example="$(host_block example.com)"
  before_internal="$(host_block internal.example)"

  run_proxy on ssh

  [ "$status" -eq 0 ]
  [ "$(host_block example.com)" = "$before_example" ]
  [ "$(host_block internal.example)" = "$before_internal" ]
  [ "$(proxy_line "$(host_block github.com)")" = \
    "    ProxyCommand ncat --proxy 127.0.0.1:7890 --proxy-type http %h %p" ]
  grep -qF '# route GitHub SSH through the local proxy' "$(ssh_config_path)"
  grep -qF '# global settings' "$(ssh_config_path)"
  [ "$(grep -c 'ProxyCommand ncat --proxy 127.0.0.1:9999' "$(ssh_config_path)")" -eq 1 ]
}

@test "off writes ProxyCommand none and leaves every other block byte-identical" {
  write_ssh_proxy_on
  local before_example before_internal
  before_example="$(host_block example.com)"
  before_internal="$(host_block internal.example)"

  run_proxy off ssh

  [ "$status" -eq 0 ]
  [ "$(host_block example.com)" = "$before_example" ]
  [ "$(host_block internal.example)" = "$before_internal" ]
  [ "$(proxy_line "$(host_block github.com)")" = "    ProxyCommand none" ]
  [ "$(grep -c 'ProxyCommand ncat --proxy 127.0.0.1:9999' "$(ssh_config_path)")" -eq 1 ]
}

@test "off adds ProxyCommand none when the github.com block has none" {
  write_ssh_without_github_proxy
  local before_example before_internal
  before_example="$(host_block example.com)"
  before_internal="$(host_block internal.example)"

  run_proxy off ssh

  [ "$status" -eq 0 ]
  [ "$(host_block example.com)" = "$before_example" ]
  [ "$(host_block internal.example)" = "$before_internal" ]
  [ "$(proxy_line "$(host_block github.com)")" = "    ProxyCommand none" ]
}

@test "on inserts ProxyCommand when the github.com block has none" {
  write_ssh_without_github_proxy

  run_proxy on ssh

  [ "$status" -eq 0 ]
  [ "$(proxy_line "$(host_block github.com)")" = \
    "    ProxyCommand ncat --proxy 127.0.0.1:7890 --proxy-type http %h %p" ]
  grep -qF 'ProxyCommand ncat --proxy 127.0.0.1:9999' "$(ssh_config_path)"
  [ "$(grep -c '^Host ' "$(ssh_config_path)")" -eq 3 ]
}

@test "on updates the port when the configured endpoint changes" {
  write_ssh_tricky
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7895"
TOML

  run_proxy on ssh
  [ "$status" -eq 0 ]
  grep -qF 'ProxyCommand ncat --proxy 127.0.0.1:7895 --proxy-type http %h %p' \
    "$(ssh_config_path)"

  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7896"
TOML

  run_proxy on ssh

  [ "$status" -eq 0 ]
  grep -qF 'ProxyCommand ncat --proxy 127.0.0.1:7896 --proxy-type http %h %p' \
    "$(ssh_config_path)"
  ! grep -qF '127.0.0.1:7895' "$(ssh_config_path)"
}

@test "ssh -G reports the expected proxycommand after on" {
  write_ssh_tricky
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7897"
TOML

  run_proxy on ssh
  [ "$status" -eq 0 ]

  # -F keeps OpenSSH on the fixture file: ssh -G resolves ~ from passwd, not $HOME.
  run ssh -G -F "$(ssh_config_path)" github.com

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk 'tolower($1) == "proxycommand" { print; exit }')" = \
    "proxycommand ncat --proxy 127.0.0.1:7897 --proxy-type http %h %p" ]
}

@test "ssh -G reports no proxycommand after off" {
  write_ssh_proxy_on

  run_proxy off ssh
  [ "$status" -eq 0 ]

  run ssh -G -F "$(ssh_config_path)" github.com

  [ "$status" -eq 0 ]
  [ -z "$(printf '%s\n' "$output" | awk 'tolower($1) == "proxycommand" { print; exit }')" ]
}

@test "status reports ssh off with the direct-access consequence" {
  write_ssh_tricky

  run_proxy status

  [ "$status" -eq 0 ]
  assert_carrier_state ssh off
  [[ "$output" == *"direct"* ]]
  [[ "$output" == *"unreachable"* ]]
}

@test "status reports ssh on after on and off after off" {
  write_ssh_tricky

  run_proxy on ssh
  [ "$status" -eq 0 ]
  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state ssh on

  run_proxy off ssh
  [ "$status" -eq 0 ]
  run_proxy status
  [ "$status" -eq 0 ]
  assert_carrier_state ssh off
}

@test "repeated on is idempotent and creates no extra snapshot" {
  write_ssh_tricky
  run_proxy on ssh
  [ "$status" -eq 0 ]
  local first_hash first_snapshots
  first_hash="$(sha256sum "$(ssh_config_path)" | cut -d' ' -f1)"
  first_snapshots="$(proxy_snapshot_count)"
  [ "$first_snapshots" -eq 1 ]

  run_proxy on ssh

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(ssh_config_path)" | cut -d' ' -f1)" = "$first_hash" ]
  [ "$(proxy_snapshot_count)" -eq "$first_snapshots" ]
}

@test "on creates a 600 ssh config when the file is missing" {
  rm -f "$(ssh_config_path)"

  run_proxy on ssh

  [ "$status" -eq 0 ]
  [ -f "$(ssh_config_path)" ]
  [ "$(stat -c '%a' "$(ssh_config_path)")" = "600" ]
  grep -qF 'Host github.com' "$(ssh_config_path)"
  grep -qF 'ProxyCommand ncat --proxy 127.0.0.1:7890 --proxy-type http %h %p' \
    "$(ssh_config_path)"
}

@test "switching preserves the existing config permission bits" {
  write_ssh_tricky
  chmod 600 "$(ssh_config_path)"

  run_proxy on ssh
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$(ssh_config_path)")" = "600" ]

  run_proxy off ssh
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$(ssh_config_path)")" = "600" ]
}

@test "--dry-run writes nothing and takes no snapshot" {
  write_ssh_tricky
  local before
  before="$(snapshot_tree "$HOME" "$XDG_STATE_HOME")"

  run_proxy on ssh --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"would"* ]]
  [ "$(snapshot_tree "$HOME" "$XDG_STATE_HOME")" = "$before" ]
}
