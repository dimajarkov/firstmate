#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
printf '%s\n' true > "$FAKE_STATE/default-running"
printf '%s\n' true > "$FAKE_STATE/arena-running"
printf '%s\n' false > "$FAKE_STATE/scratch-running"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
last=
for arg in "$@"; do
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing trailing --session" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
default_running=$(cat "$state/default-running")
arena_running=$(cat "$state/arena-running")
scratch_running=$(cat "$state/scratch-running")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    failures=0
    [ ! -f "$state/list-failures" ] || failures=$(cat "$state/list-failures")
    if [ "$failures" -gt 0 ]; then
      printf '%s\n' "$((failures - 1))" > "$state/list-failures"
      exit 94
    fi
    present=true
    running=false
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      present=false
    elif [ "$lab_state" = running ]; then
      running=true
    fi
    jq -nc \
      --arg default_socket "$default_socket" \
      --arg name "$session" \
      --argjson default_running "$default_running" \
      --argjson arena_running "$arena_running" \
      --argjson scratch_running "$scratch_running" \
      --argjson present "$present" \
      --argjson running "$running" \
      '{sessions:([
        {default:true,name:"default",running:$default_running,session_dir:"/Users/test/.config/herdr",socket_path:$default_socket},
        {default:false,name:"arena",running:$arena_running,session_dir:"/Users/test/.config/herdr/sessions/arena",socket_path:"/Users/test/.config/herdr/sessions/arena/herdr.sock"},
        {default:false,name:"scratch",running:$scratch_running,session_dir:"/Users/test/.config/herdr/sessions/scratch",socket_path:"/Users/test/.config/herdr/sessions/scratch/herdr.sock"}
      ] + if $present then [{default:false,name:$name,running:$running,session_dir:("/tmp/" + $name),socket_path:("/tmp/" + $name + ".sock")}] else [] end)}'
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    failures=0
    [ ! -f "$state/status-failures" ] || failures=$(cat "$state/status-failures")
    if [ "$failures" -gt 0 ]; then
      printf '%s\n' "$((failures - 1))" > "$state/status-failures"
      printf '%s\n' '{"server":{"running":false}}'
    elif [ "$lab_state" = running ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# shellcheck source=bin/fm-herdr-lab.sh
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated repeated digits near_limit long_one long_two
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name lab-safe-123 || fail "valid lab session name was refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "legacy lab name needed for cleanup was refused"

  generated=$(fm_herdr_lab_name arena-carlos-booking-context-loss-fix-20260723)
  [ "$generated" = lab-arena-carlos-booking-context-loss-fix-20260723 ] \
    || fail "reported task id did not produce its exact semantic lab name: $generated"
  repeated=$(fm_herdr_lab_name arena-carlos-booking-context-loss-fix-20260723)
  [ "$repeated" = "$generated" ] || fail "repeat generation changed the semantic session name"
  case "$generated" in fm-*) fail "generated lab name retained the fm- owner prefix" ;; esac
  case "$generated" in *-[0-9]*-[0-9]*) fail "generated lab name retained a pid/random suffix" ;; esac

  digits=$(fm_herdr_lab_name parser-v2-20260723)
  [ "$digits" = lab-parser-v2-20260723 ] || fail "meaningful task digits were stripped: $digits"
  near_limit=$(fm_herdr_lab_name "$(printf 'a%.0s' {1..55})-20260723")
  [ "${#near_limit}" -eq 50 ] || fail "64-character task id did not honor the deterministic Herdr session bound"
  case "$near_limit" in *-20260723) : ;; *) fail "near-limit task date digits were stripped: $near_limit" ;; esac

  long_one=$(fm_herdr_lab_name "$(printf 'z%.0s' {1..80})")
  long_two=$(fm_herdr_lab_name "$(printf 'z%.0s' {1..80})")
  [ "$long_one" = "$long_two" ] || fail "long-label shortening was not deterministic"
  [ "${#long_one}" -eq 50 ] || fail "long-label shortening exceeded its deterministic bound: $long_one"
  case "$long_one" in lab-??????????????-x-[a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z][a-z]-*) : ;; *) fail "long label lacks a nonnumeric deterministic disambiguator: $long_one" ;; esac
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  pass "fm-herdr-lab: exact semantic names preserve digits, repeat deterministically, and bound long labels without numeric nonces"
}

