#!/usr/bin/env bash
# Regression coverage for Firstmate-on-itself child operational-home isolation.
# All repos, FM_HOME fixtures, backend calls, and lock files stay under a
# self-cleaning temp root. No live Firstmate home or terminal pane is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-task-home)
fm_git_identity fmtest fmtest@example.invalid

cleanup() {
  rm -rf /tmp/fm-self-home-z1 /tmp/fm-external-home-z2
  fm_test_cleanup
}
trap cleanup EXIT

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?FM_FAKE_TMUX_LOG unset}
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 1 ] || printf '\037'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$log"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#S"*) printf 'firstmate\n'; exit 0 ;;
esac
case "${1:-}" in
  has-session|list-windows|send-keys|set-window-option|kill-window) exit 0 ;;
  new-session) exit 0 ;;
  new-window) printf '@1\n'; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_self_repo() {
  local repo=$1 wt=$2
  fm_git_init_commit "$repo"
  cp -R "$ROOT/bin" "$repo/bin"
  cp "$ROOT/AGENTS.md" "$repo/AGENTS.md"
  git -C "$repo" add bin AGENTS.md
  git -C "$repo" commit -qm tooling
  git -C "$repo" worktree add --quiet -b fm/task-home-fixture "$wt"
}

run_spawn() {
  local root=$1 home=$2 project=$3 wt=$4 fakebin=$5 log=$6 id=$7
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LOG="$log" \
    PATH="$fakebin:$PATH" "$root/bin/fm-spawn.sh" \
    "$id" "$project" --harness codex --backend tmux 2>&1
}

test_self_repo_gets_task_private_home() {
  local case_dir="$TMP_ROOT/self" root="$TMP_ROOT/self/repo" wt="$TMP_ROOT/self/wt"
  local home="$TMP_ROOT/self/home" log="$TMP_ROOT/self/tmux.log" id=self-home-z1
  local fakebin tasktmp taskhome out status=0
  mkdir -p "$case_dir" "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'fixture brief\n' > "$home/data/$id/brief.md"
  printf 'supervisor-lock-sentinel\n' > "$home/state/.lock"
  make_self_repo "$root" "$wt"
  fakebin=$(make_fakebin "$case_dir/fake")

  out=$(run_spawn "$root" "$home" "$root" "$wt" "$fakebin" "$log" "$id") || status=$?
  expect_code 0 "$status" "Firstmate-on-itself spawn"
  assert_contains "$out" "spawned $id" "self-repo spawn did not complete"

  tasktmp="/tmp/fm-$id"
  taskhome="$tasktmp/home"
  assert_grep "tasktmp=$tasktmp" "$home/state/$id.meta" "task temp root was not recorded"
  assert_grep "taskhome=$taskhome" "$home/state/$id.meta" "task-private home was not recorded"
  for dir in data state config projects; do
    [ -d "$taskhome/$dir" ] || fail "task-private home is missing $dir/"
  done
  assert_grep "FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME='$taskhome' codex" \
    "$log" "child launch did not clear inherited overrides and select its task-private home"
  [ "$(cat "$home/state/.lock")" = supervisor-lock-sentinel ] \
    || fail "spawn changed the supervising home's session lock"
  pass "Firstmate-on-itself spawn isolates FM_HOME and preserves the supervisor lock"
}

test_external_project_keeps_historical_launch_environment() {
  local case_dir="$TMP_ROOT/external" root="$TMP_ROOT/external/repo" wt="$TMP_ROOT/external/wt"
  local project="$TMP_ROOT/external/project" home="$TMP_ROOT/external/home"
  local log="$TMP_ROOT/external/tmux.log" id=external-home-z2 fakebin out status=0
  mkdir -p "$case_dir" "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'fixture brief\n' > "$home/data/$id/brief.md"
  fm_git_init_commit "$root"
  cp -R "$ROOT/bin" "$root/bin"
  git -C "$root" add bin
  git -C "$root" commit -qm tooling
  fm_git_worktree "$project" "$wt" fm/external-task
  fakebin=$(make_fakebin "$case_dir/fake")

  out=$(run_spawn "$root" "$home" "$project" "$wt" "$fakebin" "$log" "$id") || status=$?
  expect_code 0 "$status" "external-project spawn"
  assert_contains "$out" "spawned $id" "external-project spawn did not complete"
  assert_no_grep '^taskhome=' "$home/state/$id.meta" "external project unexpectedly received a Firstmate task home"
  assert_no_grep 'FM_HOME=.*/tmp/fm-external-home-z2/home' "$log" \
    "external project launch environment changed"
  pass "external-project spawn retains its historical launch environment"
}

test_self_repo_gets_task_private_home
test_external_project_keeps_historical_launch_environment

echo "# all fm-spawn task-home tests passed"
