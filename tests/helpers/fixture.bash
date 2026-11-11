# shellcheck shell=bash
# `output` and `status` below are set by bats, not by this file.
# shellcheck disable=SC2154

# Fixture factory shared by all bats tests.
#
# Every test runs inside a throwaway HOME and XDG tree rooted at
# $BATS_TEST_TMPDIR, with a stub niri that only records its argv. Nothing
# here touches the real home directory or a real compositor.

fixture_init() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture"

  export HOME="$FIXTURE_ROOT/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state"
  # The concurrency lock lives in the runtime directory. Pointing it inside the
  # fixture keeps tests off the real one and gives each test its own lock.
  export XDG_RUNTIME_DIR="$FIXTURE_ROOT/run"
  export SHELL=/bin/zsh
  export PROXYSW_BIN="$REPO_ROOT/bin/proxysw"
  export NIRI_STUB_LOG="$FIXTURE_ROOT/niri-argv.log"

  mkdir -p "$HOME" \
    "$XDG_CONFIG_HOME/niri" \
    "$XDG_CONFIG_HOME/pnpm" \
    "$HOME/.ssh" \
    "$XDG_RUNTIME_DIR" \
    "$FIXTURE_ROOT/bin"

  cat > "$FIXTURE_ROOT/bin/niri" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NIRI_STUB_LOG"
exit 0
STUB
  chmod +x "$FIXTURE_ROOT/bin/niri"

  # The docker carrier asks the daemon for the bridge gateway. The stub answers
  # with a fixed address so tests never talk to a real daemon; a test can point
  # STUB_DOCKER_STDOUT elsewhere or fail the call with STUB_DOCKER_EXIT.
  cat > "$FIXTURE_ROOT/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_DOCKER_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$STUB_DOCKER_LOG"
fi
if [ -n "${STUB_DOCKER_STDOUT:-}" ]; then
  printf '%s\n' "$STUB_DOCKER_STDOUT"
fi
exit "${STUB_DOCKER_EXIT:-0}"
STUB
  chmod +x "$FIXTURE_ROOT/bin/docker"
  # Only a default, so a test that wants an empty answer can still set it.
  STUB_DOCKER_STDOUT="${STUB_DOCKER_STDOUT-172.17.0.1}"
  export STUB_DOCKER_STDOUT

  # The picker is the TUI's only external collaborator besides the CLI. This
  # stub drains the list it is fed, records it, and prints whatever selection
  # the test asked for. Tests never need a terminal.
  #
  # It also emulates the one fzf behaviour the preview depends on: when
  # STUB_FZF_PREVIEW_LOG is set, it runs the --preview command once per row
  # with {n} replaced by that row's nth tab-separated field, and appends the
  # output to the log. That is fzf's documented placeholder substitution, so a
  # test can inspect the real preview text without a pty or a real fzf.
  cat > "$FIXTURE_ROOT/bin/fzf" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${STUB_FZF_ARGV_LOG:-}" ]; then
  printf '%s\n' "$@" > "$STUB_FZF_ARGV_LOG"
fi

input="$(cat)"
if [ -n "${STUB_FZF_STDIN_LOG:-}" ]; then
  printf '%s\n' "$input" > "$STUB_FZF_STDIN_LOG"
fi

if [ -n "${STUB_FZF_PREVIEW_LOG:-}" ]; then
  preview=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = "--preview" ]; then
      preview="$argument"
    fi
    previous="$argument"
  done
  # Bash 5.2 turns `&` in a substitution replacement into the matched text;
  # fzf does not, and neither does this stub.
  shopt -u patsub_replacement 2>/dev/null || true
  if [ -n "$input" ]; then
    while IFS= read -r row; do
      fields=()
      rest="$row"
      while [[ "$rest" == *$'\t'* ]]; do
        fields+=("${rest%%$'\t'*}")
        rest="${rest#*$'\t'}"
      done
      fields+=("$rest")
      rendered="$preview"
      for index in "${!fields[@]}"; do
        printf -v quoted '%q' "${fields[$index]}"
        rendered="${rendered//\{$((index + 1))\}/$quoted}"
      done
      sh -c "$rendered" >> "$STUB_FZF_PREVIEW_LOG"
    done <<< "$input"
  fi
fi

if [ -n "${STUB_FZF_SLEEP:-}" ]; then
  sleep "$STUB_FZF_SLEEP"
fi
if [ -n "${STUB_FZF_STDERR:-}" ]; then
  printf '%s\n' "$STUB_FZF_STDERR" >&2
fi
if [ -n "${STUB_FZF_EXIT:-}" ]; then
  exit "$STUB_FZF_EXIT"
fi
if [ -n "${STUB_FZF_OUTPUT:-}" ]; then
  printf '%s\n' "$STUB_FZF_OUTPUT"
fi
STUB
  chmod +x "$FIXTURE_ROOT/bin/fzf"

  PATH="$FIXTURE_ROOT/bin:$PATH"
  export PATH
}

