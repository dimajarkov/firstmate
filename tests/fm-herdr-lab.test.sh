#!/usr/bin/env bash
# Public-interface behavior tests for bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_SESSIONS="$TMP_ROOT/sessions.json"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
HELPER="$ROOT/bin/fm-herdr-lab.sh"
mkdir -p "$TMP_ROOT"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
last=
previous=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
selector=$last
sessions=$FM_FAKE_HERDR_SESSIONS

update_sessions() {
  local filter=$1 temporary
  temporary="$sessions.tmp.$$"
  jq "$filter" "$sessions" > "$temporary"
  mv "$temporary" "$sessions"
}

case "$1 ${2:-}" in
  "session list")
    jq -c '{sessions:.sessions}' "$sessions"
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    jq --arg name "$selector" '
      .sessions |= (
        map(select(.name != $name))
        + [{name:$name,default:false,running:true,socket_path:("/tmp/" + $name + ".sock"),pid:9001}]
      )
    ' "$sessions" > "$sessions.tmp.$$"
    mv "$sessions.tmp.$$" "$sessions"
    ;;
  "status --json")
    jq -c --arg name "$selector" '{server:{running:([.sessions[]? | select(.name == $name and .running == true)] | length == 1)}}' "$sessions"
    ;;
  "session stop")
    [ "$3" = "$selector" ] || exit 91
    update_sessions '(.sessions[] | select(.name == "'"$selector"'") | .running) = false'
    ;;
  "session delete")
    [ "$3" = "$selector" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    update_sessions '.sessions |= map(select(.name != "'"$selector"'"))'
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

reset_world() { # <sessions-json>
  rm -rf "$TRIPWIRES"
  mkdir -p "$TRIPWIRES"
  printf '%s\n' "$1" | jq -cS . > "$FAKE_SESSIONS"
  : > "$FAKE_LOG"
}

run_helper() { # <parent-session> <helper arguments...>
  local parent=$1
  shift
  env \
    -u HERDR_ENV \
    -u HERDR_PANE_ID \
    -u HERDR_TAB_ID \
    -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH \
    -u HERDR_SESSION \
    PATH="$FAKEBIN:$PATH" \
    FM_HERDR_LAB_PARENT_SESSION="$parent" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    FM_FAKE_HERDR_SESSIONS="$FAKE_SESSIONS" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    "$HELPER" "$@"
}

run_helper_without_parent() { # <helper arguments...>
  env \
    -u FM_HERDR_LAB_PARENT_SESSION \
    -u HERDR_ENV \
    -u HERDR_PANE_ID \
    -u HERDR_TAB_ID \
    -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH \
    -u HERDR_SESSION \
    PATH="$FAKEBIN:$PATH" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    FM_FAKE_HERDR_SESSIONS="$FAKE_SESSIONS" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    "$HELPER" "$@"
}

base_named_sessions() {
  printf '%s\n' '{"sessions":[
    {"name":"default","default":true,"running":false,"socket_path":"/tmp/default.sock","pid":null},
    {"name":"arena","default":false,"running":true,"socket_path":"/tmp/arena.sock","pid":101}
  ]}'
}

canonical_sessions_without() { # <session>
  jq -cS --arg name "$1" '.sessions | map(select(.name != $name))' "$FAKE_SESSIONS"
}

tripwire_for() { # <session>
  printf '%s/%s.parent-state.json' "$TRIPWIRES" "$1"
}

test_names_help_and_missing_parent_fail_closed() {
  local status=0 generated name="fm-lab-missing-parent-$$"
  generated=$("$HELPER" name fm-autodetect-smoke-concurrency-h3)
  case "$generated" in fm-lab-*) : ;; *) fail "generated name lacks the lab prefix: $generated" ;; esac
  [ "${#generated}" -le 40 ] || fail "generated lab name is too long: $generated"
  "$HELPER" --help | grep -F 'FM_HERDR_LAB_PARENT_SESSION=<parent>' >/dev/null \
    || fail "public help omits the exact parent-session input"

  reset_world "$(base_named_sessions)"
  run_helper_without_parent provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing protected-parent input must refuse provision"
  [ ! -s "$FAKE_LOG" ] || fail "missing parent identity reached Herdr"
  assert_absent "$(tripwire_for "$name")" "missing parent identity created a tripwire"
  pass "fm-herdr-lab: public naming/help work and missing parent identity refuses before Herdr"
}