test_managed_herdr_worker_cannot_provision_a_nested_session() {
  local name="lab-arena-carlos-booking-context-loss-fix-20260723" status=0
  : > "$FAKE_LOG"
  HERDR_ENV=1 HERDR_PANE_ID=w28:p3 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  unset HERDR_ENV HERDR_PANE_ID
  expect_code 1 "$status" "a Herdr-managed worker must not provision a nested session"
  [ ! -s "$FAKE_LOG" ] || fail "nested-session guard reached the Herdr CLI"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "nested-session guard created an ownership tripwire"
  assert_absent "$FAKE_STATE/$name" \
    "nested-session guard created server state"
  pass "fm-herdr-lab: a Herdr-managed worker cannot provision the Arena-shaped nested session"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/Users/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_transient_preprovision_list_failure_retries() {
  local name="fm-lab-list-retry-$$" refused_name="fm-lab-list-refuse-$$" status=0 server_calls
  : > "$FAKE_LOG"
  printf '%s\n' 1 > "$FAKE_STATE/list-failures"
  run_with_fake fm_herdr_lab_provision "$name" || fail "one transient pre-provision list failure was not retried"
  [ "$(grep -c "^session list --json --session $name$" "$FAKE_LOG")" -ge 2 ] \
    || fail "pre-provision inventory did not retry its transient list failure"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after list retry failed"

  : > "$FAKE_LOG"
  printf '%s\n' 5 > "$FAKE_STATE/list-failures"
  run_with_fake fm_herdr_lab_provision "$refused_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an exhausted pre-provision list retry must fail closed"
  server_calls=$(grep -c "^server --session $refused_name$" "$FAKE_LOG" || true)
  [ "$server_calls" -eq 0 ] || fail "exhausted list retries reached server provisioning"
  assert_absent "$TRIPWIRES/$refused_name.fleet-state.json" \
    "exhausted list retries created an ownership tripwire"
  rm -f "$FAKE_STATE/list-failures"
  pass "fm-herdr-lab: transient pre-provision session-list failures retry and exhaustion fails closed"
}

test_stopped_default_and_named_sessions_are_protected() {
  local name="fm-lab-stopped-default-$$" before after
  printf '%s\n' false > "$FAKE_STATE/default-running"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "stopped default prevented named lab provisioning"
  before=$(cat "$TRIPWIRES/$name.fleet-state.json")
  assert_contains "$before" '"name":"default","running":false' \
    "tripwire did not retain the stopped default state"
  assert_contains "$before" '"name":"arena","running":true' \
    "tripwire did not retain the running arena session"
  assert_contains "$before" '"name":"scratch","running":false' \
    "tripwire did not retain the stopped scratch session"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown with a stopped default failed"
  after=$(run_with_fake fm_herdr_lab_session_list "$name" \
    | jq -cS --arg name "$name" '[.sessions[] | select(.name != $name)] | sort_by(.name)')
  [ "$before" = "$after" ] || fail "protected fleet changed around stopped-default lab lifecycle"
  printf '%s\n' true > "$FAKE_STATE/default-running"
  pass "fm-herdr-lab: a stopped default and unrelated named sessions remain byte-identical"
}

test_protected_fleet_change_blocks_owned_destruction() {
  local name="fm-lab-fleet-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "protected-fleet fixture provision failed"
  printf '%s\n' false > "$FAKE_STATE/arena-running"
  run_with_fake fm_herdr_lab_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed unrelated session must block owned-session stop"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "tripwire failure reached owned-session stop"
  status=0
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed unrelated session must block owned-session delete"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "tripwire failure reached owned-session teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "tripwire failure discarded ownership evidence"
  printf '%s\n' true > "$FAKE_STATE/arena-running"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown did not recover after protected fleet restoration"
  pass "fm-herdr-lab: protected-session drift blocks owned stop and delete"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_readiness_beyond_old_ten_second_boundary() {
  local name="fm-lab-late-ready-$$" status_calls
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  printf '%s\n' 55 > "$FAKE_STATE/status-failures"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision stopped at the old 50-poll/10-second boundary"
  status_calls=$(grep -c "^status --json --session $name$" "$FAKE_LOG")
  [ "$status_calls" -gt 50 ] || fail "late-readiness fixture did not cross the old 10-second poll boundary"
  rm -f "$FAKEBIN/sleep" "$FAKE_STATE/status-failures"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after late readiness failed"
  pass "fm-herdr-lab: readiness after the old 10-second boundary succeeds within the 60-second cap"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}

test_refuses_unsafe_names
test_managed_herdr_worker_cannot_provision_a_nested_session
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_transient_preprovision_list_failure_retries
test_stopped_default_and_named_sessions_are_protected
test_protected_fleet_change_blocks_owned_destruction
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_readiness_beyond_old_ten_second_boundary
test_timed_out_provision_cancels_late_launch
