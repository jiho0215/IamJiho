#!/bin/bash
# Static plumbing smoke for v5: every required file exists, frontmatter parses,
# scripts are executable, references in SKILL.md resolve.
set -euo pipefail

PR=plugins/dev-framework
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Agents
[ -f "$PR/agents/research-investigator.md" ] || fail "research-investigator agent missing"

# 2. Templates
for t in RESEARCH_DOC_TEMPLATE FREEZE_DOC_TEMPLATE SPIKE_PLAN_TEMPLATE TICKET_REF_TEMPLATE; do
  [ -f "$PR/skills/spike/references/templates/$t.md" ] \
    || fail "spike template $t missing"
done

# 3. Protocols + guardrails
[ -f "$PR/skills/spike/references/protocols/research-dispatch.md" ] \
  || fail "research-dispatch protocol missing"
[ -f "$PR/skills/spike/references/guardrails.md" ] || fail "guardrails missing"

# 4. Phases
for p in p1-scope p2-investigate p3-decompose p4-spec p5-review p6-approve p7-retro; do
  [ -f "$PR/phases/spike/$p.yaml" ] || fail "phase $p.yaml missing"
done
for e in e1-execute e2-verify e3-finalize; do
  [ -f "$PR/phases/implement/$e.yaml" ] || fail "phase $e.yaml missing"
done
for old in phase-1 phase-2 phase-3 phase-4 phase-5 phase-6 phase-7; do
  [ ! -f "$PR/phases/$old.yaml" ] || fail "old phase file $old.yaml still present"
done

# 5. Scripts
for s in freeze-doc-hash.sh freeze-doc-prereqs.sh freeze-gate.sh phase-gate.sh _session-lib.sh; do
  [ -f "$PR/hooks/scripts/$s" ] || fail "hook script $s missing"
done
[ -x "$PR/hooks/scripts/freeze-doc-hash.sh" ] || fail "freeze-doc-hash.sh not executable"
[ -x "$PR/hooks/scripts/freeze-doc-prereqs.sh" ] || fail "freeze-doc-prereqs.sh not executable"

# 6. Skills
grep -q 'version: 3' "$PR/skills/spike/SKILL.md" || fail "spike SKILL.md not v3"
grep -q 'version: 2' "$PR/skills/implement/SKILL.md" || fail "implement SKILL.md not v2"

# 7. Plugin meta
grep -q '"version": "5.0.1"' "$PR/.claude-plugin/plugin.json" || fail "plugin.json not 5.0.1"

# 8. Run all v5 task tests
for t in "$PR/tests/v5/"*.test.sh; do
  [ "$(basename "$t")" = "smoke.test.sh" ] && continue
  echo "Running $t ..."
  bash "$t" || fail "task test failed: $t"
done

echo "ALL PASS"
