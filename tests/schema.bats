#!/usr/bin/env bats
#
# The `--json` contract, pinned as data.
#
# `proxy_common.JSON_SCHEMA` promises that a field is never added, removed or
# renamed without the number moving with it. That promise used to rest on a
# reader noticing, and a forgotten bump left every test green. These snapshots
# make a field change fail the suite, and make the number itself part of what
# the suite checks — so bumping one without the other is caught in both
# directions.
#
# When a field genuinely changes: update the snapshot here AND bump both
# `JSON_SCHEMA` in proxy_common.py and `SCHEMA_VERSION` below.

load "${BATS_TEST_DIRNAME}/helpers/fixture.bash"

# Must equal `JSON_SCHEMA` in libexec/proxy_common.py.
SCHEMA_VERSION=2

setup() {
  fixture_init
}

# The declared schema number, read from the single source of truth.
declared_schema() {
  sed -n 's/^JSON_SCHEMA = \([0-9]\+\).*/\1/p' "$REPO_ROOT/libexec/proxy_common.py"
}

status_document() {
  write_all_carriers_off
  bash -c '"$PROXYSW_BIN" status --json 2>/dev/null'
}

plan_document() {
  write_all_carriers_off
  bash -c '"$PROXYSW_BIN" on --dry-run --json 2>/dev/null'
}

env_document() {
  write_all_carriers_off
  SHELL=/bin/bash bash -c '"$PROXYSW_BIN" env --json 2>/dev/null'
}

@test "the declared schema number and this file's snapshot agree" {
  # Both directions: a bump without a snapshot update, or a snapshot edit
  # without a bump, fails here rather than in a downstream widget.
  [ -n "$(declared_schema)" ]
  [ "$(declared_schema)" -eq "$SCHEMA_VERSION" ]
}

@test "the status document carries exactly the snapshotted schema" {
  local output
  output="$(status_document)"

  [ "$(printf '%s\n' "$output" | jq -r .schema)" -eq "$SCHEMA_VERSION" ]

  # Top-level fields.
  [ "$(printf '%s\n' "$output" | jq -r 'keys | join(",")')" \
    = "carriers,endpoint,no_proxy,schema" ]

  # Per-carrier fields. Union across every row so a field that only one
  # carrier carries still has to be declared here.
  [ "$(printf '%s\n' "$output" | jq -r \
    '[.carriers[] | keys] | add | unique | join(",")')" \
    = "name,note,path,pending_reload,skipped,state,tools" ]
}

@test "the switch document carries exactly the snapshotted schema" {
  local output
  output="$(plan_document)"

  [ "$(printf '%s\n' "$output" | jq -r .schema)" -eq "$SCHEMA_VERSION" ]

  [ "$(printf '%s\n' "$output" | jq -r 'keys | join(",")')" \
    = "action,carriers,conflicts,dry_run,endpoint,failures,no_proxy,schema,skipped,unstarted" ]

  [ "$(printf '%s\n' "$output" | jq -r \
    '[.carriers[] | keys] | add | unique | join(",")')" \
    = "action,changed,exists,name,path,pending_reload,state,warning,written" ]
}

@test "the env document carries exactly the snapshotted schema" {
  local output
  output="$(env_document)"

  [ "$(printf '%s\n' "$output" | jq -r .schema)" -eq "$SCHEMA_VERSION" ]

  [ "$(printf '%s\n' "$output" | jq -r 'keys | join(",")')" \
    = "endpoint,exports,no_proxy,schema,state,unsets" ]
}

@test "an executing switch reports the same schema as a dry run" {
  # A consumer must not have to branch on which mode produced the document.
  write_all_carriers_off

  local dry run
  dry="$(plan_document)"
  run="$(bash -c '"$PROXYSW_BIN" on --json 2>/dev/null')"

  [ "$(printf '%s\n' "$dry" | jq -r .schema)" \
    = "$(printf '%s\n' "$run" | jq -r .schema)" ]
  [ "$(printf '%s\n' "$dry" | jq -r 'keys | join(",")')" \
    = "$(printf '%s\n' "$run" | jq -r 'keys | join(",")')" ]
}
