# Development Cycle

The development framework enforces a 7-phase cycle for new feature development and significant changes. Standalone review, test analysis, and documentation maintenance use abbreviated workflows (see `skills/dev/SKILL.md` Sections C-E).

This document is a refresher overview. SKILL.md is authoritative — if this document conflicts, defer to SKILL.md.

## Core Philosophy

- **Move slow, do it right.** Reduce revisits and refactoring.
- **Full rigor always.** 3+ agents per step, discussion loops until zero issues (default `max_iterations: 10`, `zero_threshold: 2` — both from `config.pipeline.*`).
- **Never short-circuit validation.** Fixing issues without re-running agents is not convergence. Every fix must be verified by a fresh agent dispatch. See the "Critical Rule" section in `references/protocols/multi-agent-consensus.md`.

## Phases Overview

| Phase | Mode | Description |
|-------|------|-------------|
| 1. Requirements | Interactive | Gather and validate requirements; populate freeze doc §1/§5/§6 |
| 2. Research (Codebase + Architecture) | Interactive | Explore existing code, design architecture, produce ADRs; populate freeze doc §2/§3/§4/§7/§8 |
| 3. Plan + Freeze Doc Assembly | Interactive → GATE 1 | Create implementation plan, assemble full freeze doc, get user approval |
| 4. Test Planning | Autonomous | Design layered test approach, produce test plan |
| 5. Implementation + Layer 1 Review | Autonomous | TDD implementation; multi-agent consensus review (convergence required) |
| 6. Verification + Coverage Fill + Layer 2 Review | Autonomous | Run all tests, fill coverage gaps, final multi-agent review |
| 7. Documentation + Mistake Capture → GATE 2 | Autonomous → GATE 2 | Update docs, aggregate patterns, final user approval authorizes push |

## Phase Details

### Phase 1: Requirements

**Goal:** Validated, complete, testable requirements with zero unresolved issues; freeze doc §1 (Business Logic), §5 (Error Model), §6 (Acceptance Criteria) populated.

1. Gather information from the user through one-at-a-time clarifying questions (interactive) or extract from the ticket (autonomous).
2. Run consensus protocol with `config.pipeline.agents.plan` (default `requirements-analyst, architect, test-strategist`).
3. Invoke `config.pipeline.skills.requirements` (default `superpowers:brainstorming`) for dialogue.
4. Output: requirements document at `docs/specs/[feature-slug]-requirements.md` + freeze doc draft populated for §1/§5/§6.

### Phase 2: Research (Codebase + Architecture)

**Goal:** Understand existing conventions; design sound architecture; populate freeze doc §2 (API Contracts), §3 (3rd Party), §4 (Data), §7 (Security), §8 (Performance).

1. Invoke `config.pipeline.skills.exploration` (default `feature-dev:code-explorer`) to trace execution paths, map architecture layers, document dependencies, identify conventions.
2. Invoke `config.pipeline.skills.architect` (default `feature-dev:code-architect`) to design the feature architecture.
3. Run consensus protocol on the design.
4. Produce ADRs using `references/templates/ADR_TEMPLATE.md`.
5. Populate freeze doc §2/§3/§4/§7/§8. For §2, document existing conventions followed and any proposed deviations with rationale.

### Phase 3: Plan + Freeze Doc Assembly → GATE 1

**Goal:** Detailed implementation plan + completed freeze doc approved by the user.

1. Invoke `config.pipeline.skills.planning` (default `superpowers:writing-plans`) for structured plan creation.
2. Assemble the freeze doc (see `references/templates/FREEZE_DOC_TEMPLATE.md`) — aggregate §1-§8 into `docs/specs/[feature-slug]-freeze.md`. Populate §9 from `config.pipeline.freezeDoc.nonFrozenAllowList`. Render any custom categories from `config.pipeline.freezeDoc.customCategoryTemplatesDir`.
3. Run consensus protocol (plan + freeze doc as a combined artifact) with `config.pipeline.agents.plan`.
4. Self-review loop per `references/autonomous/review-loop-protocol.md`. Inject chronic patterns as prevention checklist.
5. Set freeze doc `status: PENDING_APPROVAL`.
6. **GATE 1 (user-interactive):** Present the freeze doc + plan to the user for category-structured review. On approval, set freeze doc `status: APPROVED`; record `approvedAt`, `approvedBy`, `approvalMode`. The `freeze-gate.sh` hook then allows `src/**` edits. On rejection of specific categories, reopen the relevant phase and re-run the relevant review loops.
7. Autonomous mode: Phase 3 auto-approves (`approvalMode: autonomous`) with audit decision; GATE 2 is still user-interactive.

