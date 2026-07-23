#!/usr/bin/env bash
# Narrow cleanup helpers for real-Treehouse tests that create temporary Git
# repositories.
#
# A returned worktree remains in its reusable pool.
# Tests must destroy that test-owned pool before deleting the temporary backing
# repository, or the pool becomes an orphan that ordinary cleanup cannot safely
# identify afterward.
#
# fm_treehouse_test_pool_cleanup <test-temp-root> <temporary-project>
# validates that the project is owned by the test root, resolves its pool only
# through `treehouse status` from that exact project, refuses leased or running
# worktrees, verifies every worktree's Git common directory against the exact
# temporary repository, returns each worktree, destroys only that one pool, and
# verifies that no worktrees remain.

fm_treehouse_test_realpath_dir() { # <existing-directory>
  (cd "$1" 2>/dev/null && pwd -P)
}

fm_treehouse_test_common_dir() { # <worktree>
  local worktree=$1 common
  common=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) fm_treehouse_test_realpath_dir "$common" ;;
    *) fm_treehouse_test_realpath_dir "$worktree/$common" ;;
  esac
}

fm_treehouse_test_pool_cleanup() { # <test-temp-root> <temporary-project>
  local test_root=${1:-} project=${2:-} root_abs project_abs project_git
  local status wt common pool='' candidate slot state_status process_count after

  [ -n "$test_root" ] && [ -n "$project" ] || return 0
  [ -d "$test_root" ] && [ -d "$project/.git" ] || return 0
  command -v treehouse >/dev/null 2>&1 || {
    echo "treehouse test cleanup: treehouse is required" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "treehouse test cleanup: jq is required" >&2
    return 1
  }

  root_abs=$(fm_treehouse_test_realpath_dir "$test_root") || return 1
  project_abs=$(fm_treehouse_test_realpath_dir "$project") || return 1
  case "$project_abs" in
    "$root_abs"/*) ;;
    *)
      echo "treehouse test cleanup: refusing project outside the exact test root: $project_abs" >&2
      return 1
      ;;
  esac
  project_git=$(fm_treehouse_test_realpath_dir "$project_abs/.git") || return 1

  status=$(cd "$project_abs" && treehouse status --json) || {
    echo "treehouse test cleanup: could not inspect the exact temporary project" >&2
    return 1
  }
  printf '%s' "$status" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    echo "treehouse test cleanup: unexpected Treehouse status response" >&2
    return 1
  }
  [ "$(printf '%s' "$status" | jq 'length')" -gt 0 ] || return 0

  while IFS=$'\t' read -r wt state_status process_count; do
    [ -n "$wt" ] && [ -d "$wt" ] || {
      echo "treehouse test cleanup: status named a missing worktree" >&2
      return 1
    }
    case "$wt" in
      /*) ;;
      *)
        echo "treehouse test cleanup: status named a non-absolute worktree" >&2
        return 1
        ;;
    esac
    [ "$state_status" != leased ] || {
      echo "treehouse test cleanup: refusing leased worktree $wt" >&2
      return 1
    }
    [ "$process_count" -eq 0 ] || {
      echo "treehouse test cleanup: refusing worktree with running processes $wt" >&2
      return 1
    }
    common=$(fm_treehouse_test_common_dir "$wt") || {
      echo "treehouse test cleanup: could not resolve Git ownership for $wt" >&2
      return 1
    }
    [ "$common" = "$project_git" ] || {
      echo "treehouse test cleanup: refusing worktree not owned by $project_abs: $wt" >&2
      return 1
    }
    candidate=$(dirname "$(dirname "$wt")")
    [ -f "$candidate/treehouse-state.json" ] || {
      echo "treehouse test cleanup: refusing path without exact pool state: $candidate" >&2
      return 1
    }
    slot=$(basename "$(dirname "$wt")")
    case "$slot" in
      ''|*[!0-9]*)
        echo "treehouse test cleanup: refusing unexpected pool slot for $wt" >&2
        return 1
        ;;
    esac
    if [ -n "$pool" ] && [ "$candidate" != "$pool" ]; then
      echo "treehouse test cleanup: refusing multiple pools for one temporary project" >&2
      return 1
    fi
    pool=$candidate
  done < <(printf '%s' "$status" | jq -r '.[] | [.path, .status, ((.processes // []) | length)] | @tsv')

  [ -n "$pool" ] || {
    echo "treehouse test cleanup: could not resolve the owned pool" >&2
    return 1
  }

  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    (cd "$project_abs" && treehouse return --force "$wt") >/dev/null || {
      echo "treehouse test cleanup: could not return owned worktree $wt" >&2
      return 1
    }
  done < <(printf '%s' "$status" | jq -r '.[].path')

  after=$(cd "$project_abs" && treehouse status --json) || return 1
  while IFS=$'\t' read -r wt state_status process_count; do
    [ -n "$wt" ] || continue
    [ "$state_status" != leased ] && [ "$process_count" -eq 0 ] || {
      echo "treehouse test cleanup: owned worktree did not become idle after return: $wt" >&2
      return 1
    }
    common=$(fm_treehouse_test_common_dir "$wt") || return 1
    [ "$common" = "$project_git" ] || {
      echo "treehouse test cleanup: ownership changed before pool destroy: $wt" >&2
      return 1
    }
    candidate=$(dirname "$(dirname "$wt")")
    [ "$candidate" = "$pool" ] || {
      echo "treehouse test cleanup: pool identity changed before destroy" >&2
      return 1
    }
  done < <(printf '%s' "$after" | jq -r '.[] | [.path, .status, ((.processes // []) | length)] | @tsv')

  treehouse destroy "$pool" --all --yes >/dev/null || {
    echo "treehouse test cleanup: exact owned pool destroy failed: $pool" >&2
    return 1
  }
  after=$(cd "$project_abs" && treehouse status --json) || return 1
  printf '%s' "$after" | jq -e 'type == "array" and length == 0' >/dev/null 2>&1 || {
    echo "treehouse test cleanup: owned pool still contains worktrees after destroy: $pool" >&2
    return 1
  }
}
