#!/usr/bin/env bash
# Portable regression coverage for test-owned Treehouse isolation and lifecycle.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/treehouse-test-safety.sh
. "$REPO_ROOT/tests/treehouse-test-safety.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-safety-unit.XXXXXX")
ORIGINAL_HOME=${HOME:-}
cleanup() {
  HOME=$ORIGINAL_HOME
  export HOME
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

HOME="$SCRATCH/ambient-home"
export HOME
mkdir -p "$HOME/.treehouse"
printf 'ambient\n' > "$HOME/.treehouse/sentinel"
ambient_before=$(find "$HOME/.treehouse" -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort)

make_repo() { # <root> <name>
  local repo="$1/$2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  printf '%s\n' "$repo"
}

# A valid prepare binds repo config, pool state, and updater behavior below the
# exact temporary root before any Treehouse command runs.
VALID_ROOT="$SCRATCH/valid"
VALID_PROJECT=$(make_repo "$VALID_ROOT" project)
fm_treehouse_test_isolation_prepare "$VALID_ROOT" "$VALID_PROJECT" \
  || fail "valid test-owned isolation was refused"
VALID_ROOT_ABS=$(fm_treehouse_test_realpath_dir "$VALID_ROOT")
grep -Fx "root = \"$VALID_ROOT_ABS/treehouse-state\"" "$VALID_PROJECT/treehouse.toml" >/dev/null \
  || fail "generated config did not bind the exact test-owned state root"
[ "${TREEHOUSE_NO_UPDATE_CHECK:-}" = 1 ] || fail "prepare did not disable Treehouse update-cache writes"
fm_treehouse_test_isolation_assert "$VALID_ROOT" "$VALID_PROJECT" \
  || fail "fresh isolation binding did not revalidate"
pass "isolation prepare binds project config and state before Treehouse can run"

# The pane-visible shim carries the update-cache suppression into runtime shells.
REAL_STUB="$SCRATCH/real-treehouse"
cat > "$REAL_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TREEHOUSE_NO_UPDATE_CHECK:-unset}"
SH
chmod +x "$REAL_STUB"
OLD_PATH=$PATH
fm_treehouse_test_install_shim "$VALID_ROOT" "$VALID_PROJECT" "$REAL_STUB" \
  || fail "isolated Treehouse shim installation failed"
[ "$(treehouse probe)" = 1 ] || fail "runtime shim did not suppress update-cache writes"
PATH=$OLD_PATH
export PATH
pass "runtime-pane Treehouse wrapper preserves cache isolation"

# Missing, external, ambient-home, and malformed isolation all fail before the
# helper creates state or changes an existing config.
MISSING_ROOT="$SCRATCH/missing"
mkdir -p "$MISSING_ROOT"
if fm_treehouse_test_isolation_prepare "$MISSING_ROOT" "$MISSING_ROOT/no-project" >/dev/null 2>&1; then
  fail "missing project isolation unexpectedly succeeded"
fi
[ ! -e "$MISSING_ROOT/treehouse-state" ] || fail "missing project failure mutated state"

OUTSIDE_ROOT="$SCRATCH/outside-root"
OUTSIDE_PROJECT=$(make_repo "$SCRATCH/outside-owner" project)
mkdir -p "$OUTSIDE_ROOT"
if fm_treehouse_test_isolation_prepare "$OUTSIDE_ROOT" "$OUTSIDE_PROJECT" >/dev/null 2>&1; then
  fail "project outside the exact root unexpectedly succeeded"
fi
[ ! -e "$OUTSIDE_ROOT/treehouse-state" ] || fail "outside-project failure mutated state"
[ ! -e "$OUTSIDE_PROJECT/treehouse.toml" ] || fail "outside-project failure wrote config"

AMBIENT_PROJECT=$(make_repo "$HOME/.treehouse/fixture-root" project)
if fm_treehouse_test_isolation_prepare "$HOME/.treehouse/fixture-root" "$AMBIENT_PROJECT" >/dev/null 2>&1; then
  fail "ambient Treehouse-home isolation unexpectedly succeeded"
fi
[ ! -e "$AMBIENT_PROJECT/treehouse.toml" ] || fail "ambient-home refusal wrote config"
rm -rf "$HOME/.treehouse/fixture-root"

MALFORMED_ROOT="$SCRATCH/malformed"
MALFORMED_PROJECT=$(make_repo "$MALFORMED_ROOT" project)
printf 'root = "/unexpected"\n' > "$MALFORMED_PROJECT/treehouse.toml"
malformed_before=$(shasum -a 256 "$MALFORMED_PROJECT/treehouse.toml" | awk '{print $1}')
if fm_treehouse_test_isolation_prepare "$MALFORMED_ROOT" "$MALFORMED_PROJECT" >/dev/null 2>&1; then
  fail "malformed existing config unexpectedly succeeded"
fi
[ "$malformed_before" = "$(shasum -a 256 "$MALFORMED_PROJECT/treehouse.toml" | awk '{print $1}')" ] \
  || fail "malformed config refusal changed the file"
[ ! -e "$MALFORMED_ROOT/treehouse-state" ] || fail "malformed config refusal created state"
pass "missing and malformed isolation fail before mutation"

# Root cleanup refuses a still-managed worktree and removes only an empty,
# structurally bound task root.
mkdir -p "$VALID_ROOT/treehouse-state/.treehouse/pool"
printf '{"worktrees":[{"path":"owned"}]}\n' > "$VALID_ROOT/treehouse-state/.treehouse/pool/treehouse-state.json"
if fm_treehouse_test_root_cleanup "$VALID_ROOT" >/dev/null 2>&1; then
  fail "root cleanup removed a managed worktree"
fi
[ -d "$VALID_ROOT" ] || fail "refused root cleanup did not preserve evidence"
printf '{"worktrees":[]}\n' > "$VALID_ROOT/treehouse-state/.treehouse/pool/treehouse-state.json"
fm_treehouse_test_root_cleanup "$VALID_ROOT" || fail "empty isolated root cleanup failed"
[ ! -e "$VALID_ROOT" ] || fail "empty isolated root remained"
pass "root cleanup preserves managed state and removes only an empty isolated root"

LIFECYCLE_WORKER="$SCRATCH/lifecycle-worker.sh"
cat > "$LIFECYCLE_WORKER" <<'SH'
#!/usr/bin/env bash
set -u
helper=$1
root=$2
mode=$3
# shellcheck source=tests/treehouse-test-safety.sh
. "$helper"
mkdir -p "$root/project"
git -C "$root/project" init -q
git -C "$root/project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit --allow-empty -qm initial
fm_treehouse_test_isolation_prepare "$root" "$root/project" || exit 90
mkdir -p "$root/treehouse-state/.treehouse/pool"
printf '{"worktrees":[]}\n' > "$root/treehouse-state/.treehouse/pool/treehouse-state.json"
on_exit() {
  status=$?
  fm_treehouse_test_root_cleanup "$root" || status=$?
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'ready\n' > "$root.ready"
case "$mode" in
  normal) exit 0 ;;
  failure) exit 7 ;;
  wait) while :; do sleep 1; done ;;
  *) exit 91 ;;
