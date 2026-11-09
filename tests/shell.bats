#!/usr/bin/env bats
#
# Black-box tests for switching the shell rc carrier on and off. The only seam
# is the CLI: real files in a throwaway HOME, a stub niri, and assertions on
# exit code, output, the manifest and the bytes left on disk.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

setup() {
  fixture_init
}

write_shell_with_snippet_in_the_middle() {
  cat > "$(shell_rc_path)" <<'SH'
export BEFORE_MARKER=1
# keep this comment

# >>> proxy-switcher >>>
export http_proxy="http://127.0.0.1:7000"
# <<< proxy-switcher <<<

# after marker
export AFTER_MARKER=2
SH
}

@test "on writes six exports and leaves everything outside the snippet byte-identical" {
  write_shell_with_snippet_in_the_middle
  awk '/^# >>> proxy-switcher >>>$/{exit} {print}' \
    "$(shell_rc_path)" > "$BATS_TEST_TMPDIR/prefix.before"
  awk 'seen {print} /^# <<< proxy-switcher <<<$/{seen=1}' \
    "$(shell_rc_path)" > "$BATS_TEST_TMPDIR/suffix.before"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  for key in $(proxy_keys); do
    grep -qE "^export ${key}=\"" "$(shell_rc_path)"
    [ "$(grep -cE "^export ${key}=" "$(shell_rc_path)")" -eq 1 ]
  done
  grep -qF 'http://127.0.0.1:7890' "$(shell_rc_path)"
  ! grep -q 'all_proxy' "$(shell_rc_path)"

  awk '/^# >>> proxy-switcher >>>$/{exit} {print}' \
    "$(shell_rc_path)" > "$BATS_TEST_TMPDIR/prefix.after"
  awk 'seen {print} /^# <<< proxy-switcher <<<$/{seen=1}' \
    "$(shell_rc_path)" > "$BATS_TEST_TMPDIR/suffix.after"
  cmp "$BATS_TEST_TMPDIR/prefix.before" "$BATS_TEST_TMPDIR/prefix.after"
  cmp "$BATS_TEST_TMPDIR/suffix.before" "$BATS_TEST_TMPDIR/suffix.after"

  grep -qF 'export BEFORE_MARKER=1' "$(shell_rc_path)"
  grep -qF '# keep this comment' "$(shell_rc_path)"
  grep -qF '# after marker' "$(shell_rc_path)"
  grep -qF 'export AFTER_MARKER=2' "$(shell_rc_path)"

  run_proxysw status
  [ "$status" -eq 0 ]
  assert_carrier_state shell on
}

@test "on appends the snippet when the rc file has none and keeps the original bytes as a prefix" {
  write_shell_raw_exports
  cp "$(shell_rc_path)" "$BATS_TEST_TMPDIR/rc.before"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ "$(grep -c '^# >>> proxy-switcher >>>$' "$(shell_rc_path)")" -eq 1 ]
  [ "$(grep -c '^# <<< proxy-switcher <<<$' "$(shell_rc_path)")" -eq 1 ]
  cmp -n "$(stat -c%s "$BATS_TEST_TMPDIR/rc.before")" \
    "$BATS_TEST_TMPDIR/rc.before" "$(shell_rc_path)"
  for key in $(proxy_keys); do
    grep -qE "^export ${key}=\"" "$(shell_rc_path)"
  done
  grep -qx 'export NODE_USE_ENV_PROXY=1' "$(shell_rc_path)"
}

@test "off writes six explicit unsets and keeps the snippet" {
  write_shell_on

  run_proxysw off shell

  [ "$status" -eq 0 ]
  [ "$(grep -c '^# >>> proxy-switcher >>>$' "$(shell_rc_path)")" -eq 1 ]
  [ "$(grep -c '^# <<< proxy-switcher <<<$' "$(shell_rc_path)")" -eq 1 ]
  for key in $(proxy_keys); do
    [ "$(grep -cE "^unset ${key}$" "$(shell_rc_path)")" -eq 1 ]
  done
  ! grep -q 'http://127.0.0.1:7890' "$(shell_rc_path)"
  ! grep -qE '^export (http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY)=' \
    "$(shell_rc_path)"
  ! grep -qE '^unset NODE_USE_ENV_PROXY$' "$(shell_rc_path)"

  run_proxysw status
  [ "$status" -eq 0 ]
  assert_carrier_state shell off
}

@test "repeated on is idempotent and creates no extra snapshot" {
  write_shell_raw_exports
  run_proxysw on shell
  [ "$status" -eq 0 ]
  local first_hash first_snapshots
  first_hash="$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)"
  first_snapshots="$(proxy_snapshot_count)"
  [ "$first_snapshots" -eq 1 ]

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)" = "$first_hash" ]
  [ "$(proxy_snapshot_count)" -eq "$first_snapshots" ]
  [ "$(grep -c '^# >>> proxy-switcher >>>$' "$(shell_rc_path)")" -eq 1 ]
}

@test "repeated off is idempotent and creates no extra snapshot" {
  write_shell_on
  run_proxysw off shell
  [ "$status" -eq 0 ]
  local first_hash first_snapshots
  first_hash="$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)"
  first_snapshots="$(proxy_snapshot_count)"

  run_proxysw off shell

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)" = "$first_hash" ]
  [ "$(proxy_snapshot_count)" -eq "$first_snapshots" ]
}

