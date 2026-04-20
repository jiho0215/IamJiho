# Design: Unified `/dev` Workflow — Level 3 Full Integration + Freeze Doc

**Date:** 2026-04-19
**Status:** Approved (user confirmed full integration scope)
**Scope:** Consolidate `/dev` and `/dev-pipeline` into a single skill. Absorb all sibling skills (multi-agent-consensus, project-docs, test-planning) as internal protocol references. Introduce freeze doc artifact and two-gate user approval flow. Unify all review iteration limits (10/2). No duplication anywhere.

---

## 1. Background & Motivation

### The problem

1. **Duplicate entry points.** `/dev` (interactive) and `/dev-pipeline` (autonomous) exist as peer commands with overlapping phase semantics but different quality bars. Users must choose between them and switch mental models.
2. **Fragmented skill layer.** `multi-agent-consensus`, `project-docs`, `test-planning` are peer skills alongside `dev` but are only meaningful as internals of the development workflow. This creates a false impression of five separable skills when there is one workflow.
3. **Implicit research-execution boundary.** Pre-execution research and execution are mixed in one workflow. Small-picture decisions (status enum options, 3rd-party API payload/rate-limit/cache, DB schema choices) leak into implementation phases as mid-coding questions.
4. **No artifact for "research done."** Decisions made during Phase 1-3 are not captured in a single consolidated document, so Phase 5+ agents re-interpret or forget them.
5. **No enforcement.** Even when the user approves at Phase 3, nothing physically prevents writing code before approval or changing frozen decisions mid-execution. Same for push — the user's final approval is not connected to push authorization.
6. **Inconsistent review depth.** `/dev` hardcodes `max_iterations: 5`; `/dev-pipeline` and the underlying consensus protocol default to `10 / 2`. Same reviewers, same artifact — different depth.

### Philosophy (user's stated principles)

> The plugin has one purpose: AI leads development end-to-end; the user answers questions, discusses, confirms, and completes. All skills and hooks exist for this single workflow.
>
> Never leave duplicates.

Translating:

- One command. One skill. One SKILL.md. One config init script. One session-state location.
- Research ends when the workflow transitions from "planning" to "execution." At that transition, all decisions (big and small) required to execute must be captured in a single artifact. The ticket (if any) is just the initial requirement source; whether it exists at the start is immaterial.
- User approval is a **physical artifact** (file state), not a verbal exchange.
- Review depth is uniform across all invocations of the workflow.

### Ticket origin is irrelevant

A ticket may originate from:
1. A business requirement handed to the developer.
2. A troubleshooting path: problem → research → plan → ticket (ticket is an *output* of early work, not an input).

Either way, the workflow is the same. What matters is that by end of Phase 3, all decisions required to execute are frozen.

---

## 2. Unified `/dev` Workflow

### 2.1 Single command, multiple modes

```
/dev [feature description]        Interactive full cycle (default)
/dev --autonomous TICKET-123       Autonomous full cycle
/dev --from N                      Resume at phase N (interactive or autonomous)
/dev --status                      Show current pipeline status
/dev init                          Initialize new project
/dev review                        Standalone review workflow
/dev test                          Standalone test strategy workflow
/dev docs                          Standalone documentation workflow
```

No `/dev-pipeline` command. Autonomous mode is a `/dev` mode.

### 2.2 Seven unified phases (full cycle)

```
Phase 1: Requirements (interactive always)
  populates freeze doc: §1 Business Logic, §5 Error Model, §6 Acceptance Criteria

Phase 2: Research (interactive; codebase exploration + architecture)
  populates freeze doc: §2 API Contracts, §3 3rd Party, §4 Data,
                       §7 Security, §8 Performance

Phase 3: Plan + Freeze Doc Assembly (interactive)
  assembles complete freeze doc
  🚪 GATE 1: user reviews freeze doc by category; approves
  In autonomous mode, GATE 1 is skipped — freeze doc is written APPROVED automatically
  with audit note, but frozen-category enforcement still applies.

[freeze-gate hook ACTIVE — src/** edits blocked unless freeze doc APPROVED]

Phase 4: Test Planning (autonomous)
  layered test plan (Layer 0/1/2, event-type grouping)

Phase 5: Implementation + Layer 1 Review (autonomous)
  TDD implementation + multi-agent consensus validate (code-quality,
  observability, performance). 10 max iterations, 2 consecutive zero exit.

Phase 6: Verification + Coverage Fill + Layer 2 Review (autonomous)
  full test run, coverage fill to target, multi-agent consensus validate.
  10 max iterations, 2 consecutive zero exit.

Phase 7: Documentation + Mistake Capture (autonomous)
  update ADRs, specs, test docs; run mistake tracker pattern aggregation.
  🚪 GATE 2: user reviews review summary + final state, approves.
  On approval: authorize push via completion marker.

[push-guard hook — blocks git push until GATE 2 approved]
```

