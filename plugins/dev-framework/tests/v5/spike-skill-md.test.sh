#!/bin/bash
set -euo pipefail
F="plugins/dev-framework/skills/spike/SKILL.md"
[ -f "$F" ] || { echo "FAIL: SKILL.md missing"; exit 1; }
! grep -q "Phase 0" "$F" || { echo "FAIL: Phase 0 still present"; exit 1; }
for kw in "Epic mode" "Story mode" "Research mode"; do
  grep -qF "$kw" "$F" || { echo "FAIL: keyword '$kw' missing"; exit 1; }
done
for ref in "research-dispatch.md" "FREEZE_DOC_TEMPLATE" "RESEARCH_DOC_TEMPLATE" "guardrails.md"; do
  grep -qF "$ref" "$F" || { echo "FAIL: ref '$ref' missing"; exit 1; }
done
for p in "P1 Scope" "P2 Investigate" "P3 Decompose" "P4 Spec" "P5 Review" "P6 Approve" "P7 Retro"; do
  grep -qF "$p" "$F" || { echo "FAIL: phase '$p' missing"; exit 1; }
done
grep -q "approvedHash" "$F" || { echo "FAIL: approvedHash mention missing"; exit 1; }
echo "PASS"
