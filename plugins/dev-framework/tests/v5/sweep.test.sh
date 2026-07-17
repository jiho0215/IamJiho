#!/bin/bash
# Final sweep test: confirms v4 leftovers are gone and v5 docs are aligned.
set -euo pipefail

PR=plugins/dev-framework
fail() { echo "FAIL: $*" >&2; exit 1; }

# A. FEATURE_SPEC_TEMPLATE removed from implement
[ ! -f "$PR/skills/implement/references/templates/FEATURE_SPEC_TEMPLATE.md" ] \
  || fail "FEATURE_SPEC_TEMPLATE still in implement"

# B. README updated for v5 (if present)
README="$PR/README.md"
if [ -f "$README" ]; then
  grep -qE 'v5\.|5\.0|universal planning' "$README" \
    || fail "README not updated for v5"
fi

# C1. No leftover v4 FREEZE_DOC_TEMPLATE path under implement skill or phases
#     (CLAUDE.md should now point to spike/references/templates/)
if grep -r 'skills/implement/references/templates/FREEZE_DOC_TEMPLATE' \
    "$PR/skills/" "$PR/phases/" 2>/dev/null | grep -v '^Binary' | grep -q '.'; then
  fail "stale FREEZE_DOC_TEMPLATE path in skills/phases"
fi

# C2. phases/implement/e*.yaml skillMdSection points to E1/E2/E3, not v4 Phase 5/6/7
for f in "$PR/phases/implement/e1-execute.yaml" \
         "$PR/phases/implement/e2-verify.yaml" \
         "$PR/phases/implement/e3-finalize.yaml"; do
  grep -E '^skillMdSection: "E[123] ' "$f" >/dev/null \
    || fail "$f skillMdSection not updated to E1/E2/E3"
done

# C3. DEVELOPMENT_CYCLE.md FREEZE_DOC_TEMPLATE refs point to spike location
DC="$PR/skills/implement/references/methodology/DEVELOPMENT_CYCLE.md"
if [ -f "$DC" ]; then
  if grep -q 'FREEZE_DOC_TEMPLATE' "$DC"; then
    grep -qE '\.\./\.\./\.\./spike/references/templates/FREEZE_DOC_TEMPLATE\.md|skills/spike/references/templates/FREEZE_DOC_TEMPLATE\.md' "$DC" \
      || fail "DEVELOPMENT_CYCLE.md FREEZE_DOC_TEMPLATE ref not updated to spike path"
  fi
fi

# D. Spec §5 step order — SESSION_DIR resolves before §11 Prerequisites verify
SPEC="docs/specs/2026-05-09-spike-as-planning-skill.md"
if [ -f "$SPEC" ]; then
  # Within §5 startup-checks block, the line for "Resolve SESSION_DIR" must
  # appear before "Verify §11 Prerequisites" (i.e., SESSION_DIR ordinal < §11 ordinal).
  SESSDIR_LINE=$(grep -n 'Resolve \*\*SESSION_DIR\*\*\|Resolve `SESSION_DIR`\|Resolve SESSION_DIR' "$SPEC" | head -1 | cut -d: -f1)
  # -F, not a '.' wildcard: § is two bytes, so '.' matched only half of it and this
  # grep always came up empty — which killed the test under set -e + pipefail.
  PREREQ_LINE=$(grep -nF 'Verify §11 Prerequisites' "$SPEC" | head -1 | cut -d: -f1)
  if [ -n "${SESSDIR_LINE:-}" ] && [ -n "${PREREQ_LINE:-}" ]; then
    [ "$SESSDIR_LINE" -lt "$PREREQ_LINE" ] \
      || fail "spec §5 step order not amended (SESSION_DIR must precede §11 Prerequisites)"
  fi
fi

echo "PASS"