run_proxysw() {
  run "$PROXYSW_BIN" "$@"
}

niri_config_path() { printf '%s\n' "$XDG_CONFIG_HOME/niri/config.kdl"; }
shell_rc_path() {
  case "$(basename "${SHELL:-}")" in
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    *) printf '%s\n' "$HOME/.zshrc" ;;
  esac
}
npmrc_path() { printf '%s\n' "$HOME/.npmrc"; }
pnpm_config_path() { printf '%s\n' "$XDG_CONFIG_HOME/pnpm/config.yaml"; }
ssh_config_path() { printf '%s\n' "$HOME/.ssh/config"; }
docker_config_path() { printf '%s\n' "$HOME/.docker/config.json"; }

proxy_keys() {
  printf '%s\n' \
    http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
}

managed_carriers() {
  printf '%s\n' niri shell npm pnpm ssh docker
}

carrier_path() {
  case "$1" in
    niri) niri_config_path ;;
    shell) shell_rc_path ;;
    npm) npmrc_path ;;
    pnpm) pnpm_config_path ;;
    ssh) ssh_config_path ;;
    docker) docker_config_path ;;
    *) return 1 ;;
  esac
}

write_niri_plain() {
  cat > "$(niri_config_path)" <<'KDL'
// niri configuration
environment {
    LANG "zh_CN.UTF-8"
    QT_QPA_PLATFORM "wayland"

    // keep this comment
    GODEBUG "http2client=0"
}

input {
    keyboard {
        repeat-delay 400
    }
}
KDL
}

write_niri_on() {
  cat > "$(niri_config_path)" <<'KDL'
// niri configuration
environment {
    LANG "zh_CN.UTF-8"
    QT_QPA_PLATFORM "wayland"

    // proxy variables written by proxy-switcher
    http_proxy "http://127.0.0.1:7890"
    https_proxy "http://127.0.0.1:7890"
    HTTP_PROXY "http://127.0.0.1:7890"
    HTTPS_PROXY "http://127.0.0.1:7890"
    no_proxy "localhost,127.0.0.1,::1"
    NO_PROXY "localhost,127.0.0.1,::1"
    NODE_USE_ENV_PROXY "1"
}

input {
    keyboard {
        repeat-delay 400
    }
}
KDL
}

write_niri_off() {
  cat > "$(niri_config_path)" <<'KDL'
environment {
    LANG "zh_CN.UTF-8"
    http_proxy null
    https_proxy null
    HTTP_PROXY null
    HTTPS_PROXY null
    no_proxy null
    NO_PROXY null
    NODE_USE_ENV_PROXY null
}
KDL
}

write_niri_without_environment_block() {
  cat > "$(niri_config_path)" <<'KDL'
// no environment block here
input {
    keyboard {
        repeat-delay 400
    }
}
KDL
}

write_niri_commented_proxies() {
  cat > "$(niri_config_path)" <<'KDL'
environment {
    LANG "zh_CN.UTF-8"
    // http_proxy "http://127.0.0.1:7890"
    /* https_proxy "http://127.0.0.1:7890" */
    /- HTTP_PROXY "http://127.0.0.1:7890"
    no_proxy null
}
KDL
}

write_shell_on() {
  cat > "$(shell_rc_path)" <<'SH'
# interactive shell setup
export PATH="$HOME/bin:$PATH"
export NODE_USE_ENV_PROXY=1

# >>> proxy-switcher >>>
export http_proxy="http://127.0.0.1:7890"
export https_proxy="http://127.0.0.1:7890"
export HTTP_PROXY="http://127.0.0.1:7890"
export HTTPS_PROXY="http://127.0.0.1:7890"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
export NODE_USE_ENV_PROXY=1
# <<< proxy-switcher <<<
SH
}

write_shell_off() {
  cat > "$(shell_rc_path)" <<'SH'
# interactive shell setup
export PATH="$HOME/bin:$PATH"
export NODE_USE_ENV_PROXY=1

# >>> proxy-switcher >>>
unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset no_proxy
unset NO_PROXY
# <<< proxy-switcher <<<
SH
}

write_shell_raw_exports() {
  cat > "$(shell_rc_path)" <<'SH'
# hand-written proxy settings from before proxy-switcher
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export NODE_USE_ENV_PROXY=1
SH
}

write_npm_on() {
  cat > "$(npmrc_path)" <<'NPM'
registry=https://registry.npmmirror.com
proxy=http://127.0.0.1:7890
https-proxy=http://127.0.0.1:7890
noproxy=localhost,127.0.0.1,::1
NPM
  chmod 600 "$(npmrc_path)"
}

write_npm_off() {
  cat > "$(npmrc_path)" <<'NPM'
registry=https://registry.npmmirror.com
prefix=~/.npm-global
NPM
  chmod 600 "$(npmrc_path)"
}

write_npm_duplicate_keys_off() {
  cat > "$(npmrc_path)" <<'NPM'
registry=https://registry.npmmirror.com
proxy=http://127.0.0.1:7890
https-proxy=http://127.0.0.1:7890
proxy=
https-proxy=
NPM
  chmod 600 "$(npmrc_path)"
}

