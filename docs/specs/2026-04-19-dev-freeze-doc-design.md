# Design: `/dev` Freeze Doc Workflow

**Date:** 2026-04-19
**Status:** Draft (awaiting user review)
**Author:** Dev-framework maintainers
**Scope:** Upgrade `/dev` skill to enforce "research → freeze → execute" boundary via freeze doc artifact + hook-based user approval gates.

---

## 1. Background & Motivation

### Problem

The current `/dev` Section B (Full Cycle) mixes two distinct kinds of work inside a single 7-phase workflow:

- **Pre-ticket work** (Phases 1-3): requirements gathering, architecture, planning. The "research" phase.
- **Post-ticket work** (Phases 4-7): testing strategy, implementation, verification, documentation. The "execution" phase.

The boundary between these two is implicit — only the Phase 3 user gate separates them. This creates three failure modes in practice:

1. **Incomplete research before execution.** Small-picture details (status enum options, 3rd party API payload/rate-limit/cache, DB schema choices) leak into Phase 5+ as mid-implementation questions that block coding and require synchronous business consultation.
2. **Decision drift.** Decisions made verbally in Phase 1-3 are not captured in a single artifact, so Phase 5+ agents re-interpret or forget them.
3. **No enforcement layer.** Even if the user approves at Phase 3, nothing physically prevents the LLM from writing code before approval or changing frozen decisions mid-execution.

### Philosophy (user's stated principle)

> Plugin's only purpose: AI leads development end-to-end; the user answers questions, discusses, confirms, and completes. All skills and hooks exist for this single workflow.

Translating into concrete design requirements:

- All research and questions must end when the ticket transitions from "drafting" to "ready-to-execute." A ticket is just the initial requirement source; the transition point is what matters, not whether a ticket exists at the start.
- Big-picture AND small-picture decisions are frozen together at that transition.
- During execution, only three question zones exist: frozen (blocked), non-frozen (allowed), self-decide (no question needed).
- User approval is a **physical artifact** (file state), not a verbal exchange.

### Ticket origin is irrelevant to the workflow

A ticket can originate from:
1. A fresh business requirement handed to the developer.
2. Troubleshoot → research → investigation → plan → ticket creation (ticket is an *output* of early work).

Either way, the workflow is the same. The "ticket" is one possible input or output of Phase 1. What matters is that by end of Phase 3, all decisions required to execute are captured and frozen.

---

## 2. Design Overview

### 2.1 Two-gate workflow

```
Phase 1: Requirements (interactive)
  → populates freeze doc: §1 Business Logic, §5 Error Model, §6 Acceptance Criteria
Phase 2: Architecture (interactive)
  → populates freeze doc: §2 API Contracts, §3 3rd Party, §4 Data,
    §7 Security, §8 Performance
Phase 3: Planning + Freeze Doc Assembly (interactive)
  → assembles complete freeze doc
  → 🚪 GATE 1: user reviews category-structured freeze doc, approves

[freeze-gate hook ACTIVE — src/** edits blocked unless freeze doc APPROVED]

Phase 4: Testing Strategy (autonomous)
Phase 5: Implementation (autonomous + Layer 1 review consensus)
Phase 6: Verification & Code Review (autonomous + Layer 2 review consensus)
Phase 7: Documentation (autonomous)
  → 🚪 GATE 2: user reviews review summary + final state, approves

[push-guard hook — blocks git push until GATE 2 approved]
```

### 2.2 Zone-based execution rules

During Phase 4-7, any question the LLM encounters falls into one of three zones:

| Zone | Description | LLM behavior |
|---|---|---|
| 🛑 **Frozen** | Would change a decision in freeze doc §1-§8 | HALT workflow + notify "ticket update required" |
| ✅ **Non-Frozen** | In allow-list (observability, railroad composition, pure-function composition, etc.) | May ask user |
| 🤔 **Ambiguous** | Technical question not covered by above | Use 4-tier context rule (see 2.3) |
| ⚙️ **Self-decide** | Pure technical (naming, extraction, internal module boundaries) | No question — decide using standards and context |

### 2.3 Ambiguous question 4-tier rule

```
Is there related code in THIS repo?
├─ YES → Follow existing patterns (silent)
│         └─ Pattern seems wrong or deviation needed?
│             ├─ YES → Ask with suggestion (format below)
│             └─ NO  → Proceed silently
└─ NO  → Did user provide reference/example repo?
         ├─ YES → Same branch as "repo has related code"
         └─ NO  → Is this an initial implementation (totally new area)?
                  ├─ YES → Ask many questions (no anchor, need user intent)
                  └─ NO  → Self-decide using standards/
```

