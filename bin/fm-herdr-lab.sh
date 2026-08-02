#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking its
# verified parent fleet session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   FM_HERDR_LAB_PARENT_SESSION=<parent> fm-herdr-lab.sh prepare <session>
#   FM_HERDR_LAB_PARENT_SESSION=<parent> fm-herdr-lab.sh provision <session>
#   FM_HERDR_LAB_PARENT_SESSION=<parent> fm-herdr-lab.sh run <session> <herdr arguments...>
#   FM_HERDR_LAB_PARENT_SESSION=<parent> fm-herdr-lab.sh stop <session>
#   FM_HERDR_LAB_PARENT_SESSION=<parent> fm-herdr-lab.sh teardown <session>
#
# Lifecycle commands require the exact running parent session through
# FM_HERDR_LAB_PARENT_SESSION. The helper never infers it from the session
# inventory. Lifecycle commands require a Herdr-managed caller's injected
# session and socket to agree with the supplied parent. A run call entered
# from the guarded task lab instead requires its injected session and socket
# to exactly match that verified task target.
# Session names must begin with "fm-lab-" and can never equal the parent.
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Provision records the exact running parent-session object as a tripwire.
# Prepare, provision, run, stop, and teardown refuse a missing, ambiguous,
# changed, stopped, cross-runtime, or target-equal parent before proceeding.
# Stop and teardown re-check both the protected parent and task target
# immediately before every destructive call. Successful teardown requires the
# parent snapshot to remain semantically identical, removes only the task lab,
# and clears its tripwire.
# End help.
set -u

fm_herdr_lab_error() {
  echo "fm-herdr-lab: $*" >&2
}

fm_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) fm_herdr_lab_error "refusing session name 'default'" ;;
    '') fm_herdr_lab_error "refusing an empty session name" ;;
    *) fm_herdr_lab_error "session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

fm_herdr_lab_validate_parent_name() { # <parent-session>
  local parent=${1:-}
  if [[ "$parent" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    return 0
  fi
  if [ -z "$parent" ]; then
    fm_herdr_lab_error "FM_HERDR_LAB_PARENT_SESSION is required for every lifecycle command"
  else
    fm_herdr_lab_error "parent session must contain only letters, digits, underscores, or dashes: $parent"
  fi
  return 1
}

fm_herdr_lab_parent_name() {
  local parent=${FM_HERDR_LAB_PARENT_SESSION:-}
  fm_herdr_lab_validate_parent_name "$parent" || return 1
  printf '%s\n' "$parent"
}

fm_herdr_lab_validate_pair() { # <parent-session> <lab-session>
  local parent=$1 name=$2
  fm_herdr_lab_validate_parent_name "$parent" || return 1
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$parent" != "$name" ] || {
    fm_herdr_lab_error "refusing to target protected parent session '$parent' as a task lab"
    return 1
  }
}

fm_herdr_lab_state_dir() {
  printf '%s' "${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}"
}

fm_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.parent-state.json' "$(fm_herdr_lab_state_dir)" "$1"
}

fm_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1
  shift
  HERDR_SESSION="$name" herdr "$@" --session "$name"
}

fm_herdr_lab_session_list() { # <selector-session>
  fm_herdr_lab_raw "$1" session list --json
}

