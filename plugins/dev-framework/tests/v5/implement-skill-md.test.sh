#!/bin/bash
set -euo pipefail
F="plugins/dev-framework/skills/implement/SKILL.md"
[ -f "$F" ] || { echo "FAIL: SKILL.md missing"; exit 1; }
! grep -qE "Phase 1|Phase 2|Phase 3|Phase 4" "$F" \
  || { echo "FAIL: old Phase 1-4 references still present"; exit 1; }
for p in "E1 Execute" "E2 Verify" "E3 Finalize"; do
  grep -qF "$p" "$F" || { echo "FAIL: phase '$p' missing"; exit 1; }
done
for kw in "freeze-doc-path" "approvedHash" "Prerequisites" "active-freeze-doc.txt"; do
  grep -qF "$kw" "$F" || { echo "FAIL: keyword '$kw' missing"; exit 1; }
done
echo "PASS"