### 2.4 "Ask with suggestion" format (mandatory for ambiguous questions that require user input)

```
📋 Context: [observed existing pattern or reference]
🔍 Observation: [why this case seems to need deviation]
💡 Proposal: [proposed alternative with reasoning]
❓ Decision needed: [concrete question for user]
```

---

## 3. Freeze Doc

### 3.1 File location

`docs/specs/[feature-slug]-freeze.md`

### 3.2 Frontmatter

```yaml
---
feature: [feature-slug]
status: DRAFT | PENDING_APPROVAL | APPROVED | BYPASSED | SUPERSEDED
createdAt: 2026-04-19T10:00:00Z
approvedAt: null
approvedBy: null
bypassedAt: null
bypassReason: null
bypassHistory: []           # persistent audit (even after bypass is cleared)
supersededBy: null          # path to replacement freeze doc
frozenCategories:           # blocked during execution
  - business-logic
  - api-contracts
  - third-party
  - data
  - error-model
  - acceptance-criteria
  - security
  - performance
nonFrozenAllowList:         # allowed during execution
  - observability
  - railroad-composition
  - pure-function-composition
customCategories: []        # loaded from config (future extension)
---
```

### 3.3 Body structure (8 categories)

#### § 1. Business Logic
Purpose: domain rules, decision flows, validation rules.
Required subsections:
- `Decisions` table: ID, Rule, Rationale, Ticket Ref
- `Open Questions` list (must be empty before APPROVED)

#### § 2. API Contracts (Internal)
Purpose: internal endpoint paths/methods, request/response schemas, auth.
**Rule:** follow existing repo conventions first; document deviations explicitly with rationale.
Required subsections:
- `Conventions Followed` — observed patterns from existing codebase
- `Endpoints` table: Method, Path, Auth, Request Schema, Response Schema
- `Request/Response Schemas` — concrete type definitions
- `Proposed Deviations` — any deviation from existing conventions, with reasoning

#### § 3. 3rd Party Integrations
Purpose: external API usage — payload, rate limit, retry, cache.
Required subsections:
- Integration table: Service, Endpoint, Payload Ref, Rate Limit, Retry Policy, Cache TTL
- `Secrets & Credentials` — storage location, rotation policy

#### § 4. Data & Database
Purpose: DB schema changes, enums, migrations, backfills (single category — these always need to be decided together).
Required subsections:
- `Schema Changes` — SQL/DDL
- `Enums` table: Name, Values, Default, Notes
- `Migration Strategy` — forward and rollback
- `Backfill Plan` — existing row handling, timing, estimated duration

#### § 5. Error Model
Purpose: error codes, user-facing messages, recovery paths.
Required subsections:
- Error table: Code, Message (user), HTTP status, Recovery Action

#### § 6. Acceptance Criteria
Purpose: feature-complete judgment. Each item must be testable.
Required subsections:
- Checkbox list of `AC-NN: [testable condition]`

#### § 7. Security / Auth
Purpose: authZ model, sensitive data handling, threat surface.
Required subsections:
- `Authorization Model` — endpoint scope, row-level access rules
- `Sensitive Data Handling` — PII masking, token storage rules
- `Threat Surface` — identified threats + mitigations

#### § 8. Performance
Purpose: SLA, throughput, resource budgets.
Required subsections:
- Performance budget table: Metric, Target, Measurement Point (e.g., p95 latency, p99 latency, throughput, DB query budget, memory)

#### § 9. Non-Frozen Questions (execution-phase behavior rules)
Purpose: define question-handling behavior during Phase 4-7.
Required subsections:
- `Zone 1 — Frozen` — references § 1-§8 (frozen categories)
- `Zone 2 — Non-Frozen` — allow list (must match `nonFrozenAllowList` in frontmatter)
- `Zone 3 — Ambiguous` — the 4-tier rule (above)

### 3.4 Category extensibility

Categories live in `~/.claude/autodev/config.json`:

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
1. Append `"migration-safety"` to `categories` array.
2. Create `~/.claude/autodev/freeze-categories/migration-safety.md` with section template.
3. Next `/dev` run picks it up automatically.

SKILL.md and the template render sections by iterating this array — no hardcoded 8-category list.

---

## 4. User Gates

