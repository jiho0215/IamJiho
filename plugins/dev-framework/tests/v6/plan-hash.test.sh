#!/bin/bash
# plan-hash: stable per-item content hashes (CRLF, ticket:, whitespace) that move only for the edited item.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PH="$DIR/../../bin/plan-hash"
FIX="$DIR/fixtures/PLAN.md"
[ -x "$PH" ] || { echo "FAIL: bin/plan-hash missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

BASE=$("$PH" "$FIX")
[ "$(echo "$BASE" | wc -l)" -eq 3 ] || { echo "FAIL: expected 3 lines, got: $BASE"; exit 1; }
[ "$(echo "$BASE" | awk '{print $1}' | tr '\n' ' ')" = "D-3 P-core-1 P-core-2 " ] \
  || { echo "FAIL: ids/order wrong: $BASE"; exit 1; }
echo "$BASE" | awk '{ if ($2 !~ /^[0-9a-f]{12}$/) exit 1 }' || { echo "FAIL: hash not 12 hex"; exit 1; }

# CRLF copy hashes identically
sed 's/$/\r/' "$FIX" > "$TMP/crlf.md"
[ "$("$PH" "$TMP/crlf.md")" = "$BASE" ] || { echo "FAIL: CRLF changed hashes"; exit 1; }

# ticket: churn does not move the hash
sed 's|acme/core#41|acme/core#99|' "$FIX" > "$TMP/ticket.md"
[ "$("$PH" "$TMP/ticket.md")" = "$BASE" ] || { echo "FAIL: ticket: change moved a hash"; exit 1; }

# whitespace-only edits do not move hashes
sed 's|^Return the same error|    Return   the same error|; s|minute\.$|minute.   |' "$FIX" > "$TMP/ws.md"
[ "$("$PH" "$TMP/ws.md")" = "$BASE" ] || { echo "FAIL: whitespace change moved a hash"; exit 1; }

# discriminating: one word in P-core-1 moves only P-core-1
sed 's|5 per minute|6 per minute|' "$FIX" > "$TMP/word.md"
NEW=$("$PH" "$TMP/word.md")
[ "$(echo "$NEW" | grep '^P-core-1 ')" != "$(echo "$BASE" | grep '^P-core-1 ')" ] \
  || { echo "FAIL: body edit did not move P-core-1"; exit 1; }
[ "$(echo "$NEW" | grep -v '^P-core-1 ')" = "$(echo "$BASE" | grep -v '^P-core-1 ')" ] \
  || { echo "FAIL: body edit moved other items"; exit 1; }

# missing file
set +e; "$PH" "$TMP/missing.md" 2>/dev/null; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: missing file exit $rc, want 2"; exit 1; }
echo "ok"