fm_herdr_lab_parent_snapshot_from_inventory() { # <parent-session> <session-list-json>
  local parent=$1 sessions=$2 snapshot
  snapshot=$(printf '%s' "$sessions" | jq -cS --arg parent "$parent" '
    [.sessions[]? | select(.name == $parent)]
    | if (
        length == 1
        and (.[0].running == true)
        and (((.[0].socket_path // "") | type) == "string")
        and (((.[0].socket_path // "") | length) > 0)
        and (if $parent == "default" then .[0].default == true else .[0].default == false end)
      )
      then .[0]
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "protected parent '$parent' must resolve to exactly one running session with a verified socket and matching default identity"
    return 1
  }
  printf '%s\n' "$snapshot"
}

fm_herdr_lab_verify_runtime_parent() { # <parent-session> <parent-snapshot> [<lab-session> <lab-snapshot>]
  local parent=$1 snapshot=$2 name=${3:-} target_snapshot=${4:-} runtime_claim=0 runtime_session runtime_socket snapshot_socket marker
  for marker in HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH; do
    [ -z "${!marker:-}" ] || runtime_claim=1
  done
  [ "$runtime_claim" -eq 1 ] || return 0

  runtime_session=${HERDR_SESSION:-}
  runtime_socket=${HERDR_SOCKET_PATH:-}
  if [ "$runtime_session" = "$parent" ]; then
    if [ -z "$runtime_socket" ]; then
      return 0
    fi
    snapshot_socket=$(printf '%s' "$snapshot" | jq -er '.socket_path' 2>/dev/null) || {
      fm_herdr_lab_error "protected parent '$parent' has no verifiable socket identity"
      return 1
    }
    [ "$runtime_socket" = "$snapshot_socket" ] || {
      fm_herdr_lab_error "protected parent '$parent' socket disagrees with the Herdr-managed caller"
      return 1
    }
    return 0
  fi
  if [ -n "$name" ] && [ "$runtime_session" = "$name" ]; then
    [ -n "$runtime_socket" ] || {
      fm_herdr_lab_error "task lab '$name' must provide its injected Herdr socket identity"
      return 1
    }
    snapshot_socket=$(printf '%s' "$target_snapshot" | jq -er '.socket_path' 2>/dev/null) || {
      fm_herdr_lab_error "task lab '$name' has no verifiable socket identity"
      return 1
    }
    [ "$runtime_socket" = "$snapshot_socket" ] || {
      fm_herdr_lab_error "task lab '$name' socket disagrees with the Herdr-managed caller"
      return 1
    }
    return 0
  fi
  fm_herdr_lab_error "protected parent '$parent' disagrees with the Herdr-managed caller session '${runtime_session:-<missing>}'"
  return 1
}

fm_herdr_lab_target_snapshot_from_inventory() { # <lab-session> <session-list-json>
  local name=$1 sessions=$2 snapshot
  snapshot=$(printf '%s' "$sessions" | jq -cS --arg name "$name" '
    [.sessions[]? | select(.name == $name)]
    | if (
        length == 1
        and .[0].default == false
        and (((.[0].socket_path // "") | type) == "string")
        and (((.[0].socket_path // "") | length) > 0)
      )
      then .[0]
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    fm_herdr_lab_error "task lab '$name' is missing, ambiguous, default, or lacks a verified socket"
    return 1
  }
  printf '%s\n' "$snapshot"
}

fm_herdr_lab_distinct_target_snapshot() { # <parent-session> <lab-session> <session-list-json>
  local parent=$1 name=$2 sessions=$3 parent_snapshot target_snapshot parent_socket target_socket
  parent_snapshot=$(fm_herdr_lab_parent_snapshot_from_inventory "$parent" "$sessions") || return 1
  target_snapshot=$(fm_herdr_lab_target_snapshot_from_inventory "$name" "$sessions") || return 1
  parent_socket=$(printf '%s' "$parent_snapshot" | jq -er '.socket_path' 2>/dev/null) || return 1
  target_socket=$(printf '%s' "$target_snapshot" | jq -er '.socket_path' 2>/dev/null) || return 1
  [ "$parent_socket" != "$target_socket" ] || {
    fm_herdr_lab_error "refusing task lab '$name': it resolves to the protected parent '$parent' socket"
    return 1
  }
  printf '%s\n' "$target_snapshot"
}

fm_herdr_lab_tripwire_record() { # <session>
  local name=$1 tripwire record
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] && [ ! -L "$tripwire" ] || {
    fm_herdr_lab_error "protected-parent tripwire for '$name' is missing or not a regular non-symlink file; refusing unverified operation"
    return 1
  }
  record=$(jq -cS -e '
    select(
      .version == 1
      and (.lab_session | type == "string")
      and (.parent_session | type == "string")
      and (.parent_state | type == "object")
    )
  ' "$tripwire" 2>/dev/null) || {
    fm_herdr_lab_error "protected-parent tripwire for '$name' is malformed"
    return 1
  }
  printf '%s\n' "$record"
}

fm_herdr_lab_tripwire_binding() { # <parent-session> <lab-session>
  local parent=$1 name=$2 record record_parent record_lab
  record=$(fm_herdr_lab_tripwire_record "$name") || return 1
  record_parent=$(printf '%s' "$record" | jq -r '.parent_session')
  record_lab=$(printf '%s' "$record" | jq -r '.lab_session')
  [ "$record_parent" = "$parent" ] || {
    fm_herdr_lab_error "protected parent changed from '$record_parent' to '$parent'; refusing to guess"
    return 1
  }
  [ "$record_lab" = "$name" ] || {
    fm_herdr_lab_error "tripwire lab identity '$record_lab' does not match requested task lab '$name'"
    return 1
  }
  printf '%s\n' "$record"
}

fm_herdr_lab_verify_inventory_binding() { # <parent-session> <lab-session> <session-list-json> [allow-task-runtime]
  local parent=$1 name=$2 sessions=$3 allow_task_runtime=${4:-0} record before after target_snapshot
  record=$(fm_herdr_lab_tripwire_binding "$parent" "$name") || return 1
  before=$(printf '%s' "$record" | jq -cS '.parent_state')
  after=$(fm_herdr_lab_parent_snapshot_from_inventory "$parent" "$sessions") || return 1
  if [ "$allow_task_runtime" = 1 ]; then
    target_snapshot=$(fm_herdr_lab_distinct_target_snapshot "$parent" "$name" "$sessions") || return 1
    fm_herdr_lab_verify_runtime_parent "$parent" "$after" "$name" "$target_snapshot" || return 1
  else
    fm_herdr_lab_verify_runtime_parent "$parent" "$after" || return 1
  fi
  [ "$before" = "$after" ] || {
    fm_herdr_lab_error "PROTECTED-PARENT TRIPWIRE FAILED: session '$parent' changed during lab work"
    fm_herdr_lab_error "before: $before"
    fm_herdr_lab_error "after:  $after"
    return 1
  }
}

fm_herdr_lab_check_tripwire() { # <session>
  local name=$1 parent sessions
  parent=$(fm_herdr_lab_parent_name) || return 1
  fm_herdr_lab_validate_pair "$parent" "$name" || return 1
  fm_herdr_lab_tripwire_binding "$parent" "$name" >/dev/null || return 1
  sessions=$(fm_herdr_lab_session_list "$parent" 2>/dev/null) || {
    fm_herdr_lab_error "cannot read Herdr sessions while checking protected parent '$parent'"
    return 1
  }
  fm_herdr_lab_verify_inventory_binding "$parent" "$name" "$sessions"
}

fm_herdr_lab_guard_target() { # <session> [allow-task-runtime]
  local name=$1 allow_task_runtime=${2:-0} parent sessions
  parent=$(fm_herdr_lab_parent_name) || return 1
  fm_herdr_lab_validate_pair "$parent" "$name" || return 1
  fm_herdr_lab_tripwire_binding "$parent" "$name" >/dev/null || return 1
  sessions=$(fm_herdr_lab_session_list "$parent" 2>/dev/null) || {
    fm_herdr_lab_error "refusing task-lab operation because session inventory failed"
    return 1
  }
  fm_herdr_lab_verify_inventory_binding "$parent" "$name" "$sessions" "$allow_task_runtime" || return 1
  fm_herdr_lab_distinct_target_snapshot "$parent" "$name" "$sessions" >/dev/null
}

fm_herdr_lab_write_tripwire() { # <parent-session> <lab-session> <parent-snapshot>
  local parent=$1 name=$2 snapshot=$3 state_dir tripwire temporary record
  state_dir=$(fm_herdr_lab_state_dir)
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  mkdir -p "$state_dir" || return 1
  chmod 700 "$state_dir" 2>/dev/null || true
  [ ! -e "$tripwire" ] || {
    fm_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  record=$(jq -cnS --arg parent "$parent" --arg lab "$name" --argjson state "$snapshot" \
    '{version:1,lab_session:$lab,parent_session:$parent,parent_state:$state}') || return 1
  temporary="$tripwire.tmp.$$.$RANDOM"
  (umask 077; printf '%s\n' "$record" > "$temporary") || {
    rm -f "$temporary"
    return 1
  }
  if ! mv "$temporary" "$tripwire"; then
    rm -f "$temporary"
    return 1
  fi
}

fm_herdr_lab_prepare() { # <session>
  local name=$1 parent sessions parent_snapshot target_count
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  parent=$(fm_herdr_lab_parent_name) || return 1
  fm_herdr_lab_validate_pair "$parent" "$name" || return 1

  sessions=$(fm_herdr_lab_session_list "$parent" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before preparing '$name'"
    return 1
  }
  parent_snapshot=$(fm_herdr_lab_parent_snapshot_from_inventory "$parent" "$sessions") || return 1
  fm_herdr_lab_verify_runtime_parent "$parent" "$parent_snapshot" || return 1
  target_count=$(printf '%s' "$sessions" | jq -r --arg name "$name" '[.sessions[]? | select(.name == $name)] | length' 2>/dev/null) || {
    fm_herdr_lab_error "cannot verify task-lab absence before preparing '$name'"
    return 1
  }
  [ "$target_count" = 0 ] || {
    fm_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  }
  fm_herdr_lab_write_tripwire "$parent" "$name" "$parent_snapshot"
}

fm_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  fm_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { fm_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      fm_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        fm_herdr_lab_error "run forbids caller-supplied --session; the helper appends the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      fm_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      fm_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  fm_herdr_lab_guard_target "$name" 1 || return 1
  fm_herdr_lab_raw "$name" "$@"
}

fm_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

fm_herdr_lab_provision() { # <session>
  local name=$1 parent sessions tripwire running attempt server_pid max_attempts timeout_seconds target target_running
  fm_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { fm_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_herdr_lab_error "jq is required"; return 1; }
  parent=$(fm_herdr_lab_parent_name) || return 1
  fm_herdr_lab_validate_pair "$parent" "$name" || return 1

  sessions=$(fm_herdr_lab_session_list "$parent" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(fm_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      fm_herdr_lab_error "missing protected-parent tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    fm_herdr_lab_verify_inventory_binding "$parent" "$name" "$sessions" || return 1
    target=$(fm_herdr_lab_distinct_target_snapshot "$parent" "$name" "$sessions") || return 1
    target_running=$(printf '%s' "$target" | jq -r '.running')
    [ "$target_running" = false ] || {
      fm_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
  else
    fm_herdr_lab_prepare "$name" || return 1
  fi

  fm_herdr_lab_check_tripwire "$name" || return 1
  fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt "$max_attempts" ]; do
    fm_herdr_lab_check_tripwire "$name" || {
      fm_herdr_lab_cancel_provision "$server_pid"
      return 1
    }
    running=$(fm_herdr_lab_raw "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      fm_herdr_lab_guard_target "$name" || {
        fm_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  fm_herdr_lab_cancel_provision "$server_pid"
  fm_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

fm_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire state_dir
  fm_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(fm_herdr_lab_tripwire_path "$name")
  state_dir=$(fm_herdr_lab_state_dir)
  rm -f "$tripwire"
  rmdir "$state_dir" 2>/dev/null || true
}

fm_herdr_lab_stop() { # <session>
  local name=$1 status=0
  fm_herdr_lab_validate_name "$name" || return 1
  fm_herdr_lab_guard_target "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json || status=$?
  fm_herdr_lab_check_tripwire "$name" || return 1
  return "$status"
}

fm_herdr_lab_teardown() { # <session>
  local name=$1 parent sessions delete_status=0
  fm_herdr_lab_validate_name "$name" || return 1
  parent=$(fm_herdr_lab_parent_name) || return 1
  fm_herdr_lab_validate_pair "$parent" "$name" || return 1
  fm_herdr_lab_tripwire_binding "$parent" "$name" >/dev/null || return 1

  sessions=$(fm_herdr_lab_session_list "$parent" 2>/dev/null) || {
    fm_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  fm_herdr_lab_verify_inventory_binding "$parent" "$name" "$sessions" || return 1
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fm_herdr_lab_verify_tripwire "$name"
    return
  fi
  fm_herdr_lab_guard_target "$name" || return 1
  fm_herdr_lab_raw "$name" session stop "$name" --json >/dev/null 2>&1 || true
  fm_herdr_lab_check_tripwire "$name" || return 1
  sleep 0.5

  fm_herdr_lab_guard_target "$name" || return 1
  fm_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  fm_herdr_lab_check_tripwire "$name" || return 1

  sessions=$(fm_herdr_lab_session_list "$parent" 2>/dev/null) || {
    fm_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  fm_herdr_lab_verify_inventory_binding "$parent" "$name" "$sessions" || return 1
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      fm_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      fm_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  fm_herdr_lab_verify_tripwire "$name"
}

fm_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'fm-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

fm_herdr_lab_usage() {
  awk '
    /^# Usage:/ { emit = 1 }
    /^# End help\./ { exit }
    emit {
      sub(/^# ?/, "")
      print
    }
  ' "${BASH_SOURCE[0]}"
}

fm_herdr_lab_main() {
  local command=${1:-}
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { fm_herdr_lab_usage >&2; return 2; }
      shift
      fm_herdr_lab_cli "$@"
      ;;
    stop)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { fm_herdr_lab_usage >&2; return 2; }
      fm_herdr_lab_teardown "$2"
      ;;
    -h|--help|help)
      fm_herdr_lab_usage
      ;;
    *)
      fm_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_herdr_lab_main "$@"
fi
