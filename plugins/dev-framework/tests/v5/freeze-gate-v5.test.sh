#!/bin/bash
set -euo pipefail
HOOK="plugins/dev-framework/hooks/scripts/freeze-gate.sh"
LIB="plugins/dev-framework/hooks/scripts/_session-lib.sh"

[ -f "$HOOK" ] || { echo "FAIL: freeze-gate missing"; exit 1; }
grep -q 'active-freeze-doc.txt' "$HOOK" \
  || { echo "FAIL: freeze-gate does not read active pointer"; exit 1; }
grep -q 'freeze-doc-hash.sh' "$HOOK" \
  || { echo "FAIL: freeze-gate does not invoke hash verify"; exit 1; }
grep -q 'freeze-doc-prereqs.sh' "$HOOK" \
  || { echo "FAIL: freeze-gate does not invoke prereq check"; exit 1; }
grep -q 'resolve_active_freeze_doc' "$LIB" \
  || { echo "FAIL: _session-lib helper missing"; exit 1; }
echo "PASS"