write_pnpm_on() {
  cat > "$(pnpm_config_path)" <<'YAML'
httpProxy: "http://127.0.0.1:7890"
httpsProxy: "http://127.0.0.1:7890"
noProxy: "localhost,127.0.0.1,::1"
YAML
}

write_pnpm_off() {
  cat > "$(pnpm_config_path)" <<'YAML'
# pnpm settings
strictPeerDependencies: false
YAML
}

write_pnpm_quoted() {
  cat > "$(pnpm_config_path)" <<'YAML'
# pnpm settings
strictPeerDependencies: false
httpProxy: 'http://127.0.0.1:7890'
httpsProxy: "http://127.0.0.1:7890" # inline comment
noProxy: "localhost,127.0.0.1,::1"
YAML
}

write_ssh_on() {
  cat > "$(ssh_config_path)" <<'SSH'
Host example.com
    HostName example.com
    User git

Host github.com
    HostName ssh.github.com
    User git
    Port 443
    ProxyCommand ncat --proxy 127.0.0.1:7890 --proxy-type http %h %p

Host internal.example
    HostName 10.0.0.1
SSH
}

write_ssh_off() {
  cat > "$(ssh_config_path)" <<'SSH'
Host example.com
    HostName example.com
    User git

Host github.com
    HostName ssh.github.com
    User git
    Port 443
    ProxyCommand none

Host internal.example
    HostName 10.0.0.1
SSH
}

write_ssh_other_host_proxy_only() {
  cat > "$(ssh_config_path)" <<'SSH'
Host example.com
    HostName example.com
    ProxyCommand ncat --proxy 127.0.0.1:7890 --proxy-type http %h %p

Host github.com
    HostName ssh.github.com
    User git
    Port 443
SSH
}

# No github.com block at all: ``on`` has to append one.
write_ssh_without_github() {
  cat > "$(ssh_config_path)" <<'SSH'
Host example.com
    HostName example.com
    User git

Host internal.example
    HostName 10.0.0.1
SSH
}

write_docker_on() {
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
        }
    }
}
JSON
  chmod 600 "$(docker_config_path)"
}

write_docker_off() {
  mkdir -p "$(dirname "$(docker_config_path)")"
  cat > "$(docker_config_path)" <<'JSON'
{
    "auths": {
        "https://index.docker.io/v1/": {
            "auth": "Zml4dHVyZQ=="
        }
    }
}
JSON
  chmod 600 "$(docker_config_path)"
}

write_all_carriers_on() {
  write_niri_on
  write_shell_on
  write_npm_on
  write_pnpm_on
  write_ssh_on
  write_docker_on
}

write_all_carriers_off() {
  write_niri_off
  write_shell_off
  write_npm_off
  write_pnpm_off
  write_ssh_off
  write_docker_off
}

proxy_state_root() { printf '%s\n' "$XDG_STATE_HOME/proxy-switcher"; }
proxy_manifest_path() { printf '%s\n' "$(proxy_state_root)/manifest.json"; }
proxy_snapshot_count() {
  local dir
  dir="$(proxy_state_root)/snapshots"
  if [[ ! -d "$dir" ]]; then
    printf '0\n'
    return
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l
}

write_proxy_config() {
  mkdir -p "$XDG_CONFIG_HOME/proxy-switcher"
  cat > "$XDG_CONFIG_HOME/proxy-switcher/config.toml"
}

# A stable fingerprint of a directory tree: paths, types, modes, sizes,
# mtimes and contents. Used to prove status performed no writes.
snapshot_tree() {
  local root
  for root in "$@"; do
    if [[ ! -e "$root" ]]; then
      printf 'absent %s\n' "$root"
      continue
    fi
    find "$root" -printf '%y %m %s %T@ %p\n'
    find "$root" -type f -print0 | sort -z | xargs -0 -r sha256sum
  done
}

# Assert that a human-readable carrier row starts with the expected state.
assert_carrier_state() {
  local name="$1" state="$2" line
  line="$(printf '%s\n' "$output" | grep -E "^${name}[[:space:]]" | head -n1)"
  if [[ -z "$line" ]]; then
    printf 'no status row for carrier: %s\n' "$name" >&2
    return 1
  fi
  if [[ ! "$line" =~ ^${name}[[:space:]]+${state}([[:space:]]|$) ]]; then
    printf 'carrier %s: expected state %s, got: %s\n' "$name" "$state" "$line" >&2
    return 1
  fi
}

assert_carrier_tools() {
  local name="$1" needle="$2" line
  line="$(printf '%s\n' "$output" | grep -E "^${name}[[:space:]]" | head -n1)"
  if [[ "$line" != *"$needle"* ]]; then
    printf 'carrier %s: expected tools to mention %q, got: %s\n' \
      "$name" "$needle" "$line" >&2
    return 1
  fi
}