test_running_named_parent_with_stopped_default() {
  local name="fm-lab-named-parent-$$" before after
  reset_world "$(base_named_sessions)"
  before=$(canonical_sessions_without "$name")
  run_helper arena provision "$name" || fail "named parent with stopped default did not provision"
  jq -e --arg name "$name" '.sessions[] | select(.name == $name and .running == true)' "$FAKE_SESSIONS" >/dev/null \
    || fail "named-parent provision did not start the task lab"
  assert_present "$(tripwire_for "$name")" "named-parent provision did not record its parent tripwire"
  run_helper arena run "$name" workspace list >/dev/null || fail "named-parent run failed"
  run_helper arena teardown "$name" || fail "named-parent teardown failed"
  after=$(canonical_sessions_without "$name")
  [ "$before" = "$after" ] || fail "named-parent lifecycle changed the protected or unrelated sessions"
  assert_absent "$(tripwire_for "$name")" "named-parent teardown retained its tripwire"
  pass "fm-herdr-lab: running named parent works while default remains stopped"
}

test_running_default_parent_compatibility() {
  local name="fm-lab-default-parent-$$" before after
  reset_world '{"sessions":[
    {"name":"default","default":true,"running":true,"socket_path":"/tmp/default.sock","pid":202},
    {"name":"unrelated","default":false,"running":true,"socket_path":"/tmp/unrelated.sock","pid":303}
  ]}'
  before=$(canonical_sessions_without "$name")
  run_helper default provision "$name" || fail "running default parent compatibility provision failed"
  run_helper default teardown "$name" || fail "running default parent compatibility teardown failed"
  after=$(canonical_sessions_without "$name")
  [ "$before" = "$after" ] || fail "default-parent lifecycle changed the protected or unrelated sessions"
  pass "fm-herdr-lab: genuine running default parent remains safely supported"
}

test_multiple_running_sessions_and_complete_cleanup() {
  local name="fm-lab-multiple-$$" before after line stop_line delete_line
  reset_world '{"sessions":[
    {"name":"default","default":true,"running":false,"socket_path":"/tmp/default.sock","pid":null},
    {"name":"arena","default":false,"running":true,"socket_path":"/tmp/arena.sock","pid":101},
    {"name":"sibling","default":false,"running":true,"socket_path":"/tmp/sibling.sock","pid":404},
    {"name":"resting","default":false,"running":false,"socket_path":"/tmp/resting.sock","pid":null}
  ]}'
  before=$(canonical_sessions_without "$name")
  run_helper arena provision "$name" || fail "explicit parent was treated as ambiguous with multiple running sessions"
  run_helper arena stop "$name" >/dev/null || fail "guarded stop failed"
  run_helper arena provision "$name" || fail "guarded re-provision failed"
  : > "$FAKE_LOG"
  run_helper arena teardown "$name" || fail "complete task-lab teardown failed"
  after=$(canonical_sessions_without "$name")
  [ "$before" = "$after" ] || fail "complete cleanup changed an unrelated session"
  jq -e --arg name "$name" '[.sessions[] | select(.name == $name)] | length == 0' "$FAKE_SESSIONS" >/dev/null \
    || fail "complete cleanup retained the task lab"
  assert_absent "$(tripwire_for "$name")" "complete cleanup retained task ownership state"

  while IFS= read -r line; do
    case "$line" in
      *"--session arena"|*"--session $name") : ;;
      *) fail "Herdr call was not explicitly scoped to the parent or task lab: $line" ;;
    esac
  done < "$FAKE_LOG"
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  [ -n "$stop_line" ] && [ -n "$delete_line" ] || fail "teardown omitted explicit task-lab stop/delete"
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session arena" >/dev/null \
    || fail "task stop lacked an immediate protected-parent and target re-check"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session arena" >/dev/null \
    || fail "task delete lacked an immediate protected-parent and target re-check"
  pass "fm-herdr-lab: explicit parent disambiguates multiple sessions and cleanup changes nothing else"
}

