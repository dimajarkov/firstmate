#!/usr/bin/env bash
# Focused fake-backend coverage for the ordinary Herdr spawn layout.
# The adapter-level fake tests own duplicate/recovery/teardown identity checks;
# this suite pins fm-spawn.sh's Treehouse lease ordering and metadata wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-task-workspace)
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/treehouse/task-a1"
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_LOG="$TMP_ROOT/herdr.log"
TREEHOUSE_LOG="$TMP_ROOT/treehouse.log"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/task-a1" "$HOME_DIR/config" "$FAKEBIN" "$(dirname "$WORKTREE")"
: > "$HERDR_LOG"
: > "$TREEHOUSE_LOG"

fm_git_init_commit "$PROJECT"
git -C "$PROJECT" worktree add -q -b task-a1 "$WORKTREE"
printf '%s\n' '- project [local-only] - fixture (added 2026-07-13)' > "$HOME_DIR/data/projects.md"
printf '%s\n' 'test brief' > "$HOME_DIR/data/task-a1/brief.md"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse' >> "${FM_FAKE_TREEHOUSE_LOG:?}"
for arg in "$@"; do printf '\x1f%s' "$arg" >> "$FM_FAKE_TREEHOUSE_LOG"; done
printf '\n' >> "$FM_FAKE_TREEHOUSE_LOG"
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_WORKTREE:?}" ;;
  return) : ;;
esac
SH
chmod +x "$FAKEBIN/treehouse"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf 'herdr' >> "${FM_FAKE_HERDR_LOG:?}"
for arg in "$@"; do printf '\x1f%s' "$arg" >> "$FM_FAKE_HERDR_LOG"; done
printf '\n' >> "$FM_FAKE_HERDR_LOG"
case "${1:-} ${2:-}" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.7.3","protocol":16},"server":{"running":true}}'
    ;;
  'workspace list')
    printf '%s\n' '{"result":{"workspaces":[]}}'
    ;;
  'workspace create')
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w-task"},"tab":{"tab_id":"w-task:t1"},"root_pane":{"pane_id":"w-task:p1"}}}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

OUT="$TMP_ROOT/spawn.out"
ERR="$TMP_ROOT/spawn.err"
PATH="$FAKEBIN:$PATH" FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" HERDR_SESSION=fm-fake-task-workspaces \
  FM_FAKE_WORKTREE="$WORKTREE" FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
  "$ROOT/bin/fm-spawn.sh" task-a1 "$PROJECT" "sh -c 'echo fake-agent'" --backend herdr > "$OUT" 2> "$ERR" \
  || fail "fm-spawn.sh failed in the fake Herdr task-workspace case$(printf '\n--- stdout ---\n%s\n--- stderr ---\n%s' "$(cat "$OUT")" "$(cat "$ERR")")"

META="$HOME_DIR/state/task-a1.meta"
[ -f "$META" ] || fail "fm-spawn.sh did not write task metadata"
assert_contains "$(cat "$META")" "worktree=$WORKTREE" "metadata did not record the exact leased Treehouse worktree"
assert_contains "$(cat "$META")" "herdr_workspace_id=w-task" "metadata did not record the task workspace id"
assert_contains "$(cat "$META")" "herdr_tab_id=w-task:t1" "metadata did not record the seeded root tab id"
assert_contains "$(cat "$META")" "herdr_pane_id=w-task:p1" "metadata did not record the seeded root pane id"
assert_contains "$(cat "$META")" "herdr_layout=task-workspace" "metadata did not mark the task-workspace layout"

assert_contains "$(cat "$TREEHOUSE_LOG")" $'treehouse\x1fget\x1f--lease\x1f--lease-holder\x1ftask-a1' \
  "ordinary Herdr spawn did not acquire a durable Treehouse lease under the task id"
assert_contains "$(cat "$HERDR_LOG")" $'herdr\x1fworkspace\x1fcreate\x1f--cwd\x1f'"$WORKTREE"$'\x1f--label\x1ffm-task-a1\x1f--no-focus' \
  "ordinary Herdr spawn did not create fm-<id> workspace at the exact worktree cwd with --no-focus"
assert_not_contains "$(cat "$HERDR_LOG")" $'herdr\x1ftab\x1fcreate' \
  "ordinary Herdr spawn created a second tab instead of reusing the seeded root tab"
assert_not_contains "$(cat "$HERDR_LOG")" $'treehouse get' \
  "ordinary Herdr spawn still tried to run interactive treehouse get inside the root pane"

pass "fm-spawn.sh: ordinary Herdr task leases Treehouse first, creates one fm-<id> workspace at that cwd, and records seeded root ids"
