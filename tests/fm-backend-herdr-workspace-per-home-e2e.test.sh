#!/usr/bin/env bash
# Compatibility entry point retained for callers of the prior E2E filename.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend-herdr-task-workspaces-e2e.test.sh" "$@"