### Phase 4: Test Planning

**Goal:** Comprehensive test plan covering all 4 test types with coverage target from `config.pipeline.testCoverageTarget` (default 90%).

1. Invoke `config.pipeline.skills.tdd` (default `superpowers:test-driven-development`) for TDD methodology.
2. Read `references/protocols/test-planning.md`; apply layered plan (Layer 0/1/2 + event-type grouping).
3. Produce `docs/test-plans/[feature-slug]-test-plan.md` + session copy at `{SESSION_DIR}/tdd-plan.md`.
4. Map tests to acceptance criteria (traceability matrix).

### Phase 5: Implementation + Layer 1 Review

**Goal:** Working code that passes all tests, following TDD, with Layer 1 multi-agent review converged to zero valid issues.

1. Invoke `config.pipeline.skills.tdd` — tests first.
2. Invoke `config.pipeline.skills.implementation` (default `superpowers:subagent-driven-development`); alternatives `implementationSequential`/`implementationParallel` per plan structure.
3. **Mandatory Layer 1 review:** read `references/protocols/multi-agent-consensus.md` and run the validate protocol with `config.pipeline.agents.review` (default code-quality, observability, performance). Do NOT substitute a manual single-agent review — the iteration loop is required for convergence.
4. Loop until convergence (`max_iterations: config.pipeline.maxReviewIterations`, default 10; `zero_threshold: config.pipeline.consecutiveZerosToExit`, default 2). See "Critical Rule" in `references/protocols/multi-agent-consensus.md`.
5. Question handling during execution follows freeze doc §9 zones (Frozen → halt; Non-Frozen → may ask; Ambiguous → 4-tier; Self-decide → no question).

### Phase 6: Verification + Coverage Fill + Layer 2 Review

**Goal:** All tests pass, coverage meets threshold, all standards met, Layer 2 review converged.

1. Run all tests (unit, integration, smoke, E2E).
2. Verify branch coverage ≥ `config.pipeline.testCoverageTarget`. Fill gaps with TDD where below.
3. Invoke `config.pipeline.skills.verification` (default `superpowers:verification-before-completion`) to confirm acceptance criteria with evidence.
4. **Mandatory Layer 2 review:** consensus protocol with `config.pipeline.agents.review`, same convergence rules as Phase 5.
5. Scan for frozen-category drift. If any §1-§8 decision has drifted during execution, halt and offer supersede / revert / bypass.

### Phase 7: Documentation + Mistake Capture → GATE 2

**Goal:** Documentation reflects what was built; cross-session learning captured; final user approval authorizes push.

1. Read `references/protocols/project-docs.md`. Update ADRs for implementation deviations, feature specs, test docs. Scope boundary: documentation only — no new features or refactoring.
2. Read `references/autonomous/mistake-tracker-protocol.md`. Aggregate Phase 5 + Phase 6 code issues (not Phase 3 design issues). Match against existing patterns; promote at `config.pipeline.chronicPromotionThreshold`; sync CLAUDE.md chronic patterns between sentinels.
3. **GATE 2 (always user-interactive):** Present review-iteration totals, coverage, standards pass/fail, frozen-decision honor count, bypass count, chronic patterns prevented. User options: [1] Approve, [2] Reject (returns to Phase 5/6), [3] Approve + commit + push.
4. **On approval:** archive bypass records from `bypass.json` and `bypass-audit.jsonl` (filtered by current `runId`) into freeze doc frontmatter `bypassHistory` (dedup by `at`). Delete `bypass.json`. Write `{SESSION_DIR}/pipeline-complete.md` authorizing push. Mark progress-log completed.
