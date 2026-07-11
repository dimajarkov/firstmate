#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_TEST_PRIMARY_SESSION=${HERDR_SESSION:-}
if [ -z "$HERDR_TEST_PRIMARY_SESSION" ] && command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  HERDR_TEST_PRIMARY_SESSION=$(herdr session list --json --session default 2>/dev/null \
    | jq -er '[.sessions[]? | select(.running == true) | .name] | select(length == 1) | .[0]' 2>/dev/null) \
    || HERDR_TEST_PRIMARY_SESSION=
fi
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_prepare_isolated() { # <session>
  HERDR_SESSION="$HERDR_TEST_PRIMARY_SESSION" fm_herdr_lab_prepare "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
