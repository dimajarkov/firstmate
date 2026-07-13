#!/usr/bin/env bash
# Isolated real-Herdr E2E for ordinary task workspaces.
# Two crewmates spawned by one secondmate home must receive distinct fm-<id>
# workspaces rooted at their exact Treehouse leases. Tearing down one must
# leave the sibling task workspace and persistent supervisor workspace alive.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
BASE_PATH=$PATH

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {
  case "$1" in *"$2"*) : ;; *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;; esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"

REAL_HERDR=$(command -v herdr)
REAL_HERDR_DIR=$(dirname "$REAL_HERDR")
HERDR_LAB_SESSION=$(PATH="$REAL_HERDR_DIR:$BASE_PATH" "$HERDR_LAB_HELPER" name herdr-task-workspaces-s4)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-task-workspaces.XXXXXX")
WT1=
WT2=
POOL1=
POOL2=
PROJ1=
PROJ2=
LAB_TORN_DOWN=0

lab() {
  PATH="$REAL_HERDR_DIR:$BASE_PATH" "$HERDR_LAB_HELPER" "$@"
}

assert_fixture_pool_empty() { # <project> <pool>
  local project=$1 pool=$2 inventory remaining
  [ -n "$project" ] && [ -n "$pool" ] || return 0
  inventory=$(cd "$project" && treehouse status 2>&1) || {
    printf 'not ok - could not inspect fixture Treehouse pool %s after cleanup\n%s\n' "$pool" "$inventory" >&2
    return 1
  }
  case "$inventory" in
    *"$(basename "$pool")"*)
      printf 'not ok - fixture Treehouse pool still reports a worktree after cleanup: %s\n%s\n' "$pool" "$inventory" >&2
      return 1
      ;;
  esac
  remaining=$(find "$pool" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)
  [ -z "$remaining" ] || {
    printf 'not ok - fixture Treehouse pool still contains a worktree directory after cleanup: %s\n' "$remaining" >&2
    return 1
  }
}

cleanup_all() {
  local cleanup_status=0 pool previous_pool=

  # The lab owns every process rooted in the fixture worktrees. Stop and
  # delete that isolated session first so normal non-force returns never race
  # a lingering pane shell or agent process.
  if [ "$LAB_TORN_DOWN" -eq 0 ]; then
    if lab teardown "$HERDR_LAB_SESSION"; then
      LAB_TORN_DOWN=1
    else
      printf 'not ok - isolated Herdr lab teardown failed during cleanup\n' >&2
      cleanup_status=1
    fi
  fi
  if [ "$cleanup_status" -eq 0 ] && [ -n "$WT1" ]; then
    if treehouse return "$WT1"; then
      WT1=
    else
      printf 'not ok - normal Treehouse return failed during cleanup: %s\n' "$WT1" >&2
      cleanup_status=1
    fi
  fi
  if [ "$cleanup_status" -eq 0 ] && [ -n "$WT2" ]; then
    if treehouse return "$WT2"; then
      WT2=
    else
      printf 'not ok - normal Treehouse return failed during cleanup: %s\n' "$WT2" >&2
      cleanup_status=1
    fi
  fi

  # Once every lease is returned, remove only the two exact scratch-project
  # pools. Never delete TMP_ROOT first: that would turn a missed pool into an
  # unverifiable backing-repository-missing orphan.
  if [ "$cleanup_status" -eq 0 ]; then
    for pool in "$POOL1" "$POOL2"; do
      [ -n "$pool" ] || continue
      [ "$pool" != "$previous_pool" ] || continue
      previous_pool=$pool
      if [ -d "$pool" ] && ! treehouse destroy "$pool" --all --yes; then
        printf 'not ok - failed to destroy exact fixture Treehouse pool: %s\n' "$pool" >&2
        cleanup_status=1
      fi
    done
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    assert_fixture_pool_empty "$PROJ1" "$POOL1" || cleanup_status=1
    assert_fixture_pool_empty "$PROJ2" "$POOL2" || cleanup_status=1
  fi
  if [ "$cleanup_status" -eq 0 ]; then
    if rm -rf "$TMP_ROOT" && [ ! -e "$TMP_ROOT" ]; then
      pass "real Herdr E2E cleanup: isolated session removed, every lease returned, and no fixture Treehouse pool/orphan remains"
    else
      printf 'not ok - fixture pools were clean but TMP_ROOT could not be removed: %s\n' "$TMP_ROOT" >&2
      cleanup_status=1
    fi
  else
    printf 'not ok - cleanup incomplete; preserving fixture root for inspection: %s\n' "$TMP_ROOT" >&2
  fi
  return "$cleanup_status"
}

# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap below.
cleanup_on_exit() {
  local status=$?
  trap - EXIT
  cleanup_all || status=1
  exit "$status"
}
trap cleanup_on_exit EXIT
lab provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

# Route every session-specific call made by fm-spawn/fm-teardown through the
# hard-safety helper. The adapter already appends a trailing --session; this
# shim removes that pair and delegates the remaining command to helper run.
SHIM="$TMP_ROOT/herdr-shim"
mkdir -p "$SHIM"
cat > "$SHIM/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
count=${#args[@]}
if [ "$count" -ge 2 ] && [ "${args[$((count - 2))]}" = --session ]; then
  session=${args[$((count - 1))]}
  unset 'args[count-1]' 'args[count-2]'
  PATH="${HERDR_E2E_REAL_DIR:?}:${HERDR_E2E_BASE_PATH:?}" exec "${HERDR_E2E_HELPER:?}" run "$session" "${args[@]}"
fi
# The adapter's version gate intentionally reads client-only fields through a
# bare status call. Keep that exact probe inside the helper too; refuse every
# other call that lacks explicit trailing session scope.
if [ "$count" -eq 2 ] && [ "${args[0]}" = status ] && [ "${args[1]}" = --json ] && [ -n "${HERDR_SESSION:-}" ]; then
  PATH="${HERDR_E2E_REAL_DIR:?}:${HERDR_E2E_BASE_PATH:?}" exec "${HERDR_E2E_HELPER:?}" run "$HERDR_SESSION" "${args[@]}"
fi
printf 'real Herdr E2E shim: refusing a call without trailing --session\n' >&2
exit 90
SH
chmod +x "$SHIM/herdr"
export PATH="$SHIM:$BASE_PATH"
export HERDR_E2E_REAL_DIR="$REAL_HERDR_DIR"
export HERDR_E2E_BASE_PATH="$BASE_PATH" HERDR_E2E_HELPER="$HERDR_LAB_HELPER"
export HERDR_SESSION="$HERDR_LAB_SESSION"

make_project() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

PRIMARY_HOME="$TMP_ROOT/primary-home"
SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$PRIMARY_HOME/state" "$PRIMARY_HOME/data" "$PRIMARY_HOME/config"
mkdir -p "$SM_HOME/state" "$SM_HOME/data/crew-one" "$SM_HOME/data/crew-two" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf '# scratch secondmate home\n' > "$SM_HOME/AGENTS.md"
printf 'e2esm1\n' > "$SM_HOME/.fm-secondmate-home"
printf 'supervisor charter\n' > "$SM_HOME/data/charter.md"
printf 'crew one brief\n' > "$SM_HOME/data/crew-one/brief.md"
printf 'crew two brief\n' > "$SM_HOME/data/crew-two/brief.md"

PROJ1="$TMP_ROOT/project-one"
PROJ2="$TMP_ROOT/project-two"
make_project "$PROJ1"
make_project "$PROJ2"
{
  printf -- '- project-one [local-only] - fixture (added 2026-07-13)\n'
  printf -- '- project-two [local-only] - fixture (added 2026-07-13)\n'
} > "$SM_HOME/data/projects.md"

SM_OUT="$TMP_ROOT/supervisor.out"
FM_SPAWN_NO_GUARD=1 FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" e2esm1 "$SM_HOME" "sh -c 'echo supervisor-ok; sleep 300'" --secondmate --backend herdr > "$SM_OUT" 2>&1 \
  || fail "secondmate supervisor spawn failed$(printf '\n%s' "$(cat "$SM_OUT")")"
SM_META="$PRIMARY_HOME/state/e2esm1.meta"
SM_WSID=$(sed -n 's/^herdr_workspace_id=//p' "$SM_META")
SM_PANE=$(sed -n 's/^herdr_pane_id=//p' "$SM_META")
[ -n "$SM_WSID" ] && [ -n "$SM_PANE" ] || fail "supervisor metadata is missing workspace/pane identity"

spawn_crew() {
  local id=$1 project=$2 out="$TMP_ROOT/$1.out"
  FM_SPAWN_NO_GUARD=1 FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'echo $id-ok; sleep 300'" --backend herdr > "$out" 2>&1 \
    || fail "$id spawn failed$(printf '\n%s' "$(cat "$out")")"
}

spawn_crew crew-one "$PROJ1"
spawn_crew crew-two "$PROJ2"
META1="$SM_HOME/state/crew-one.meta"
META2="$SM_HOME/state/crew-two.meta"
WT1=$(sed -n 's/^worktree=//p' "$META1")
WT2=$(sed -n 's/^worktree=//p' "$META2")
POOL1=$(dirname "$(dirname "$WT1")")
POOL2=$(dirname "$(dirname "$WT2")")
WS1=$(sed -n 's/^herdr_workspace_id=//p' "$META1")
WS2=$(sed -n 's/^herdr_workspace_id=//p' "$META2")
TAB1=$(sed -n 's/^herdr_tab_id=//p' "$META1")
TAB2=$(sed -n 's/^herdr_tab_id=//p' "$META2")
PANE1=$(sed -n 's/^herdr_pane_id=//p' "$META1")
PANE2=$(sed -n 's/^herdr_pane_id=//p' "$META2")

[ "$WS1" != "$WS2" ] || fail "two crewmates from one secondmate home shared workspace $WS1"
[ "$WS1" != "$SM_WSID" ] && [ "$WS2" != "$SM_WSID" ] || fail "ordinary crewmate reused the supervisor workspace"
assert_contains_local "$(cat "$META1")" "herdr_layout=task-workspace" "crew-one metadata lacks task-workspace layout"
assert_contains_local "$(cat "$META2")" "herdr_layout=task-workspace" "crew-two metadata lacks task-workspace layout"

WORKSPACES=$(lab run "$HERDR_LAB_SESSION" workspace list)
LABEL1=$(printf '%s' "$WORKSPACES" | jq -r --arg id "$WS1" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
LABEL2=$(printf '%s' "$WORKSPACES" | jq -r --arg id "$WS2" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$LABEL1" = fm-crew-one ] || fail "crew-one workspace label is '$LABEL1'"
[ "$LABEL2" = fm-crew-two ] || fail "crew-two workspace label is '$LABEL2'"

PANE1_JSON=$(lab run "$HERDR_LAB_SESSION" pane get "$PANE1")
PANE2_JSON=$(lab run "$HERDR_LAB_SESSION" pane get "$PANE2")
CWD1=$(printf '%s' "$PANE1_JSON" | jq -r '.result.pane.cwd // empty')
CWD2=$(printf '%s' "$PANE2_JSON" | jq -r '.result.pane.cwd // empty')
[ "$CWD1" = "$(cd "$WT1" && pwd -P)" ] || fail "crew-one workspace cwd '$CWD1' does not equal Treehouse checkout '$WT1'"
[ "$CWD2" = "$(cd "$WT2" && pwd -P)" ] || fail "crew-two workspace cwd '$CWD2' does not equal Treehouse checkout '$WT2'"

TABS1=$(lab run "$HERDR_LAB_SESSION" tab list --workspace "$WS1")
TABS2=$(lab run "$HERDR_LAB_SESSION" tab list --workspace "$WS2")
[ "$(printf '%s' "$TABS1" | jq -r '.result.tabs | length')" = 1 ] || fail "crew-one workspace has an extra tab"
[ "$(printf '%s' "$TABS2" | jq -r '.result.tabs | length')" = 1 ] || fail "crew-two workspace has an extra tab"
printf '%s' "$TABS1" | jq -e --arg id "$TAB1" '.result.tabs[]? | select(.tab_id == $id)' >/dev/null || fail "crew-one metadata tab is not the seeded root tab"
printf '%s' "$TABS2" | jq -e --arg id "$TAB2" '.result.tabs[]? | select(.tab_id == $id)' >/dev/null || fail "crew-two metadata tab is not the seeded root tab"
pass "real Herdr E2E: two crewmates from one secondmate home receive distinct fm-<id> workspaces at their exact Treehouse checkouts"

TD1_OUT="$TMP_ROOT/teardown-one.out"
FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" crew-one > "$TD1_OUT" 2>&1 \
  || fail "crew-one teardown failed$(printf '\n%s' "$(cat "$TD1_OUT")")"
WT1=

POST=$(lab run "$HERDR_LAB_SESSION" workspace list)
printf '%s' "$POST" | jq -e --arg id "$WS1" '.result.workspaces[]? | select(.workspace_id == $id)' >/dev/null 2>&1 \
  && fail "crew-one workspace survived teardown"
printf '%s' "$POST" | jq -e --arg id "$WS2" '.result.workspaces[]? | select(.workspace_id == $id)' >/dev/null \
  || fail "crew-two sibling workspace was closed by crew-one teardown"
printf '%s' "$POST" | jq -e --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id)' >/dev/null \
  || fail "supervisor workspace was closed by crew-one teardown"
lab run "$HERDR_LAB_SESSION" pane get "$PANE2" >/dev/null || fail "crew-two pane was closed by crew-one teardown"
lab run "$HERDR_LAB_SESSION" pane get "$SM_PANE" >/dev/null || fail "supervisor pane was closed by crew-one teardown"
pass "real Herdr E2E: tearing down one task closes only its workspace; sibling and supervisor workspaces remain"

cleanup_status=0
cleanup_all || cleanup_status=$?
trap - EXIT
exit "$cleanup_status"
