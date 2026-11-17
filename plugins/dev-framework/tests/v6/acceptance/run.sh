#!/bin/bash
# Acceptance runner (needs the network; writes only to the sandbox repos). Not part of tests/v6/run.sh.
#   run.sh          run every acceptance/*.accept.mjs and compare with expected.json
#   run.sh --init   one-time: commit the DEVFW_SANDBOX marker (listing the code repo) to the sandbox core repo's main
# Exit: 0 every scenario matches expected.json, 1 a mismatch, 2 sandbox/env guard.
# DEVFW_ACCEPT_DIR (tests only) points the runner at another dir of *.accept.mjs + expected.json.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN="${DEVFW_ACCEPT_DIR:-$DIR}"
command -v cygpath >/dev/null 2>&1 && SCEN="$(cygpath -m "$SCEN")"
if [ -z "${DEVFW_SANDBOX_CORE:-}" ] || [ -z "${DEVFW_SANDBOX_CODE:-}" ]; then
  echo "run.sh: set DEVFW_SANDBOX_CORE and DEVFW_SANDBOX_CODE (owner/name of the sandbox repos)" >&2
  exit 2
fi
if [ "${1:-}" = "--init" ]; then
  node "$DIR/harness.mjs" --init; exit $?
fi

TAP="$(mktemp)"; command -v cygpath >/dev/null 2>&1 && TAP="$(cygpath -m "$TAP")"; trap 'rm -f "$TAP"' EXIT
node --test --test-concurrency=1 --test-timeout=300000 --test-reporter=tap "$SCEN"/*.accept.mjs >"$TAP" 2>&1
node "$DIR/tap-report.mjs" "$TAP" "$SCEN/expected.json"
exit $?