test_missing_ambiguous_and_changed_parent_refuse() {
  local name="fm-lab-parent-refusal-$$" status=0
  reset_world '{"sessions":[{"name":"default","default":true,"running":false,"socket_path":"/tmp/default.sock","pid":null}]}'
  run_helper arena provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing named parent must refuse provision"
  assert_absent "$(tripwire_for "$name")" "missing named parent created a tripwire"
  assert_no_grep '^server ' "$FAKE_LOG" "missing named parent started a lab server"

  reset_world '{"sessions":[
    {"name":"arena","default":false,"running":true,"socket_path":"/tmp/arena-a.sock","pid":1},
    {"name":"arena","default":false,"running":true,"socket_path":"/tmp/arena-b.sock","pid":2}
  ]}'
  status=0
  run_helper arena provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "duplicate parent identity must refuse provision"
  assert_no_grep '^server ' "$FAKE_LOG" "ambiguous parent started a lab server"

  reset_world "$(base_named_sessions)"
  run_helper arena provision "$name" || fail "parent-change fixture did not provision"
  jq '(.sessions[] | select(.name == "arena") | .socket_path) = "/tmp/arena-changed.sock"' \
    "$FAKE_SESSIONS" > "$FAKE_SESSIONS.tmp"
  mv "$FAKE_SESSIONS.tmp" "$FAKE_SESSIONS"
  : > "$FAKE_LOG"
  status=0
  run_helper arena stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed protected-parent state must refuse stop"
  assert_no_grep '^session stop ' "$FAKE_LOG" "changed parent state reached task stop"
  assert_no_grep '^session delete ' "$FAKE_LOG" "changed parent state reached task delete"
  assert_present "$(tripwire_for "$name")" "changed-parent refusal discarded its evidence"

  jq '(.sessions[] | select(.name == "arena") | .socket_path) = "/tmp/arena.sock"' \
    "$FAKE_SESSIONS" > "$FAKE_SESSIONS.tmp"
  mv "$FAKE_SESSIONS.tmp" "$FAKE_SESSIONS"
  run_helper arena teardown "$name" || fail "cleanup failed after restoring the protected parent"
  pass "fm-herdr-lab: missing, ambiguous, or changed protected parent refuses destructive work"
}

test_changed_supplied_parent_and_protected_target_refuse() {
  local name="fm-lab-binding-change-$$" protected="fm-lab-parent-$$" status=0
  reset_world '{"sessions":[
    {"name":"arena","default":false,"running":true,"socket_path":"/tmp/arena.sock","pid":101},
    {"name":"sibling","default":false,"running":true,"socket_path":"/tmp/sibling.sock","pid":202}
  ]}'
  run_helper arena provision "$name" || fail "binding-change fixture did not provision"
  : > "$FAKE_LOG"
  run_helper sibling teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed supplied parent must refuse teardown"
  [ ! -s "$FAKE_LOG" ] || fail "changed supplied parent queried or mutated Herdr before refusing"

  jq --arg name "$name" '(.sessions[] | select(.name == $name) | .socket_path) = "/tmp/arena.sock"' \
    "$FAKE_SESSIONS" > "$FAKE_SESSIONS.tmp"
  mv "$FAKE_SESSIONS.tmp" "$FAKE_SESSIONS"
  : > "$FAKE_LOG"
  status=0
  run_helper arena stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "task identity resolving to the protected-parent socket must refuse stop"
  assert_no_grep '^session stop ' "$FAKE_LOG" "protected-parent socket alias reached task stop"
  jq --arg name "$name" '(.sessions[] | select(.name == $name) | .socket_path) = ("/tmp/" + $name + ".sock")' \
    "$FAKE_SESSIONS" > "$FAKE_SESSIONS.tmp"
  mv "$FAKE_SESSIONS.tmp" "$FAKE_SESSIONS"
  run_helper arena teardown "$name" || fail "binding-change fixture cleanup failed"

  reset_world "$(jq -nc --arg parent "$protected" '{sessions:[{name:$parent,default:false,running:true,socket_path:("/tmp/" + $parent + ".sock"),pid:303}]}')"
  status=0
  run_helper "$protected" provision "$protected" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "attempt to target the protected parent as a lab must refuse"
  [ ! -s "$FAKE_LOG" ] || fail "protected-parent target attempt reached Herdr"
  pass "fm-herdr-lab: changed binding and protected-parent targeting refuse before lifecycle calls"
}