Dev-pipeline's former Phases 1-10 map:
- p1 → Phase 1
- p2 → Phase 2 (codebase exploration part)
- p3 → Phase 2 + Phase 3 (architecture + plan)
- p4 → Phase 4
- p5 → Phase 5
- p6 → Phase 5 (Layer 1 review, same loop)
- p7 → Phase 6 (coverage fill)
- p8 → Phase 6 (Layer 2 review, same loop)
- p9 → Phase 7 (mistake capture)
- p10 → Phase 7 (final gate)

### 2.3 Zone-based execution rules (Phase 4-7)

| Zone | Description | LLM behavior |
|---|---|---|
| 🛑 **Frozen** | Would change a decision in freeze doc §1-§8 | HALT + notify "ticket update required" |
| ✅ **Non-Frozen** | In allow-list (observability, railroad-composition, pure-function-composition, plus config extensions) | May ask user |
| 🤔 **Ambiguous** | Technical question not covered above | Apply 4-tier context rule (§2.4) |
| ⚙️ **Self-decide** | Pure technical (naming, extraction, internal module boundaries) | No question — decide using standards and context |

### 2.4 Ambiguous question 4-tier rule

```
Is there related code in THIS repo?
├─ YES → Follow existing patterns (silent)
│         └─ Pattern seems wrong or deviation needed?
│             ├─ YES → Ask with suggestion (format below)
│             └─ NO  → Proceed silently
└─ NO  → Did user provide reference/example repo?
         ├─ YES → Same branch as "repo has related code"
         └─ NO  → Is this an initial implementation (totally new area)?
                  ├─ YES → Ask many questions (no anchor — need user intent)
                  └─ NO  → Self-decide using standards/
```

### 2.5 "Ask with suggestion" format (mandatory)

```
📋 Context: [observed existing pattern or reference]
🔍 Observation: [why this case seems to need deviation]
💡 Proposal: [proposed alternative with reasoning]
❓ Decision needed: [concrete question for user]
```

---

## 3. Freeze Doc

### 3.1 File location

`docs/specs/[feature-slug]-freeze.md` — repo-local. `[feature-slug]` is derived by the orchestrator from the feature description or ticket title.

### 3.2 Frontmatter

```yaml
---
feature: [feature-slug]
status: DRAFT | PENDING_APPROVAL | APPROVED | SUPERSEDED
createdAt: 2026-04-19T10:00:00Z
approvedAt: null
approvedBy: null
approvalMode: interactive | autonomous
bypassHistory: []           # list of { at, reason, feature, userMessage, runId, preservedAt? }
supersededBy: null          # path to replacement freeze doc
frozenCategories:
  - business-logic
  - api-contracts
  - third-party
  - data
  - error-model
  - acceptance-criteria
  - security
  - performance
nonFrozenAllowList:
  - observability
  - railroad-composition
  - pure-function-composition
customCategories: []        # populated from config at render time
---
```

`BYPASSED` is **not** a status — bypass is a transient override recorded in `bypassHistory`. The freeze doc remains APPROVED (or DRAFT if bypass occurred before approval).

> **Implementation erratum:** the `bypassHistory` entry schema in the implementation is `{ at, reason, feature, userMessage, runId, preservedAt? }`. The `at` field derives from `bypass.json.createdAt` (which uses the format `<ISO UTC>-<4 hex>` for uniqueness). `runId` is injected at merge time from `progress-log.json`. `preservedAt` is present only for entries archived via `bypass-audit.jsonl` (crash-preservation path). See `skills/dev/references/templates/FREEZE_DOC_TEMPLATE.md` Rendering Notes for the authoritative description.

### 3.3 Body structure (8 required categories)