### 4.1 GATE 1 — Freeze Doc Approval (end of Phase 3)

**Presented to user:**
- Full freeze doc with category-structured sections.
- Validation summary: which categories have `Open Questions` empty, which have entries, which are still ambiguous.
- Option list:
  - `[1] Approve all` → write `status: APPROVED`, timestamp, approvedBy; grant src/** write permission.
  - `[2] Reject category X` → reopen specified category (return to Phase 1 or 2 depending on which category).
  - `[3] Inline edit` → modify specific items, re-review.

**On approval:**
1. Set freeze doc `status: APPROVED`.
2. Record `approvedAt` (UTC) and `approvedBy` (user email or identifier).
3. Create/update `.claude/dev-session/active-feature.json` with `freezeDocPath`, `plannedFiles`, `branch`, `startedAt`.

**On rejection:**
- Workflow returns to the specified phase. User may iterate multiple times.

### 4.2 GATE 2 — Final Approval (end of Phase 7)

**Presented to user:**

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
Docs updated: ADR-NNN, spec, test plan
Files changed: {N} ({src}/{tests})
Frozen decisions honored: {N}/{N}
Bypasses used: {N}
────────────────────────────────────────────────────────
Options:
  [1] Approve → archive session, allow push
  [2] Reject → list issues to fix (returns to relevant phase)
  [3] Approve + commit + push
```

**On approval (option 1 or 3):**
1. Move `.claude/dev-session/active-feature.json` to `.claude/dev-session/completed/[feature]-[timestamp].json`.
2. Append final summary to freeze doc (immutable record).
3. If option 3: stage, commit, and push (push-guard hook passes because no active-feature.json exists).

**On rejection:**
- Return to Phase 5 or 6 (user choice) to fix remaining issues.

---

## 5. Hook Enforcement

### 5.1 Existing hooks audit

All 7 existing hooks are valid (verified in audit):
`load-chronic-patterns.sh`, `phase-gate.sh`, `phase-progress-validator.sh`, `precompact.sh`, `push-guard.sh`, `sessionend.sh`, `test-failure-capture.sh`.

Two gaps relevant to this work:
- **push-guard.sh** only checks `dev-pipeline` sessions (`sessions/{repo}--{branch}/pipeline-complete.md`), not `/dev` sessions.
- **test-failure-capture.sh** defaults to `dotnet test` — contradicts "language-agnostic" goal. Tracked as separate task (not in this design's scope).

### 5.2 New hook: `freeze-gate.sh`

**Location:** `plugins/dev-framework/hooks/scripts/freeze-gate.sh`
**Event:** `PreToolUse` on `Edit` and `Write` tools
**Purpose:** Block src/** edits unless freeze doc is APPROVED.

**Logic:**

```bash
SESSION_FILE=".claude/dev-session/active-feature.json"

# 1. No active /dev session → pass through (normal coding OK)
[ ! -f "$SESSION_FILE" ] && exit 0

# 2. Branch mismatch → pass through (user is on a different branch)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
ACTIVE_BRANCH=$(jq -r '.branch' "$SESSION_FILE")
[ "$CURRENT_BRANCH" != "$ACTIVE_BRANCH" ] && exit 0

# 3. Bypass check (ticket-scoped)
BYPASS_FILE=".claude/dev-session/bypass.json"
if [ -f "$BYPASS_FILE" ]; then
  BYPASS_FEATURE=$(jq -r '.feature' "$BYPASS_FILE")
  ACTIVE_FEATURE=$(jq -r '.feature' "$SESSION_FILE")
  [ "$BYPASS_FEATURE" = "$ACTIVE_FEATURE" ] && exit 0
fi

# 4. Extract target path from tool input
INPUT=$(cat)
TARGET_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$TARGET_PATH" ] && exit 0

# 5. Scope filter — only enforce on src/**, exclude tests and docs
case "$TARGET_PATH" in
  src/*|lib/*|app/*) ;;
  *) exit 0 ;;
esac
case "$TARGET_PATH" in
  *.test.*|*.spec.*|*_test.*|tests/*|test/*) exit 0 ;;
esac

# 6. Check freeze doc status
FREEZE_DOC=$(jq -r '.freezeDocPath' "$SESSION_FILE")
if [ ! -f "$FREEZE_DOC" ]; then
  echo "🛑 BLOCKED: freeze doc missing ($FREEZE_DOC). Complete Phase 1-3 first."
  exit 2
fi

# Parse frontmatter status (between --- markers)
STATUS=$(awk '/^---$/{f=!f; next} f && /^status:/{gsub(/^status: */, ""); print; exit}' "$FREEZE_DOC")

