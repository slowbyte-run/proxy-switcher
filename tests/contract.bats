#!/usr/bin/env bats
#
# Contract tests for the architecture rules in AGENTS.md that a human reviewer
# would otherwise have to catch by eye. Each one guards a mechanical rule:
# a fixed syntactic pattern, a file-location rule, or a registry that must stay
# in step with the directory.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

# Files under libexec/carriers that describe a carrier rather than the interface
# or the registry itself.
carrier_modules() {
  local path
  for path in "$REPO_ROOT"/libexec/carriers/*.py; do
    case "$(basename "$path")" in
      __init__.py | model.py) continue ;;
    esac
    basename "$path" .py
  done
}

@test "no carrier re-declares the six proxy variable names" {
  # The names, their value mapping, line endings and quoting live in
  # proxy_common.py. A carrier that spells a name out has started its own copy.
  local failures="" module
  for module in $(carrier_modules); do
    if grep -nE '"(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY|NODE_USE_ENV_PROXY)"' \
      "$REPO_ROOT/libexec/carriers/$module.py"; then
      failures="$failures $module"
    fi
  done
  if [ -n "$failures" ]; then
    printf 'carriers re-declaring proxy variables:%s\n' "$failures" >&2
    return 1
  fi
}

@test "proxy_common is the only module that names the proxy variables" {
  local other
  other="$(grep -rlE '^PROXY_VARS = \(|^NODE_FETCH_VAR = ' "$REPO_ROOT/libexec" \
    | grep -v 'proxy_common.py' || true)"
  [ -z "$other" ]
}

@test "the bash launcher parses no arguments" {
  # Argument parsing and usage text live in proxy_cli.py alone. A `case` on $1,
  # getopts, or a shift in bin/proxysw means a second parser has appeared.
  run grep -nE '(^|[^[:alnum:]_])(getopts|shift)|\bcase[[:space:]]+"?\$' \
    "$REPO_ROOT/bin/proxysw"
  [ "$status" -ne 0 ]
}

@test "the bash launcher stays a thin exec" {
  # Updated together with the symlink-resolving preamble; the point of the
  # bound is that the launcher never grows logic of its own.
  local lines
  lines="$(grep -cvE '^[[:space:]]*(#|$)' "$REPO_ROOT/bin/proxysw")"
  [ "$lines" -le 20 ]
  grep -qE '^exec .*proxy_cli\.py' "$REPO_ROOT/bin/proxysw"
}

@test "every carrier module is registered and every registration exists" {
  local registered listed missing unlisted
  registered="$(sed -n '/^MODULES = (/,/^)/p' "$REPO_ROOT/libexec/carriers/__init__.py" \
    | grep -oE '"[a-z]+"' | tr -d '"' | sort)"
  listed="$(carrier_modules | sort)"
  missing="$(comm -13 <(printf '%s\n' "$registered") <(printf '%s\n' "$listed"))"
  unlisted="$(comm -23 <(printf '%s\n' "$registered") <(printf '%s\n' "$listed"))"
  if [ -n "$missing" ]; then
    printf 'carrier modules missing from MODULES: %s\n' "$missing" >&2
    return 1
  fi
  if [ -n "$unlisted" ]; then
    printf 'MODULES names missing modules: %s\n' "$unlisted" >&2
    return 1
  fi
}

@test "every carrier module exports a CARRIER built from the shared model" {
  local module
  for module in $(carrier_modules); do
    grep -qE '^CARRIER = Carrier\(' "$REPO_ROOT/libexec/carriers/$module.py"
    grep -qE '^from \.model import Carrier$' "$REPO_ROOT/libexec/carriers/$module.py"
  done
}

@test "every bats file loads the shared fixture and calls fixture_init" {
  local file
  for file in "$REPO_ROOT"/tests/*.bats; do
    grep -q 'helpers/fixture.bash' "$file"
    grep -q 'fixture_init' "$file"
  done
}

@test "no bats test reaches for a real system path" {
  # Every carrier path comes from the fixture, so the only forbidden literal is
  # a real machine path. `~/.npmrc` inside fixture heredocs is fixture *content*
  # and is fine; `/etc/docker/daemon.json` is the docker carrier's real path and
  # a test must never assert against the live one.
  local files=()
  local file
  for file in "$REPO_ROOT"/tests/*.bats; do
    [ "$(basename "$file")" = "contract.bats" ] && continue
    files+=("$file")
  done

  run grep -nE '(/etc/docker|\$REAL_HOME|/etc/ssh)' "${files[@]}"
  [ "$status" -ne 0 ]
}

@test "no carrier module prints to stdout" {
  # Stdout belongs to the command's result. A carrier that calls bare `print`
  # corrupts the `--json` document whenever its branch fires (a missing
  # ~/.npmrc was enough to break `--dry-run --json`). Progress detail goes
  # through `context.info`, which writes to stderr.
  local module
  for module in $(carrier_modules); do
    run grep -nE '^[[:space:]]*print\(' "$REPO_ROOT/libexec/carriers/$module.py"
    [ "$status" -ne 0 ]
  done
}

@test "the CLI keeps exit codes 0, 1 and 2 as documented" {
  run_proxysw --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 success, 1 conflict/failure, 2 usage error"* ]]

  run_proxysw --nope
  [ "$status" -eq 2 ]

  write_proxy_config <<'TOML'
endpoint = "socks5://127.0.0.1:7890"
TOML
  run_proxysw status
  [ "$status" -eq 1 ]
}