test_runtime_identity_must_match_explicit_parent() {
  local name="fm-lab-runtime-parent-$$" status=0
  reset_world "$(base_named_sessions)"
  env \
    HERDR_ENV=1 \
    HERDR_SESSION=sibling \
    HERDR_SOCKET_PATH=/tmp/sibling.sock \
    PATH="$FAKEBIN:$PATH" \
    FM_HERDR_LAB_PARENT_SESSION=arena \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    FM_FAKE_HERDR_SESSIONS="$FAKE_SESSIONS" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    "$HELPER" provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "Herdr runtime identity mismatch must refuse provision"
  assert_no_grep '^server ' "$FAKE_LOG" "runtime parent mismatch started a lab server"
  assert_absent "$(tripwire_for "$name")" "runtime parent mismatch created a tripwire"
  pass "fm-herdr-lab: explicit parent must agree with stronger Herdr runtime identity"
}

test_run_guards_and_parent_precheck() {
  local name="fm-lab-run-guards-$$" status=0
  reset_world "$(base_named_sessions)"
  run_helper arena provision "$name" || fail "run-guard fixture did not provision"

  : > "$FAKE_LOG"
  run_helper arena run "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "run must forbid server lifecycle operations"
  status=0
  run_helper arena run "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "run must forbid session lifecycle operations"
  status=0
  run_helper arena run "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "run must forbid caller-supplied session selectors"
  status=0
  run_helper arena run "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "run must forbid leading global options"
  [ ! -s "$FAKE_LOG" ] || fail "forbidden run command reached Herdr"

  jq '(.sessions[] | select(.name == "arena") | .socket_path) = "/changed/before-command.sock"' \
    "$FAKE_SESSIONS" > "$FAKE_SESSIONS.tmp"
  mv "$FAKE_SESSIONS.tmp" "$FAKE_SESSIONS"
  : > "$FAKE_LOG"
  status=0
  run_helper arena run "$name" workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "run must refuse a protected parent changed before the task call"
  assert_no_grep '^workspace list ' "$FAKE_LOG" "changed parent state reached the task command"
  assert_present "$(tripwire_for "$name")" "run pre-check failure discarded the tripwire"
  jq '(.sessions[] | select(.name == "arena") | .socket_path) = "/tmp/arena.sock"' \
    "$FAKE_SESSIONS" > "$FAKE_SESSIONS.tmp"
  mv "$FAKE_SESSIONS.tmp" "$FAKE_SESSIONS"
  run_helper arena teardown "$name" || fail "run-guard fixture cleanup failed"
  pass "fm-herdr-lab: run rejects unsafe calls and re-checks the protected parent first"
}

test_failed_delete_retains_ownership() {
  local name="fm-lab-delete-failure-$$" status=0
  reset_world "$(base_named_sessions)"
  run_helper arena provision "$name" || fail "delete-failure fixture did not provision"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_helper arena teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed task-lab delete must fail teardown"
  assert_present "$(tripwire_for "$name")" "failed delete discarded task ownership"
  jq -e --arg name "$name" '.sessions[] | select(.name == $name)' "$FAKE_SESSIONS" >/dev/null \
    || fail "failed delete unexpectedly removed the task lab"
  run_helper arena teardown "$name" || fail "delete retry did not clean up the task lab"
  pass "fm-herdr-lab: failed deletion retains ownership until confirmed cleanup"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-timeout-$$" status=0
  reset_world "$(base_named_sessions)"
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_helper arena provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$(tripwire_for "$name")" "timed-out provision discarded task ownership"
  run_helper arena teardown "$name" || fail "teardown after timed-out provision failed"
  "$REAL_SLEEP" 1.1
  jq -e --arg name "$name" '[.sessions[] | select(.name == $name)] | length == 0' "$FAKE_SESSIONS" >/dev/null \
    || fail "timed-out provision left a late-starting task lab"
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before cleanup"
}

test_names_help_and_missing_parent_fail_closed
test_running_named_parent_with_stopped_default
test_running_default_parent_compatibility
test_multiple_running_sessions_and_complete_cleanup
test_missing_ambiguous_and_changed_parent_refuse
test_changed_supplied_parent_and_protected_target_refuse
test_runtime_identity_must_match_explicit_parent
test_run_guards_and_parent_precheck
test_failed_delete_retains_ownership
test_timed_out_provision_cancels_late_launch