See Appendix A for full section-by-section templates. Summary:

- **§ 1. Business Logic** — domain rules, decision flows, validation rules.
- **§ 2. API Contracts (Internal)** — internal endpoints, request/response schemas. Rule: follow existing repo conventions first; document deviations explicitly with rationale in a "Proposed Deviations" subsection.
- **§ 3. 3rd Party Integrations** — external API payload, rate limit, retry, cache.
- **§ 4. Data & Database** — schema changes, enums, migrations, backfills (single category — always decided together).
- **§ 5. Error Model** — error codes, user-facing messages, recovery paths.
- **§ 6. Acceptance Criteria** — testable checkbox items.
- **§ 7. Security / Auth** — authZ model, sensitive data handling, threat surface.
- **§ 8. Performance** — SLA, throughput, resource budgets.
- **§ 9. Non-Frozen Questions** — Zone rules (references §1-§8 and allow-list).

### 3.4 Category extensibility

Categories and allow-list live in `~/.claude/autodev/config.json`:

```json
{
  "pipeline": {
    "freezeDoc": {
      "categories": [
        "business-logic", "api-contracts", "third-party",
        "data", "error-model", "acceptance-criteria",
        "security", "performance"
      ],
      "nonFrozenAllowList": [
        "observability", "railroad-composition",
        "pure-function-composition"
      ],
      "customCategoryTemplatesDir": "~/.claude/autodev/freeze-categories/"
    }
  }
}
```

Adding a new category (e.g., `migration-safety`):
1. Append to `categories` array.
2. Create `~/.claude/autodev/freeze-categories/migration-safety.md` (section template).
3. Next `/dev` run renders it.

SKILL.md renders sections by iterating this array. No hardcoded 8-category list in SKILL.md.

---

## 4. User Gates

### 4.1 GATE 1 — Freeze Doc Approval (end of Phase 3)

**Interactive mode:**

