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
printf '%s\n' false > "$FAKE_STATE/default-running"
printf '%s\n' scratch > "$FAKE_STATE/primary-name"
printf '%s\n' true > "$FAKE_STATE/primary-running"
printf '%s\n' true > "$FAKE_STATE/primary-present"
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
primary_name=$(cat "$state/primary-name")
primary_running=$(cat "$state/primary-running")
primary_present=$(cat "$state/primary-present")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    running=false
    [ "$lab_state" = running ] && running=true
    jq -nc --arg socket "$default_socket" --argjson default_running "$default_running" \
      --arg primary "$primary_name" --argjson primary_running "$primary_running" \
      --argjson primary_present "$primary_present" --arg lab "$session" \
      --arg lab_state "$lab_state" --argjson lab_running "$running" '
        [{default:true,name:"default",running:$default_running,socket_path:$socket}]
        + (if $primary_present then [{default:false,name:$primary,running:$primary_running,socket_path:("/tmp/" + $primary + ".sock")}] else [] end)
        + (if ($lab_state == "absent" or $lab_state == "deleted") then [] else [{default:false,name:$lab,running:$lab_running,socket_path:("/tmp/" + $lab + ".sock")}] end)
        | {sessions:.}'
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ]; then
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
    HERDR_SESSION=scratch \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 long_name
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  long_name="fm-lab-$(printf 'x%.0s' {1..58})"
  status=0
  fm_herdr_lab_validate_name "$long_name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "names beyond Herdr's 64-byte limit must be refused locally"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  pass "fm-herdr-lab: names fail closed and enforce the lab prefix and Herdr's length limit"
}

test_generated_names_fit_herdr_limit() {
  local label name digest generated_limit
  label=implement-herdr-treehouse-child-workspaces-20260712
  digest=$(printf '%s' "$label" | cksum | awk '{print $1}')
  generated_limit=$(fm_herdr_lab_generated_name_limit)
  name=$(fm_herdr_lab_name "$label")
  [ "${#name}" -le 64 ] || fail "generated lab session name exceeds Herdr's 64-byte limit: $name"
  [ "${#name}" -le "$generated_limit" ] || fail "generated lab session name exceeds the Unix-socket path budget: $name"
  fm_herdr_lab_validate_name "$name" || fail "generated length-safe lab session name was refused: $name"
  case "$name" in
    fm-lab-implement-*"-$digest-"*-*) : ;;
    *) fail "generated length-safe lab session lost its readable label or unique suffix: $name" ;;
  esac
  pass "fm-herdr-lab: long task labels retain deterministic identity and collision resistance within Herdr's 64-byte limit"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"
  jq -e '.primary == "scratch" and (.sessions | map(select(.name == "default" and .running == false)) | length) == 1 and (.sessions | map(select(.name == "scratch" and .running == true)) | length) == 1' \
    "$TRIPWIRES/$name.fleet-state.json" >/dev/null \
    || fail "tripwire did not preserve the stopped default and running named primary"

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

test_changed_preexisting_session_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' true > "$FAKE_STATE/default-running"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed pre-existing session state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' false > "$FAKE_STATE/default-running"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "restored fleet state did not release the retained tripwire"
  pass "fm-herdr-lab: any changed pre-existing session state is a hard failure"
}

test_active_primary_must_be_present_and_running() {
  local missing="fm-lab-primary-missing-$$" stopped="fm-lab-primary-stopped-$$" status=0
  printf '%s\n' false > "$FAKE_STATE/primary-present"
  run_with_fake fm_herdr_lab_provision "$missing" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing active primary must block provisioning"
  assert_absent "$TRIPWIRES/$missing.fleet-state.json" "missing primary left a lab ownership tripwire"
  printf '%s\n' true > "$FAKE_STATE/primary-present"

  status=0
  printf '%s\n' false > "$FAKE_STATE/primary-running"
  run_with_fake fm_herdr_lab_provision "$stopped" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stopped active primary must block provisioning"
  assert_absent "$TRIPWIRES/$stopped.fleet-state.json" "stopped primary left a lab ownership tripwire"
  printf '%s\n' true > "$FAKE_STATE/primary-running"
  pass "fm-herdr-lab: HERDR_SESSION must identify one present running primary session"
}

test_existing_session_name_collision_is_refused() {
  local name="fm-lab-collision-$$" status=0
  printf '%s\n' stopped > "$FAKE_STATE/$name"
  run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an existing session name collision must be refused"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "collision refusal left a lab ownership tripwire"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "collision refusal altered the pre-existing session"
  rm -f "$FAKE_STATE/$name"
  pass "fm-herdr-lab: lab names cannot collide with any existing session"
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
test_generated_names_fit_herdr_limit
test_provision_run_and_guarded_teardown
test_missing_tripwire_blocks_destruction
test_changed_preexisting_session_trips_after_teardown
test_active_primary_must_be_present_and_running
test_existing_session_name_collision_is_refused
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