esac
SH
chmod +x "$LIFECYCLE_WORKER"
HELPER="$REPO_ROOT/tests/treehouse-test-safety.sh"

NORMAL_ROOT="$SCRATCH/lifecycle-normal"
"$LIFECYCLE_WORKER" "$HELPER" "$NORMAL_ROOT" normal || fail "normal lifecycle worker failed"
[ ! -e "$NORMAL_ROOT" ] || fail "normal completion left its isolated root"

FAILURE_ROOT="$SCRATCH/lifecycle-failure"
if "$LIFECYCLE_WORKER" "$HELPER" "$FAILURE_ROOT" failure; then
  fail "command-failure fixture unexpectedly succeeded"
fi
[ ! -e "$FAILURE_ROOT" ] || fail "command failure left its isolated root"
pass "normal completion and command failure converge through isolated cleanup"

SIGNAL_ROOT="$SCRATCH/lifecycle-signal"
"$LIFECYCLE_WORKER" "$HELPER" "$SIGNAL_ROOT" wait &
signal_pid=$!
for _ in $(seq 1 100); do [ -e "$SIGNAL_ROOT.ready" ] && break; sleep 0.01; done
[ -e "$SIGNAL_ROOT.ready" ] || fail "signal worker did not become ready"
kill -TERM "$signal_pid"
if wait "$signal_pid"; then fail "signal worker unexpectedly succeeded"; fi
[ ! -e "$SIGNAL_ROOT" ] || fail "signal interruption left its isolated root"

TIMEOUT_ROOT="$SCRATCH/lifecycle-timeout"
"$LIFECYCLE_WORKER" "$HELPER" "$TIMEOUT_ROOT" wait &
timeout_pid=$!
for _ in $(seq 1 100); do [ -e "$TIMEOUT_ROOT.ready" ] && break; sleep 0.01; done
[ -e "$TIMEOUT_ROOT.ready" ] || fail "timeout worker did not become ready"
sleep 0.05
kill -TERM "$timeout_pid"
if wait "$timeout_pid"; then fail "timeout worker unexpectedly succeeded"; fi
[ ! -e "$TIMEOUT_ROOT" ] || fail "timeout termination left its isolated root"
pass "signal interruption and timeout termination run trap-backed cleanup"

PARALLEL_A="$SCRATCH/lifecycle-parallel-a"
PARALLEL_B="$SCRATCH/lifecycle-parallel-b"
"$LIFECYCLE_WORKER" "$HELPER" "$PARALLEL_A" normal & parallel_a_pid=$!
"$LIFECYCLE_WORKER" "$HELPER" "$PARALLEL_B" normal & parallel_b_pid=$!
wait "$parallel_a_pid" || fail "parallel worker A failed"
wait "$parallel_b_pid" || fail "parallel worker B failed"
[ ! -e "$PARALLEL_A" ] && [ ! -e "$PARALLEL_B" ] \
  || fail "parallel workers shared or retained isolated state"
pass "parallel executions use independent roots and converge cleanly"

ambient_after=$(find "$HOME/.treehouse" -mindepth 1 -maxdepth 2 -print | LC_ALL=C sort)
[ "$ambient_before" = "$ambient_after" ] || fail "ambient Treehouse listing changed"
pass "all lifecycle and refusal paths leave the ambient Treehouse listing unchanged"