Present freeze doc to user with:
- Each of the 8 required categories, rendered.
- Category-level validity indicator (green if all decisions populated; yellow if any `Open Questions` remain).
- Options:
  - `[1] Approve all` → `status: APPROVED` with `approvalMode: interactive`, grant src/** write permission.
  - `[2] Reject category X` → reopen that category (return to Phase 1 or 2 depending on which).
  - `[3] Inline edit` → modify specific items, re-review.

On approval:
- Set freeze doc `status: APPROVED`, record `approvedAt` (UTC) and `approvedBy`.
- Record `freezeDocPath`, `plannedFiles`, and `branch` in session `progress-log.json`.
- Append APPROVED decision to `decision-log.json` (category: "gate-1"; gate-2 is reserved for Phase 7 GATE 2 failures).

**Autonomous mode:**

- Freeze doc is written and immediately `status: APPROVED` with `approvalMode: autonomous`.
- Append a decision-log entry explaining autonomous approval (user invoked `--autonomous`).
- Frozen-category enforcement still applies during Phase 4-7; Phase 7 GATE 2 is still user-interactive.

### 4.2 GATE 2 — Final Approval (end of Phase 7)

Always user-interactive, both modes. Present:

```
Feature: [feature-slug] — Final Approval
────────────────────────────────────────────────────────
Tests:        {passed}/{total} passed
Coverage:     {N}% branch (target: 90%)
Code Review:
  Layer 1 (Phase 5): {agents} agents, {rounds} rounds, {issues} issues fixed
  Layer 2 (Phase 6): {agents} agents, {rounds} rounds, {issues} issues fixed
  Remaining:    {N} issues (must be 0 to approve [1] or [3])
Standards:    Result pattern, early exit, file size — {pass/fail}
Docs updated: ADR-NNN, spec, test plan, decisions log
Files changed: {N} ({src}/{tests})
Frozen decisions honored: {N}/{N}
Bypasses used: {N}
Chronic patterns prevented: {N}
────────────────────────────────────────────────────────
Options:
  [1] Approve → archive session, allow push
  [2] Reject → list issues to fix (returns to relevant phase)
  [3] Approve + commit + push
```

On approval (option 1 or 3):
1. Write `{SESSION_DIR}/pipeline-complete.md` with original branch name (unsanitized). This is the push-guard's authorization marker.
2. Append final summary to freeze doc `bypassHistory` (audit trail).
3. If option 3: stage, commit, push (push-guard sees the marker, allows push).

---

## 5. Hook Enforcement

### 5.1 Existing hooks audit summary

All seven existing hooks (`load-chronic-patterns.sh`, `phase-gate.sh`, `phase-progress-validator.sh`, `precompact.sh`, `push-guard.sh`, `sessionend.sh`, `test-failure-capture.sh`) are functionally valid. Two work items for this design:

1. **Extend `push-guard.sh`** to respect the unified session (it already uses `progress-log.json` and `pipeline-complete.md` — no new path needed, just confirmation the logic applies regardless of interactive/autonomous mode).
2. **Add `freeze-gate.sh`** — new hook.

Out of scope for this design (tracked separately): `test-failure-capture.sh` hardcoded `dotnet test` default.

### 5.2 New hook: `freeze-gate.sh`

**Event:** `PreToolUse` on `Edit` and `Write` tools.
**Purpose:** Block `src/**` edits unless freeze doc is `APPROVED`.

**Algorithm:**

```
1. If no progress-log.json for current branch → pass (no /dev session active).
2. If progress-log.mode != "full-cycle" → pass (review/test/docs workflow, not a full cycle).
3. If current branch differs from progress-log.branch → pass (user is elsewhere).
4. If bypass file exists AND its feature matches current session → pass.
5. Extract target path from tool input.
6. If path does not match src/ lib/ app/ prefix → pass.
7. If path matches test patterns (*.test.*, *.spec.*, *_test.*, tests/, test/) → pass.
8. Read freeze doc (path from progress-log.freezeDocPath).
9. If missing or status != APPROVED → block (exit 2) with remediation message.
10. Else pass.
```

### 5.3 Extended hook: `push-guard.sh`

**Unchanged core logic** — already checks `pipeline-complete.md` in session folder. In the unified world:
- Interactive `/dev` also writes `pipeline-complete.md` at GATE 2 approval (new behavior — previously only dev-pipeline did).
- Bypass: extend existing escape-flag mechanism to also accept ticket-scoped bypass file as a second authorization channel.

**Bypass check addition:**

```bash
# After existing escape-flag check:
BYPASS="$SESSION_DIR/bypass.json"
if [ -f "$BYPASS" ]; then
  jq -r '.feature' "$BYPASS" >/dev/null && exit 0
fi
```

### 5.4 Bypass mechanism

**File:** `{SESSION_DIR}/bypass.json` (in session folder, same place as other session state).

**Schema:**

```json
{
  "createdAt": "2026-04-19T14:00:00Z",
  "reason": "[LLM extracts user's stated reason]",
  "feature": "[matches progress-log.ticket or feature-slug]",
  "scope": "ticket",
  "userMessage": "[verbatim user request]"
}
```

**Properties:**
- Ticket-scoped: active for the entire session (until Phase 7 complete).
- Auto-cleared when session transitions to completed (by `sessionend.sh` or on GATE 2 approval).
- Feature name mismatch → bypass is ignored (cross-ticket bypass impossible).
- Recorded permanently in freeze doc `bypassHistory` for audit.

### 5.5 hooks.json registration

```json
{
  "PreToolUse": [
    {
      "matcher": "Edit|Write",
      "hooks": [{
        "type": "command",
        "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/freeze-gate.sh",
        "timeout": 3
      }]
    },
    {
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/push-guard.sh",
        "if": "Bash(git push *)",
        "timeout": 5
      }]
    }
  ]
}
```

Existing SessionStart, PreCompact, SessionEnd, and PostToolUse registrations are preserved as-is.

---

## 6. Config Initialization

### 6.1 Single source of truth: `ensure-config.sh`

The existing `/dev-pipeline` Pre-Pipeline step 2 contains inline config creation logic. We extract that into a standalone script and call it from both `/dev` (Section B start) and the unified autonomous flow.

**`hooks/scripts/ensure-config.sh`:**

```bash
#!/bin/bash
# Idempotent config bootstrap for dev-framework plugin.
# Creates ~/.claude/autodev/config.json with default schema if absent.
# Safe to call at the start of any /dev invocation.
set -euo pipefail

CONFIG_DIR="$HOME/.claude/autodev"
CONFIG_FILE="$CONFIG_DIR/config.json"

mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
  if command -v jq &>/dev/null && jq empty "$CONFIG_FILE" 2>/dev/null; then
    exit 0
  fi
  # Malformed — back up and regenerate.
  mv "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"
  echo "⚠️  config.json was malformed — backed up and regenerating with defaults."
fi

cat > "$CONFIG_FILE" <<'JSON'
{
  "pipeline": {
    "maxReviewIterations": 10,
    "consecutiveZerosToExit": 2,
    "testCoverageTarget": 90,
    "maxActivePatterns": 20,
    "chronicPromotionThreshold": 3,
    "cleanRunsForDemotion": 5,
    "maxRunsRetained": 10,
    "sessionHealthCheckpointPhases": 6,
    "skills": {
      "requirements": "superpowers:brainstorming",
      "exploration": "feature-dev:code-explorer",
      "architect": "feature-dev:code-architect",
      "planning": "superpowers:writing-plans",
      "tdd": "superpowers:test-driven-development",
      "implementation": "superpowers:subagent-driven-development",
      "implementationSequential": "superpowers:executing-plans",
      "implementationParallel": "superpowers:dispatching-parallel-agents",
      "requestReview": "superpowers:requesting-code-review",
      "receiveReview": "superpowers:receiving-code-review",
      "verification": "superpowers:verification-before-completion",
      "finishing": "superpowers:finishing-a-development-branch",
      "debugging": "superpowers:systematic-debugging"
    },
    "agents": {
      "plan": ["requirements-analyst", "architect", "test-strategist"],
      "review": ["code-quality-reviewer", "performance-reviewer", "observability-reviewer"]
    },
    "freezeDoc": {
      "categories": [
        "business-logic", "api-contracts", "third-party",
        "data", "error-model", "acceptance-criteria",
        "security", "performance"
      ],
      "nonFrozenAllowList": [
        "observability", "railroad-composition", "pure-function-composition"
      ],
      "customCategoryTemplatesDir": "~/.claude/autodev/freeze-categories/"
    }
  },
  "paths": {
    "sessionsDir": "~/.claude/autodev/sessions",
    "autodevRoot": "~/.claude/autodev",
    "patternsFile": "workflow_mistake_patterns.md"
  },
  "sessionFolderFormat": "{repo}--{branch}",
  "hooks": {
    "pushGuard": { "escapeFlags": ["--force", "-f"] },
    "testCapture": { "testCommand": "dotnet test" }
  },
  "sentinels": {
    "begin": "<!-- CHRONIC PATTERNS START -->",
    "end": "<!-- CHRONIC PATTERNS END -->"
  }
}
JSON

echo "Created default config at $CONFIG_FILE — edit to customize skills, agents, and thresholds."
```

Note: pipeline.skills no longer contains `consensus` or `testPlanning` or `implementation` references to the removed `dev-framework:*` skills — these are now internal protocols, not configurable skills. Reviewed and removed in this consolidation.

---

## 7. Review Iteration Unification

Hardcoded `max 5 iterations` in `/dev` SKILL.md Phases 5 and 6 is replaced with references to `config.pipeline.maxReviewIterations` (default 10) and `config.pipeline.consecutiveZerosToExit` (default 2). All reviews — Layer 1, Layer 2, plan validation, freeze doc validation — use the same defaults from one source.

---

## 8. Session State Unification

**Before:**
- `/dev-pipeline`: `~/.claude/autodev/sessions/{repo}--{branch}/` (progress-log.json, decision-log.json, pipeline-issues.json, tdd-plan.md, pipeline-complete.md).
- `/dev` (interactive): no session state.

**After (unified):**
- Both modes use `~/.claude/autodev/sessions/{repo}--{branch}/`.
- `progress-log.json` gains new fields:
  - `mode`: `"full-cycle" | "review" | "test" | "docs" | "init"` — lets hooks distinguish workflows.
  - `freezeDocPath`: relative path from repo root, e.g. `docs/specs/order-bulk-create-freeze.md`.
  - `plannedFiles`: string array, populated at Phase 3 completion.
  - `featureSlug`: stable identifier used across artifacts.
- `bypass.json` (if any) also lives in session folder.

Interactive mode creates progress-log.json at Phase 1 start with `mode: "full-cycle"`. Autonomous mode already does this; no change.

---

## 9. Skill Consolidation

### 9.1 Skills being moved (content preserved, path changes only)

| From | To | New role |
|---|---|---|
| `skills/multi-agent-consensus/SKILL.md` | `skills/dev/references/protocols/multi-agent-consensus.md` | Internal protocol, invoked by dev SKILL.md |
| `skills/project-docs/SKILL.md` | `skills/dev/references/protocols/project-docs.md` | Internal protocol |
| `skills/test-planning/SKILL.md` | `skills/dev/references/protocols/test-planning.md` | Internal protocol |
| `skills/dev-pipeline/references/session-management.md` | `skills/dev/references/autonomous/session-management.md` | Internal reference |
| `skills/dev-pipeline/references/review-loop-protocol.md` | `skills/dev/references/autonomous/review-loop-protocol.md` | Internal reference |
| `skills/dev-pipeline/references/mistake-tracker-protocol.md` | `skills/dev/references/autonomous/mistake-tracker-protocol.md` | Internal reference |

After the move, the moved files lose their `---\nname:` frontmatter block (that's for top-level skills); they become plain markdown references.

### 9.2 Files deleted

| Path | Reason |
|---|---|
| `commands/dev-pipeline.md` | `/dev --autonomous` replaces it |
| `skills/dev-pipeline/SKILL.md` | Content absorbed into `skills/dev/SKILL.md` |
| `skills/dev-pipeline/` folder (empty after moves) | — |
| `skills/multi-agent-consensus/` folder (empty after move) | — |
| `skills/project-docs/` folder (empty after move) | — |
| `skills/test-planning/` folder (empty after move) | — |

### 9.3 `skills/dev/SKILL.md` rewrite

The new SKILL.md is the single source of truth for the workflow. High-level structure:

1. **Workflow routing** — detects mode from `$ARGUMENTS`:
   - `init` keyword → Init workflow (Section A).
   - `review` keyword → Review workflow (Section C).
   - `test` keyword → Test workflow (Section D).
   - `docs` keyword → Docs workflow (Section E).
   - `--autonomous TICKET` → Full-cycle autonomous.
   - Otherwise → Full-cycle interactive (Section B).

2. **Pre-Workflow (all modes):**
   - Call `bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/ensure-config.sh` to guarantee config.
   - Resolve session folder (use the algorithm from `references/autonomous/session-management.md`).
   - Load chronic patterns.

3. **Section A: Init** — unchanged functionally; invokes `references/protocols/project-docs.md` for docs scaffolding.

4. **Section B: Full Cycle** — the unified 7-phase workflow. Interactive mode has GATE 1 user-interactive at Phase 3; autonomous mode skips GATE 1 (writes APPROVED with audit). GATE 2 always interactive. Phases 4-7 autonomous in both modes. Review loops use config defaults (10/2).

5. **Section C: Review** — standalone quality review. Uses `references/protocols/multi-agent-consensus.md` protocol.

6. **Section D: Test** — standalone test strategy. Uses `references/protocols/test-planning.md`.

7. **Section E: Docs** — standalone docs maintenance. Uses `references/protocols/project-docs.md`.

8. **Phase Failure Protocol, Gate Failure Protocol** — absorbed from dev-pipeline SKILL.md.

9. **Cross-cutting concerns** — phase gates, decision logging, progress tracking, markdown regeneration, performance budgets (from dev-pipeline SKILL.md).

### 9.4 References to moved protocols

Internal references become relative paths: `references/protocols/multi-agent-consensus.md` instead of `dev-framework:multi-agent-consensus`. SKILL.md reads these via its Read tool, not via the Skill tool.

---

## 10. CLAUDE.md (plugin root) rewrite

The plugin-level CLAUDE.md is rewritten to describe one workflow with optional modes. Hook table includes `freeze-gate.sh` and `ensure-config.sh`. `/dev` vs `/dev-pipeline` comparison table is removed (no comparison — one command).

---

## 11. File Change Inventory

### 11.1 New files

| Path | Purpose |
|---|---|
| `hooks/scripts/ensure-config.sh` | Idempotent config bootstrap (single source of truth) |
| `hooks/scripts/freeze-gate.sh` | Block src/** edits unless freeze doc APPROVED |
| `skills/dev/references/templates/FREEZE_DOC_TEMPLATE.md` | 8-category freeze doc template |
| `skills/dev/references/protocols/multi-agent-consensus.md` | Moved from deleted skill |
| `skills/dev/references/protocols/project-docs.md` | Moved from deleted skill |
| `skills/dev/references/protocols/test-planning.md` | Moved from deleted skill |
| `skills/dev/references/autonomous/session-management.md` | Moved from deleted skill |
| `skills/dev/references/autonomous/review-loop-protocol.md` | Moved from deleted skill |
| `skills/dev/references/autonomous/mistake-tracker-protocol.md` | Moved from deleted skill |

### 11.2 Modified files

| Path | Nature |
|---|---|
| `skills/dev/SKILL.md` | Full rewrite — unified 7-phase workflow, absorbs dev-pipeline, freeze doc integration, 10/2 default |
| `hooks/scripts/push-guard.sh` | Add bypass.json check, ensure pipeline-complete.md also written by interactive mode |
| `hooks/hooks.json` | Add freeze-gate PreToolUse registration |
| `CLAUDE.md` (plugin root) | Rewrite to describe single `/dev` |

### 11.3 Deletions

| Path |
|---|
| `commands/dev-pipeline.md` |
| `skills/dev-pipeline/` (entire directory after moves) |
| `skills/multi-agent-consensus/` (after move) |
| `skills/project-docs/` (after move) |
| `skills/test-planning/` (after move) |

### 11.4 Out of scope (separate tasks)

- `test-failure-capture.sh` language-agnostic default — spawned as separate task.
- README.md updates — spawned follow-up once all changes land.

---

## 12. Compatibility & Migration

### 12.1 In-flight sessions

- Sessions started before this change continue working under `/dev-pipeline` logic since the moved references are at new paths. **Risk:** if a user has an active `/dev-pipeline` run when this lands, the command is gone.
- **Mitigation:** Phase F commit notes include a migration call-out: complete in-flight sessions before pulling this change, or manually re-invoke phases via `/dev --from N --autonomous TICKET`.

### 12.2 External consumers

Grep across the repo confirms no external consumer (other plugins, user CLAUDE.md, etc.) references the soon-deleted skills by their fully-qualified names. Internal references are updated as part of the rewrite.

### 12.3 Config file

Existing `~/.claude/autodev/config.json` files gain new optional keys (`freezeDoc` section). Missing keys fall back to defaults defined in `ensure-config.sh`. No breaking change for users with existing configs.

---

## 13. Execution Plan

Six logical commits:

1. **Phase A** — File moves only (git mv). No logic changes. Protocol files relocated under `skills/dev/references/`.
2. **Phase B** — New artifacts: `ensure-config.sh`, `freeze-gate.sh`, `FREEZE_DOC_TEMPLATE.md`.
3. **Phase C1** — Rewrite `skills/dev/SKILL.md` (longest file; isolated commit for reviewability).
4. **Phase C2** — Update `hooks/scripts/push-guard.sh`, `hooks/hooks.json`, `CLAUDE.md`.
5. **Phase D** — Delete `commands/dev-pipeline.md` and emptied skill directories.
6. **Phase E** — Multi-agent review findings and fixes (one or more commits depending on volume).

Each commit leaves the plugin in a working state (no commit half-moves a file).

---

## 14. Review Plan

After all implementation commits land, run a multi-agent consensus review:

- **Agents:** `code-quality-reviewer`, `observability-reviewer`, `performance-reviewer`.
- **Max iterations:** 20 (higher than default 10 for this large consolidation).
- **Early exit:** 2 consecutive zero-valid-issue rounds.
- **Scope:** all files changed in Phases A-E.
- **Quality bar:** high — no time-pressure shortcuts. Findings treated with full issue-validity criteria (see `references/autonomous/review-loop-protocol.md`).

---

## 15. Success Criteria

1. After consolidation, a fresh user invoking `/dev` sees one skill, one command, and a single workflow. No mention of `/dev-pipeline`.
2. `/dev` run from a vague requirement produces a complete category-structured freeze doc another team could execute without further consultation.
3. The LLM physically cannot write to src/** before GATE 1 approval (verified by attempting and seeing hook block).
4. During Phase 4-7, the LLM never asks the user a question about a frozen-category decision. If such a question arises, workflow halts with clear "ticket update required" message.
5. Push is blocked until GATE 2 approval (both interactive and autonomous modes create the completion marker).
6. Bypass is only possible via explicit user trigger, with audit trail in freeze doc.
7. Review iteration behavior is identical across all phases and modes (10 max, 2 consecutive zero).
8. `~/.claude/autodev/config.json` is auto-created on first `/dev` use (previously only on first `/dev-pipeline` use).

---

## Appendix A — FREEZE_DOC_TEMPLATE.md detail

Full body template per category, with example rows. This content lives in `skills/dev/references/templates/FREEZE_DOC_TEMPLATE.md`; documented here for spec completeness.

### § 1. Business Logic

```markdown
## § 1. Business Logic

**Purpose:** Domain rules, decision flows, validation rules.

### Decisions
| ID | Rule | Rationale | Source |
|----|------|-----------|--------|
| BL-01 | [rule] | [why] | [ticket/discussion ref] |

### Open Questions
All items must be empty before GATE 1 approval.
- [ ] (empty)
```

### § 2. API Contracts (Internal)

```markdown
## § 2. API Contracts (Internal)

**Purpose:** Internal endpoint paths, methods, request/response schemas, auth.
**Rule:** Follow existing repo conventions first. Document deviations explicitly.

### Conventions Followed
- [observed pattern, e.g., "REST style: /api/v1/{resource}/{id}"]
- [observed pattern, e.g., "Response wrapper: { data, error, meta } from src/api/response.ts"]

### Endpoints
| Method | Path | Auth | Request Schema | Response Schema |
|--------|------|------|----------------|-----------------|
| POST | /api/v1/... | required | CreateXRequest | XResponse |

### Request/Response Schemas
Concrete type definitions for each schema listed above.

### Proposed Deviations
None. / Or: [deviation + rationale, requires explicit user approval in GATE 1]
```

### § 3. 3rd Party Integrations

```markdown
## § 3. 3rd Party Integrations

**Purpose:** External API usage — payload, rate limit, retry, cache.

### Integrations
| Service | Endpoint | Payload Ref | Rate Limit | Retry Policy | Cache TTL |

### Secrets & Credentials
- **Storage:** [where]
- **Rotation:** [policy or N/A]
```

### § 4. Data & Database

```markdown
## § 4. Data & Database

**Purpose:** DB schema changes, enums, migrations, backfills.

### Schema Changes
[SQL/DDL]

### Enums
| Enum | Values | Default | Notes |

### Migration Strategy
- **Forward:** [migration file ref]
- **Rollback:** [approach]

### Backfill Plan
- **Existing rows:** [handling]
- **Timing:** [when backfill runs]
- **Estimated duration:** [time]
```

### § 5. Error Model

```markdown
## § 5. Error Model

**Purpose:** Error codes, user-facing messages, recovery paths.

### Errors
| Code | Message (user) | HTTP | Recovery Action |
```

### § 6. Acceptance Criteria

```markdown
## § 6. Acceptance Criteria

**Purpose:** Testable feature-complete conditions.

- [ ] AC-01: [testable condition]
- [ ] AC-02: [testable condition]
```

### § 7. Security / Auth

```markdown
## § 7. Security / Auth

**Purpose:** Authorization model, sensitive data handling, threat surface.

### Authorization Model
- Endpoint scope / role / permission
- Row-level access rules

### Sensitive Data Handling
- PII masking approach
- Secret/token storage rules

### Threat Surface
- Identified threats (IDOR, CSRF, etc.)
- Mitigations in place
```

### § 8. Performance

```markdown
## § 8. Performance

**Purpose:** SLA, throughput, resource budgets.

### Budgets
| Metric | Target | Measurement Point |
```

### § 9. Non-Frozen Questions

```markdown
## § 9. Non-Frozen Questions

**Purpose:** Rules for LLM question handling during Phase 4-7.

### Zone 1 — Frozen (halt on violation)
All decisions in §1-§8 above.

### Zone 2 — Non-Frozen (may ask user)
- observability details (log level, metric name, span naming)
- railroad/Result chain composition
- pure function composition

### Zone 3 — Ambiguous (context-aware 4-tier rule)
1. Existing code in repo → follow silently; ask with suggestion if deviation needed.
2. User-provided reference repo → same as existing code.
3. Initial implementation (no anchor) → ask liberally.
4. Otherwise → self-decide using standards/.
```