@test "on creates a missing rc file and says so" {
  rm -f "$(shell_rc_path)"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ -f "$(shell_rc_path)" ]
  [[ "$output" == *"created"* ]]
  [[ "$output" == *"$(shell_rc_path)"* ]]
  for key in $(proxy_keys); do
    grep -qE "^export ${key}=\"" "$(shell_rc_path)"
  done

  run_proxysw status
  [ "$status" -eq 0 ]
  assert_carrier_state shell on
}

@test "the manifest records a missing original rc file as absent" {
  rm -f "$(shell_rc_path)"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ "$(jq -r '.carriers.shell.original_existed' "$(proxy_manifest_path)")" = "false" ]
  [ "$(jq -r '.carriers.shell.original_hash' "$(proxy_manifest_path)")" = "null" ]
  [ "$(jq -r '.carriers.shell.snapshot' "$(proxy_manifest_path)")" = "null" ]
}

@test "off refuses to overwrite an externally modified rc file with exit code 1" {
  write_shell_on
  run_proxysw on shell
  [ "$status" -eq 0 ]
  printf '\n# edited by hand\n' >> "$(shell_rc_path)"
  local before
  before="$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)"

  run_proxysw off shell

  [ "$status" -eq 1 ]
  [[ "$output" == *"$(shell_rc_path)"* ]]
  [[ "$output" == *"--force"* ]]
  [ "$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)" = "$before" ]
}

@test "--force completes a switch over an externally modified rc file" {
  write_shell_on
  run_proxysw on shell
  [ "$status" -eq 0 ]
  printf '\n# edited by hand\n' >> "$(shell_rc_path)"

  run_proxysw off shell --force

  [ "$status" -eq 0 ]
  grep -qF '# edited by hand' "$(shell_rc_path)"
  for key in $(proxy_keys); do
    grep -qE "^unset ${key}$" "$(shell_rc_path)"
  done
}

@test "an interactive shell ends up without proxy variables when niri is on and shell is off" {
  write_niri_plain
  run_proxysw on niri
  [ "$status" -eq 0 ]
  run_proxysw on shell
  [ "$status" -eq 0 ]
  run_proxysw off shell
  [ "$status" -eq 0 ]

  local leftover
  leftover="$(env -i HOME="$HOME" PATH="$PATH" \
    http_proxy="http://127.0.0.1:7890" \
    https_proxy="http://127.0.0.1:7890" \
    HTTP_PROXY="http://127.0.0.1:7890" \
    HTTPS_PROXY="http://127.0.0.1:7890" \
    no_proxy="localhost,127.0.0.1,::1" \
    NO_PROXY="localhost,127.0.0.1,::1" \
    "$(command -v bash)" --noprofile --norc -c '
      source "$HOME/.zshrc"
      for name in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
        if printenv "$name" >/dev/null; then
          printf "%s=%s\n" "$name" "$(printenv "$name")"
        fi
      done
    ')"

  [ -z "$leftover" ]
}

@test "an interactive shell still sees niri's values when the shell carrier has not run" {
  write_niri_plain
  run_proxysw on niri
  [ "$status" -eq 0 ]

  local leftover
  leftover="$(env -i HOME="$HOME" PATH="$PATH" \
    http_proxy="http://127.0.0.1:7890" \
    https_proxy="http://127.0.0.1:7890" \
    "$(command -v bash)" --noprofile --norc -c '
      source "$HOME/.zshrc"
      printenv http_proxy
    ')"

  [ "$leftover" = "http://127.0.0.1:7890" ]
}

@test "on uses the endpoint and no_proxy from the XDG config" {
  write_shell_raw_exports
  write_proxy_config <<'TOML'
endpoint = "http://127.0.0.1:7895"
no_proxy = "localhost,example.test"
TOML

  run_proxysw on shell

  [ "$status" -eq 0 ]
  grep -qF 'export http_proxy="http://127.0.0.1:7895"' "$(shell_rc_path)"
  grep -qF 'export HTTPS_PROXY="http://127.0.0.1:7895"' "$(shell_rc_path)"
  grep -qF 'export NO_PROXY="localhost,example.test"' "$(shell_rc_path)"
}

@test "writing preserves the rc file permissions" {
  write_shell_raw_exports
  chmod 600 "$(shell_rc_path)"

  run_proxysw on shell
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$(shell_rc_path)")" = "600" ]

  run_proxysw off shell
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$(shell_rc_path)")" = "600" ]
}

@test "a file that already holds the same snippet is left byte-identical" {
  write_shell_on
  local before
  before="$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(shell_rc_path)" | cut -d' ' -f1)" = "$before" ]
}

@test "the shell carrier uses ~/.bashrc when SHELL is bash" {
  SHELL=/bin/bash
  export SHELL
  rm -f "$HOME/.bashrc" "$HOME/.zshrc"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ -f "$HOME/.bashrc" ]
  [ ! -e "$HOME/.zshrc" ]
  for key in $(proxy_keys); do
    grep -qE "^export ${key}=\"" "$HOME/.bashrc"
  done

  run_proxysw status
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.bashrc"* ]]
}

@test "the shell carrier falls back to ~/.zshrc for other shells" {
  SHELL=/bin/fish
  export SHELL
  rm -f "$HOME/.bashrc" "$HOME/.zshrc"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ -f "$HOME/.zshrc" ]
  [ ! -e "$HOME/.bashrc" ]
}

@test "the shell carrier falls back to ~/.zshrc when SHELL is unset" {
  unset SHELL
  rm -f "$HOME/.bashrc" "$HOME/.zshrc"

  run_proxysw on shell

  [ "$status" -eq 0 ]
  [ -f "$HOME/.zshrc" ]
  [ ! -e "$HOME/.bashrc" ]
}
