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

# Field-order tolerance: ticketId before type in the JSON object should still match.
DOC3="$TMP/order.md"
cat > "$DOC3" <<'EOF'
## §11 Prerequisites

- `order-flip-002` -- type field comes second in the JSON
EOF
echo '{"seq":2,"data":{"ticketId":"order-flip-002"},"type":"ticket.merged"}' >> "$EVENTS"
SESSION_DIR="$SESSION" "$SCRIPT" "$DOC3" \
  || { echo "FAIL: ticketId-before-type should still match (field-order tolerance)"; exit 1; }

# Regex-meta-character safety: ticket id with '.' must not false-positive on
# similar ids that have other characters where the dot is.
DOC4="$TMP/dot.md"
cat > "$DOC4" <<'EOF'
## §11 Prerequisites

- `v1.2.3-pay` -- dotted version-style ticket id
EOF
EVENTS2="$SESSION/events2.jsonl"
SESSION2="$TMP/session2"; mkdir -p "$SESSION2"
EVENTS_DOTTED="$SESSION2/events.jsonl"
# Emit a ticket.merged for a similar id (`v1X2X3-pay`) only — the dotted one
# must NOT match this if `.` is treated literally.
echo '{"seq":1,"type":"ticket.merged","data":{"ticketId":"v1X2X3-pay"}}' >> "$EVENTS_DOTTED"
SESSION_DIR="$SESSION2" "$SCRIPT" "$DOC4" 2>/dev/null \
  && { echo "FAIL: dotted id must not match similar id with other chars"; exit 1; } || true

# Now add the real merge event and confirm it passes.
echo '{"seq":2,"type":"ticket.merged","data":{"ticketId":"v1.2.3-pay"}}' >> "$EVENTS_DOTTED"
SESSION_DIR="$SESSION2" "$SCRIPT" "$DOC4" \
  || { echo "FAIL: dotted id should match its own ticket.merged event"; exit 1; }

echo "PASS"
