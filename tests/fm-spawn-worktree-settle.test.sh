#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_herdr_race_fakebin <dir> builds a fake Herdr whose pane metadata stays
# pinned to a stale pool path while commands sent through the exact task pane
# execute in the actual worktree.
# This is the deterministic form of the live Herdr reproduction: the old
# foreground_cwd reader accepts the stale path twice, while a pane-owned pwd
# probe observes the shell that will receive the agent launch.
make_herdr_race_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}\n'
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n'
    ;;
  "tab list")
    printf '{"result":{"tabs":[]}}\n'
    ;;
  "tab create")
    printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"w1:p2","cwd":"%s","foreground_cwd":"%s"}}}\n' \
      "${FM_FAKE_HERDR_PROJECT:?}" "${FM_FAKE_HERDR_STALE:?}"
    ;;
  "pane run")
    command=${4:-}
    case "$command" in
      *"pwd -P >"*)
        if [ "${FM_FAKE_HERDR_PROBE_MODE:-write}" = write ]; then
          (cd "${FM_FAKE_HERDR_ACTUAL:?}" && /bin/bash -c "$command")
        fi
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

make_herdr_race_case() {
  local name=$1 id=$2 case_dir home proj actual stale fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  actual="$case_dir/actual-slot"
  stale="$case_dir/stale-slot"
  log="$case_dir/herdr.log"
  fakebin=$(make_herdr_race_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$actual" "actual-$name"
  git -C "$proj" worktree add --detach "$stale" HEAD >/dev/null
  : > "$log"
  printf '%s\n' "$case_dir|$home|$proj|$actual|$stale|$fakebin|$log"
}

read_herdr_race_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR HERDR_LOG <<EOF
$1
EOF
}

run_herdr_race_spawn() {
  local id=$1 mode=${2:-write}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=herdr HERDR_SESSION=fm-herdr-path-race \
    FM_BACKEND_HERDR_PATH_TIMEOUT_SECS=1 FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_HERDR_PROJECT="$PROJ_DIR" FM_FAKE_HERDR_STALE="$STALE_DIR" \
    FM_FAKE_HERDR_ACTUAL="$WT_DIR" FM_FAKE_HERDR_PROBE_MODE="$mode" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_herdr_stale_foreground_path_cannot_become_metadata() {
  local rec id out status actual_real stale_real
  id=herdr-path-race-z3
  rec=$(make_herdr_race_case herdr-race "$id")
  read_herdr_race_record "$rec"

  out=$(run_herdr_race_spawn "$id")
  status=$?
  actual_real=$(cd "$WT_DIR" && pwd -P)
  stale_real=$(cd "$STALE_DIR" && pwd -P)
  expect_code 0 "$status" "Herdr spawn should succeed once the exact pane shell proves its path"
  assert_contains "$out" "spawned $id" "Herdr spawn did not report success"
  assert_grep "worktree=$actual_real" "$HOME_DIR/state/$id.meta" \
    "Herdr metadata did not record the pane-owned actual worktree"
  assert_no_grep "worktree=$stale_real" "$HOME_DIR/state/$id.meta" \
    "Herdr metadata accepted the stale foreground pool path"
  [ "$(grep -c $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f''(umask 077; pwd -P >' "$HERDR_LOG")" -eq 2 ] \
    || fail "Herdr spawn should require two exact-pane pwd probes"
  assert_no_grep $'\x1f''pane'$'\x1f''get'$'\x1f''w1:p2' "$HERDR_LOG" \
    "Herdr spawn must not consult stale foreground_cwd metadata for containment"
  pass "Herdr stale foreground metadata cannot override the exact pane shell's actual worktree"
}

test_herdr_missing_pane_proof_refuses_before_metadata() {
  local rec id out status
  id=herdr-path-unproved-z4
  rec=$(make_herdr_race_case herdr-unproved "$id")
  read_herdr_race_record "$rec"

  out=$(run_herdr_race_spawn "$id" drop)
  status=$?
  [ "$status" -ne 0 ] || fail "Herdr spawn should refuse when the exact pane never proves its path"
  assert_contains "$out" "did not enter a worktree" "Herdr refusal did not explain the missing containment proof"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "Herdr refusal published metadata without containment proof"
  assert_no_grep $'\x1f''pane'$'\x1f''send-text' "$HERDR_LOG" \
    "Herdr refusal reached agent launch despite missing containment proof"
  [ -d "$WT_DIR" ] && [ -d "$STALE_DIR" ] \
    || fail "Herdr refusal removed an actual or stale pool slot"
  pass "Herdr missing pane-owned path proof refuses metadata and preserves every possible slot"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_herdr_stale_foreground_path_cannot_become_metadata
test_herdr_missing_pane_proof_refuses_before_metadata

echo "# all fm-spawn-worktree-settle tests passed"
