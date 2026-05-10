#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../hooks/scripts/freeze-doc-prereqs.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: script missing or not executable"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SESSION="$TMP/session"; mkdir -p "$SESSION"
EVENTS="$SESSION/events.jsonl"; touch "$EVENTS"

# Empty prerequisites -> pass
DOC1="$TMP/empty.md"
cat > "$DOC1" <<'EOF'
## §11 Prerequisites

(empty)
EOF
SESSION_DIR="$SESSION" "$SCRIPT" "$DOC1" \
  || { echo "FAIL: empty prereqs should pass"; exit 1; }

# One unmet prerequisite -> fail
DOC2="$TMP/unmet.md"
cat > "$DOC2" <<'EOF'
## §11 Prerequisites

- `pay-foundation-001` — schema must exist
EOF
SESSION_DIR="$SESSION" "$SCRIPT" "$DOC2" 2>/dev/null \
  && { echo "FAIL: unmet prereq should fail"; exit 1; } || true

# Mark merged via event -> pass
echo '{"seq":1,"type":"ticket.merged","data":{"ticketId":"pay-foundation-001"}}' >> "$EVENTS"
SESSION_DIR="$SESSION" "$SCRIPT" "$DOC2" \
  || { echo "FAIL: merged-via-event prereq should pass"; exit 1; }

echo "PASS"