if [ "$STATUS" != "APPROVED" ]; then
  echo "🛑 BLOCKED: freeze doc status is '$STATUS' (need APPROVED)."
  echo "   Complete Phase 1-3 and GATE 1 approval, or say 'bypass freeze' to override for this ticket."
  exit 2
fi

exit 0
```

### 5.3 Extended hook: `push-guard.sh`

**Changes:**
- Add `/dev` session check alongside existing `dev-pipeline` check.
- Support ticket-scoped bypass.

**New logic structure:**

```bash
# ... (existing config loading, branch resolution) ...

# Check 1: dev-pipeline completion (existing)
if [ -d "$SESSION_DIR" ] && [ -f "$SESSION_DIR/pipeline-complete.md" ]; then
  grep -qxF "Pipeline completed for branch: $BRANCH" "$SESSION_DIR/pipeline-complete.md" && exit 0
fi

# Check 2: /dev session (new)
DEV_SESSION=".claude/dev-session/active-feature.json"
if [ -f "$DEV_SESSION" ]; then
  # bypass check
  BYPASS=".claude/dev-session/bypass.json"
  if [ -f "$BYPASS" ]; then
    BYPASS_FEATURE=$(jq -r '.feature' "$BYPASS")
    ACTIVE_FEATURE=$(jq -r '.feature' "$DEV_SESSION")
    [ "$BYPASS_FEATURE" = "$ACTIVE_FEATURE" ] && exit 0
  fi
  echo "🛑 BLOCKED: /dev workflow in progress for '$(jq -r .feature "$DEV_SESSION")'."
  echo "   Complete Phase 7 (GATE 2 final approval) or use --force to bypass."
  exit 2
fi

# Check 3: dev-pipeline session exists but not completed
if [ -d "$SESSION_DIR" ]; then
  echo "🛑 BLOCKED: dev-pipeline not completed for branch '$BRANCH'."
  exit 2
fi

# No active workflow → allow push
exit 0
```

### 5.4 Bypass mechanism

**Trigger phrases** (LLM recognizes and creates bypass file):
- "bypass freeze"
- "freeze 무시하고 진행"
- "freeze 우회"
- explicit user-authored sentence indicating bypass intent

**File:** `.claude/dev-session/bypass.json`

```json
{
  "createdAt": "2026-04-19T14:00:00Z",
  "reason": "[LLM extracts user's stated reason]",
  "feature": "[matches active-feature.json]",
  "scope": "ticket",
  "userMessage": "[verbatim user request]"
}
```

**Properties:**
- Ticket-scoped: active for the entire feature lifecycle, not TTL-based.
- Auto-cleared when `active-feature.json` is archived (Phase 7 completion).
- Persistent audit: bypass event is appended to freeze doc frontmatter `bypassHistory` — never lost.
- Feature name mismatch → bypass is ignored (cross-ticket bypass impossible).

### 5.5 hooks.json changes

Add `freeze-gate.sh` registration:

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
    // ... existing push-guard registration for Bash ...
  ]
}
```

---

## 6. Review Iteration Unification

### 6.1 Problem

Current state has three different review iteration settings:

| Location | Current value |
|---|---|
| `multi-agent-consensus` protocol default | `max_iterations: 10, zero_threshold: 2` |
| `dev-pipeline` (reads config) | `maxReviewIterations: 10, consecutiveZerosToExit: 2` |
| `/dev` Phase 5 end review | `max 5 iterations` (hardcoded) |
| `/dev` Phase 6 review loop | `5 iterations` (hardcoded) |

This breaks the "one workflow, one quality bar" principle.

### 6.2 Resolution

Remove the hardcoded `5` in `/dev` SKILL.md Phase 5 and Phase 6. Use protocol defaults (10/2) via multi-agent-consensus skill.

**SKILL.md changes:**

Phase 5 — before:
> invoke `dev-framework:multi-agent-consensus` with `task_type: validate` (max 5 iterations — see DECISION_MAKING.md; escalate if unresolved)

Phase 5 — after:
> invoke `dev-framework:multi-agent-consensus` with `task_type: validate`. Use protocol defaults (`max_iterations: 10`, `zero_threshold: 2`). Escalate to user if not converged.

