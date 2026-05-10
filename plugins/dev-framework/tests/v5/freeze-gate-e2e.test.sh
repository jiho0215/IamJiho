#!/bin/bash
# freeze-gate-e2e.test.sh
#
# End-to-end: simulate /implement startup + tampered freeze doc; assert that
# freeze-gate.sh halts src/** edits on hash mismatch.
#
# Flow:
#   1. Create a tmp SESSION_DIR (overrides resolve_session_dir via env).
#   2. Author a freeze doc, compute & seal its approvedHash.
#   3. Drop the active-freeze-doc.txt pointer (what /implement startup writes).
#   4. POSITIVE: invoke freeze-gate.sh with a src/** Write; expect exit 0.
#   5. Tamper the freeze doc body (append a section after approval).
#   6. NEGATIVE: invoke freeze-gate.sh again; expect exit 2 + hash-mismatch
#      message on stderr.
#
# This exercises the security-critical contract end-to-end: pointer + status +
# canonical-body sha256 verify, all composed by freeze-gate.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

HOOK="$PLUGIN_ROOT/hooks/scripts/freeze-gate.sh"
HASH_SH="$PLUGIN_ROOT/hooks/scripts/freeze-doc-hash.sh"

[ -f "$HOOK" ] || { echo "FAIL: freeze-gate.sh missing at $HOOK"; exit 1; }
[ -x "$HASH_SH" ] || { echo "FAIL: freeze-doc-hash.sh missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SESSION_DIR="$TMP/session"
mkdir -p "$SESSION_DIR"
touch "$SESSION_DIR/events.jsonl"   # prereqs script reads this; empty is fine

DOC="$TMP/freeze.md"

# --- Step 1: author the freeze doc (status APPROVED, approvedHash placeholder).
# Note: NO §11 Prerequisites section -> prereqs script extracts nothing -> exits 0.
cat > "$DOC" <<'EOF'
---
status: APPROVED
approvedAt: 2026-05-09T12:00:00Z
approvedBy: tester
approvalMode: interactive
approvedHash: null
bypassHistory: []
featureSlug: e2e-test
ticket: e2e-test
---

# Freeze: e2e-test

## §1 Requirements
Body content protected by the canonical-body hash.

## §5 Edge Cases
- empty input
- long input
EOF

# --- Step 2: compute and seal hash.
HASH=$("$HASH_SH" compute "$DOC")
[ -n "$HASH" ] || { echo "FAIL: compute returned empty hash"; exit 1; }

# Cross-platform sed -i (GNU vs BSD on macOS, both available on git-bash/Windows).
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(sed -i)
else
  SED_INPLACE=(sed -i.bak)
fi
"${SED_INPLACE[@]}" "s/approvedHash: null/approvedHash: $HASH/" "$DOC"
rm -f "${DOC}.bak"

# Sanity: hash should verify cleanly now.
"$HASH_SH" verify "$DOC" >/dev/null 2>&1 \
  || { echo "FAIL: pre-tamper hash failed to verify"; exit 1; }

# --- Step 3: simulate /implement startup writing the active-freeze-doc pointer.
echo "$DOC" > "$SESSION_DIR/active-freeze-doc.txt"

# --- Step 4: POSITIVE case — hook should ALLOW src/** Write.
# Use repo-relative path for stable normalization regardless of REPO_ROOT.
INPUT='{"tool_name":"Write","tool_input":{"file_path":"src/test-target.txt"}}'
OUT="$TMP/gate-pos.out"
ERR="$TMP/gate-pos.err"

echo "$INPUT" \
  | DEVFW_TEST_SESSION_DIR="$SESSION_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$HOOK" >"$OUT" 2>"$ERR"
POS_RC=$?
if [ "$POS_RC" -ne 0 ]; then
  echo "FAIL: positive case — freeze-gate exited $POS_RC with valid hash"
  echo "  stdout:"; sed 's/^/    /' "$OUT"
  echo "  stderr:"; sed 's/^/    /' "$ERR"
  exit 1
fi

# --- Step 5: TAMPER — modify body after approval.
cat >> "$DOC" <<'EOF'

## §99 Tampered Section
Attacker-added content; canonical body has changed.
EOF

# Sanity: hash verify should now reject standalone.
if "$HASH_SH" verify "$DOC" >/dev/null 2>&1; then
  echo "FAIL: hash verify accepted tampered body (standalone check)"
  exit 1
fi

# --- Step 6: NEGATIVE case — hook should BLOCK with exit 2 + hash-mismatch msg.
OUT="$TMP/gate-neg.out"
ERR="$TMP/gate-neg.err"

echo "$INPUT" \
  | DEVFW_TEST_SESSION_DIR="$SESSION_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$HOOK" >"$OUT" 2>"$ERR"
NEG_RC=$?

if [ "$NEG_RC" -eq 0 ]; then
  echo "FAIL: negative case — freeze-gate allowed edit on tampered freeze doc"
  echo "  stdout:"; sed 's/^/    /' "$OUT"
  echo "  stderr:"; sed 's/^/    /' "$ERR"
  exit 1
fi

if [ "$NEG_RC" -ne 2 ]; then
  echo "FAIL: negative case expected exit 2 (block), got $NEG_RC"
  echo "  stderr:"; sed 's/^/    /' "$ERR"
  exit 1
fi

if ! grep -qi 'hash mismatch\|modified after approval' "$ERR"; then
  echo "FAIL: gate error message did not mention hash mismatch / modification"
  echo "  stderr was:"
  sed 's/^/    /' "$ERR"
  exit 1
fi

echo "PASS"
