#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_SH="$SCRIPT_DIR/../../hooks/scripts/freeze-doc-hash.sh"
[ -x "$HASH_SH" ] || { echo "FAIL: freeze-doc-hash.sh not executable or missing"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DOC="$TMP/freeze.md"

cat > "$DOC" <<'EOF'
---
status: APPROVED
approvedAt: 2026-05-09T12:00:00Z
approvedBy: jiho
approvalMode: interactive
approvedHash: null
bypassHistory: []
---

# Freeze: ticket-x

## §1 Requirements
Body content here.
EOF

# Compute -> hash should be non-empty deterministic
H1=$("$HASH_SH" compute "$DOC")
[ -n "$H1" ] || { echo "FAIL: compute returned empty"; exit 1; }
H2=$("$HASH_SH" compute "$DOC")
[ "$H1" = "$H2" ] || { echo "FAIL: compute not deterministic"; exit 1; }

# Verify against null-hash -> should be mismatch
"$HASH_SH" verify "$DOC" 2>/dev/null && { echo "FAIL: verify accepted null hash"; exit 1; } || true

# Set hash, verify -> match
sed -i.bak "s/approvedHash: null/approvedHash: $H1/" "$DOC"
"$HASH_SH" verify "$DOC" || { echo "FAIL: verify rejected matching hash"; exit 1; }

# Mutate body -> mismatch
echo "extra line" >> "$DOC"
"$HASH_SH" verify "$DOC" 2>/dev/null && { echo "FAIL: verify accepted mutated body"; exit 1; } || true

# Mutate bypassHistory only -> still matches (bypassHistory excluded from canonical)
cat > "$DOC" <<'EOF'
---
status: APPROVED
approvedAt: 2026-05-09T12:00:00Z
approvedBy: jiho
approvalMode: interactive
approvedHash: PLACEHOLDER
bypassHistory: [{ts: "2026-05-09T13:00:00Z", reason: "x"}]
---

# Freeze: ticket-x

## §1 Requirements
Body content here.
EOF
sed -i.bak "s/approvedHash: PLACEHOLDER/approvedHash: $H1/" "$DOC"
"$HASH_SH" verify "$DOC" || { echo "FAIL: bypassHistory mutation should not affect hash"; exit 1; }

echo "PASS"