Phase 6 — before:
> If the resolution loop does not converge within 5 iterations, escalate remaining issues to the user.

Phase 6 — after:
> If the resolution loop does not converge within `max_iterations` (default 10), escalate remaining issues to the user.

Result: `/dev` and `/dev-pipeline` now run reviews at the same depth. Single source of truth (the multi-agent-consensus protocol defaults).

---

## 7. File Change Inventory

### 7.1 New files

| Path | Purpose |
|---|---|
| `plugins/dev-framework/hooks/scripts/freeze-gate.sh` | Enforce freeze doc APPROVED before src/** edits |
| `plugins/dev-framework/skills/dev/references/templates/FREEZE_DOC_TEMPLATE.md` | Template for feature freeze docs |

### 7.2 Modified files

| Path | Changes |
|---|---|
| `plugins/dev-framework/skills/dev/SKILL.md` | Section B Phase 1-3: populate freeze doc by category. Phase 3 end: GATE 1. Phase 5/6: review iteration text updated to use protocol defaults. Phase 7 end: GATE 2 with summary. |
| `plugins/dev-framework/hooks/scripts/push-guard.sh` | Add `/dev` session check with ticket-scoped bypass. |
| `plugins/dev-framework/hooks/hooks.json` | Register `freeze-gate.sh` on PreToolUse(Edit\|Write). |
| `plugins/dev-framework/skills/dev-pipeline/references/session-management.md` | Add `freezeDoc` config schema section (canonical source). |
| `plugins/dev-framework/CLAUDE.md` | Update hook table to include `freeze-gate`. |

### 7.3 Runtime-generated (not committed)

| Path | Purpose |
|---|---|
| `.claude/dev-session/active-feature.json` | Per-feature workflow state (exists while workflow active) |
| `.claude/dev-session/bypass.json` | Bypass declaration (ticket-scoped) |
| `.claude/dev-session/completed/` | Archived completed features |

These paths must be added to `.gitignore` if not already covered.

### 7.4 Out of scope (separate tasks)

| Item | Reason |
|---|---|
| `test-failure-capture.sh` language-agnostic default | Unrelated cleanup; spawned as separate task |
| Level 3 plugin consolidation (merge dev-pipeline into /dev, flatten skills directory) | Architectural refactor; scheduled as follow-up after this work |

---

## 8. Compatibility & Migration

### 8.1 In-flight `/dev` sessions

Sessions started before this change lack `.claude/dev-session/active-feature.json`. Hook behavior:
- `freeze-gate.sh` sees no session file → passes through (no blocking).
- `push-guard.sh` checks new path, finds nothing → falls through to existing dev-pipeline check, passes through if not dev-pipeline branch.

No user action required; next `/dev` invocation starts fresh with the new workflow.

### 8.2 Relationship with existing spec docs

Freeze doc **complements** existing `docs/specs/[feature]-requirements.md`; it does not replace it:

- Requirements spec = output of Phase 1 (feature-focused narrative).
- Freeze doc = output of Phase 3 (category-structured execution contract).

Both are authored during Phase 1-3. Requirements spec captures "what and why"; freeze doc captures "exact decisions for each category."

### 8.3 Relationship with `/dev-pipeline`

No change in this design. `/dev-pipeline` continues to work as-is; the freeze doc workflow is only in `/dev` Section B for now.

Level 3 integration (separate future work) will merge `/dev-pipeline` into `/dev` as an autonomous mode, at which point freeze doc applies uniformly.

---

## 9. Open Questions (deferred decisions)

None. All design decisions resolved through brainstorming. Items explicitly scoped out:

- test-failure-capture.sh cleanup → separate task
- Level 3 integration → separate task
- Commit hook (no such hook currently; commits remain unguarded — push is the only enforcement point)

---

## 10. Success Criteria

This design is successful if, after implementation:

1. A `/dev` run from a vague requirement produces a complete, category-structured freeze doc that a human developer could hand to another team and have them implement.
2. The LLM physically cannot write to src/** before user freeze doc approval (verified by attempting and seeing hook block).
3. During Phase 4-7, the LLM never asks the user a question about frozen-category decisions (business logic, API contracts, etc.) — if such a question arises, workflow halts with "ticket update required."
4. Push is blocked until user GATE 2 approval, verified by `git push` failing with clear message.
5. Bypass is only possible via explicit user trigger phrases, with audit trail in freeze doc.
6. Review iteration behavior is identical between `/dev` and `/dev-pipeline` (both 10/2).
