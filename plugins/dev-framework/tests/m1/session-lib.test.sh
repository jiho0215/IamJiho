#!/bin/bash
# Verify _session-lib.sh helpers behave correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../../hooks/scripts/_session-lib.sh"

[ -f "$LIB" ] || { echo "FAIL: _session-lib.sh not found at $LIB"; exit 1; }

# shellcheck disable=SC1090
. "$LIB"

# sanitize_branch
[ "$(sanitize_branch 'feature/auth-flow')" = "feature-auth-flow" ] \
  || { echo "FAIL: sanitize_branch slash"; exit 1; }
[ "$(sanitize_branch 'foo@bar:baz')" = "foo-bar-baz" ] \
  || { echo "FAIL: sanitize_branch special chars"; exit 1; }
[ "$(sanitize_branch 'trailing...')" = "trailing" ] \
  || { echo "FAIL: sanitize_branch trailing dots"; exit 1; }

# iso_utc format (must match ^YYYY-MM-DDTHH:MM:SSZ$)
ts=$(iso_utc)
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || { echo "FAIL: iso_utc format ($ts)"; exit 1; }

# cfg fallback (nonexistent config file -> should return default)
export DEVFW_CONFIG="/tmp/nonexistent-devfw-$$.json"
[ "$(cfg '.any.key' 'fallback')" = "fallback" ] \
  || { echo "FAIL: cfg fallback"; exit 1; }

# resolve_session_dir returns non-empty absolute path
sd=$(resolve_session_dir)
[ -n "$sd" ] || { echo "FAIL: resolve_session_dir empty"; exit 1; }
[[ "$sd" == /* ]] || [[ "$sd" =~ ^[A-Za-z]: ]] \
  || { echo "FAIL: resolve_session_dir not absolute ($sd)"; exit 1; }

# DEVFW_TEST_SESSION_DIR override takes priority
export DEVFW_TEST_SESSION_DIR="/tmp/override-test-$$"
override=$(resolve_session_dir)
[ "$override" = "$DEVFW_TEST_SESSION_DIR" ] \
  || { echo "FAIL: DEVFW_TEST_SESSION_DIR override (got $override)"; exit 1; }
unset DEVFW_TEST_SESSION_DIR

echo "PASS: session-lib helpers"
