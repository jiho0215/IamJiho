#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../../hooks/scripts/_reducers.sh"

[ -f "$LIB" ] || { echo "FAIL: _reducers.sh not found"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export DEVFW_TEST_SESSION_DIR="$TMP/session"
mkdir -p "$DEVFW_TEST_SESSION_DIR"

# ensure_views_dir creates views/ under session
ensure_views_dir
[ -d "$DEVFW_TEST_SESSION_DIR/views" ] || { echo "FAIL: views dir not created"; exit 1; }

# events_file returns path to events.jsonl
EF=$(events_file)
[ "$EF" = "$DEVFW_TEST_SESSION_DIR/events.jsonl" ] || { echo "FAIL: events_file path wrong ($EF)"; exit 1; }

# read_events with no file returns empty
OUT=$(read_events)
[ -z "$OUT" ] || { echo "FAIL: read_events with missing file not empty"; exit 1; }

# Seed events, check read_events returns them
echo '{"seq":1,"at":"2026-04-20T10:00:00Z","type":"test","data":{}}' > "$EF"
OUT=$(read_events)
[ -n "$OUT" ] || { echo "FAIL: read_events with data empty"; exit 1; }

# atomic_write: write stdin to target atomically
echo "test content" | atomic_write "$TMP/session/target.txt"
[ -f "$TMP/session/target.txt" ] || { echo "FAIL: atomic_write target not created"; exit 1; }
[ "$(cat "$TMP/session/target.txt")" = "test content" ] || { echo "FAIL: atomic_write content mismatch"; exit 1; }

echo "PASS: reducers-lib"
