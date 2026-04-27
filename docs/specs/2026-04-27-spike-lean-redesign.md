---
title: "Spike framework lean redesign — YAGNI default + reversibility-weighted design"
date: 2026-04-27
status: design-approved
target: dev-framework:spike skill v1.0.0 → v2.0.0
related:
  - retro-source: Bucket Advisor PR1 (jiho0215/buckitApi PR #23, 30 commits, 3000 LOC)
  - replaces: docs/specs/2026-04-21-spike-implement-split.md (partially)
---

# Spike framework lean redesign

## §0 Background — what motivated this

The Bucket Advisor PR1 close-out (sessions 13-15, ~2 calendar days of active work) shipped 30 commits / ~3000 LOC of production code + ~3000 LOC of tests for what could have been a 5-10 commit / ~800 LOC slice. Post-merge retro identified the spike framework itself as a primary scope-inflation contributor.

**Symptoms in PR1**:
- 50 metric series + 13 alerts planned for a transaction-categorization feature (5-10 + 3 would have sufficed)
- Forward-compat baking in PR1 for PR3/PR4 (e.g., `source=manual` registered but unused, `body.system` array shape changed for PR4 to add 1 line later)
- 2 runbooks + 11 alerts deferred but documented as required
- 13 spike sessions before any code, then 30 commits to land (waterfall mindset in modern garb)
- Multi-agent consensus iterations accumulated low-severity findings as "must-have" — each R1-R6 review iteration grew the spec

**Root cause analysis**:

1. **Phase 1 NFR forced-ask** ("Do not let the user skip any") committed users to SLA / security / privacy / accessibility upfront even when not applicable
2. **Phase 2 templates required §3 Rollout / §4 Observability / §5 API contracts / §6 Migrations** to be filled comprehensively — once filled, items become "must implement"
3. **No prune step** — design flowed straight to decomposition with no "what's NOT MVP?" filter
4. **Phase 3 ticket decomposition** extracted "relevant slices" from epic-level §4-§6 into each ticket — including forward-compat setup
5. **Multi-agent consensus** (3 agents × 10 iterations × 2 zero-rounds-to-exit) generated low-severity findings that became "must-fix" → spec inflation
6. **No size budget** on tickets → PR1 grew to 30 commits without any framework-side gate

**Conclusion**: the framework optimized for thoroughness without a counterweight for scope discipline. The fix is to add the counterweight, not remove thoroughness.

## §1 Goals / non-goals

**Goals**:
- Default behavior produces MVP-sized scopes (Walking Skeleton + reversibility-weighted)
- Forward-compat / nice-to-have / "while we're here" items deferred BY DEFAULT to follow-up
- Multi-agent consensus accepts Minor/Nit findings without blocking exit
- Existing rigorous artifacts (ADRs, runbooks, alerts) stay possible but become opt-in per epic, not default
- Backward-compat: existing `spike-plan.md` files from v1.0.0 keep parsing

**Non-goals**:
- Not removing /spike entirely (multi-PR epics still need cross-ticket coherence)
- Not splitting into /spike-lean and /spike-rigorous two skills (single mode per user direction)
- Not changing `/implement` (separate concern; this redesign targets /spike only)
- Not changing event-log architecture or session-management semantics
- Not adding new orchestration phases beyond the one (Phase 2.5) needed for prune

## §2 Foundational frameworks (research benchmarks)

The redesign synthesizes established industry frameworks rather than inventing new ones:

| Framework | Source | Spike application |
|---|---|---|
| **Walking Skeleton** | Alistair Cockburn | Phase 2 §9 — define thinnest end-to-end slice that exercises every architectural seam once |
| **Two-Way Doors** | Jeff Bezos / Pragmatic Programmer reversibility | Phase 2 §2.1 — every decision tagged `[type-1]` (one-way, ADR required) or `[type-2]` (two-way, lightweight) |
| **Evolutionary Architecture** | Neal Ford / Rebecca Parsons | Phase 2 §2.2 — fitness functions as CI checks (architecture properties enforced by code, not prose policy) |
| **Spike-and-Stabilize** | Dan North | Implicit — spike is risk-validation only; production readiness comes from `/implement`, not from spike comprehensiveness |
| **Strangler Fig** | Martin Fowler | Phase 3 ticket cuts — explicit "this ticket strangles X; that strangles Y next epic" |
| **Tidy First?** | Kent Beck (2024) | Phase 2.5 prune rule — "while we're here..." items go to follow-up, not current epic |
| **DORA / Accelerate** | Forsgren, Humble, Kim | Phase 3 ticket size budget (≤400 LOC green, 400-800 yellow, >800 red) — research-backed correlation between PR size and reliability |
| **ADRs** | Michael Nygard | Phase 2 — only for type-1 decisions, not all architectural choices |

## §3 Design — six changes

### §3.1 Philosophy

**Old**: comprehensive upfront design, "fill every section", reviewers find missing things.

**New**: **YAGNI-default + reversibility-weighted minimum.** Hard-to-reverse decisions get full treatment; easy-to-reverse decisions ship with one-line capture and iterate post-deploy.

**What stays**: 5-phase structure, plan-doc-as-PR-artifact, event log + shared epic session with `/implement`, retro mechanism.

**What changes**: Phase 0 added; Phase 1 NFR triaged; Phase 2 reversibility-tagged + fitness-functions; Phase 2.5 added; Phase 3 size-budgeted + MVP/Future split; Phase 4 removal pass + severity-gated consensus.

### §3.2 Phase 0 (NEW) — Scope-or-implement gate

Before Phase 1, run a 2-question gate:

**Q1**: "Could this epic ship as a single PR (~500 LOC)?" Yes → exit /spike with: `"Use /dev-framework:implement <ticket> instead. Spike adds overhead for single-PR work."`

**Q2** (if Q1=no): "How many PRs do you anticipate?" 1 → same as Q1=yes. 2-4 → continue. 5+ → flag scope warning, ask user to confirm or split into sub-epics.

**Implementation**: SKILL.md "Pre-Workflow" 단계 직후, "Section S Phase 1" 진입 전. ~20 LOC.

### §3.3 Phase 1 — Triaged NFR

**Old** (SKILL.md line 166): "ask explicitly about each of: SLA, security threat model, privacy / compliance, accessibility. **Do not let the user skip any**."

**New**: Single triage question, follow-ups only on applicable categories:

```
이 epic이 다음 중 어떤 거에 해당해?
[ ] 새 user-facing 엔드포인트 / API → SLA 질문
[ ] PII / 사용자 데이터 처리 → privacy 질문
[ ] 새 user-visible UI → accessibility 질문
[ ] 인증 / 권한 변경 → security threat model 질문
[ ] 위 어느 것도 아님 → NFR 섹션 omit
```

If all unchecked: `spike-plan.md` §1 keeps the goal + success criteria but **omits the NFR sub-section entirely** (not "N/A" placeholder — full omission of the sub-section block). §1 itself is never omitted — every epic has at least a goal and success criteria.

**Implementation**: SKILL.md Phase 1 §3 NFR rewrite (line 166-167). ~15 LOC.

### §3.4 Phase 2 — Reversibility-weighted design

**§2.1 Architectural decisions** — each decision tagged:
- **`[type-1]`** (one-way door): formal ADR via `../implement/references/templates/ADR_TEMPLATE.md`, included in cross-ticket review
- **`[type-2]`** (two-way door): one-line note in spike-plan, no ADR

**Type-1 examples** (from PR1 retro):
- AC18 event schema (`AdvisorPlanAppliedEvent`) — consumers depend on shape
- Wire-level metric names (`advisor_feedback_recorded_total`) — dashboards depend
- Span event names (`ghost_bucket_rejected`) — alert queries depend
- Module boundary (`Buckit.AutoBucket` vs `BuckitApi`) — refactor cost high

**Type-2 examples** (from PR1 retro):
- Counter additions (just add the line)
- Alert thresholds (config change)
- Internal class hierarchies
- Test coverage levels
- Documentation depth
- Forward-compat tag values (e.g., registered allowed-values widening)

**§2.2 Fitness functions** (NEW sub-section, brief — 1-3 properties):
CI checks that automatically enforce architecture properties. Examples:
- "Module X NEVER references Module Y" (NetArchTest)
- "Public API endpoint count ≤ N" (lint)
- "Cardinality budget ≤ 500 series" (CardinalityBudgetTests)

Properties without fitness functions are NOT policy — don't include them in design prose. Either codify or omit.

**§3 Rollout/rollback** — conditional on flag: "Does this epic ship behind a flag?" If no → "N/A — direct deploy" one-liner. If yes → existing template.

**§4 Observability** — minimum-first table (1-3 metrics + 1-2 alerts maximum) at top. `### Future (opt-in per ticket)` empty section below — populated by tickets that need it during /implement.

**§5 API contracts** — MVP / Deferred two sub-sections. Deferred for context only ("future PRs will add X / Y / Z, listed here for understanding").

**§6 Migration chain** — conditional: "Does this epic touch DB schema?" no → "N/A".

**§9 (NEW) Walking skeleton path** — one paragraph: "The thinnest end-to-end slice that exercises every architectural seam exactly once is: ..."

**§10 (NEW) Deferred items** — populated from Phase 2.5 prune. Each entry: rationale + when to revisit.

**Implementation**: SKILL.md Phase 2 (line 183-204) rewrite, SPIKE_PLAN_TEMPLATE.md restructure. ~80 LOC SKILL.md, full template rewrite (~150 LOC).

### §3.5 Phase 2.5 (NEW) — Scope prune

After Phase 2 design, before Phase 3 decomposition. Single-agent pass + user review.

**Single-agent prune task**:
> Review spike-plan.md §2-§6. List items that are NOT required for the first ship to be useful. Classify each:
> - `forward-compat` — preparing for future PR; current epic could ship without it
> - `nice-to-have` — improvement opportunity, not correctness
> - `while-we-here` — unrelated cleanup that snuck in
> - `future-need` — speculative requirement without current evidence

**Artifact flow** (clarifies relationship between `MVP-SCOPE.md` and `spike-plan.md` §9/§10):

1. Phase 2.5 agent produces a working doc `docs/plan/{epic}/MVP-SCOPE.md` listing every spike-plan candidate item with proposed classification (in-scope / deferred / type).
2. User reviews and overrides as needed.
3. **After user approval**, two folds happen:
   - The **walking skeleton path** (one-paragraph description) is folded INTO `spike-plan.md` §9 (Walking skeleton path)
   - The **deferred items** (with rationale + when-to-revisit) are folded INTO `spike-plan.md` §10 (Deferred items)
4. `MVP-SCOPE.md` then persists as an **archived audit trail** of the prune decision — what was originally proposed vs what survived. Future epics' retros reference it; production code does not.

In other words: `MVP-SCOPE.md` is the working doc; `spike-plan.md` §9/§10 are the canonical ship-ready references. They are NOT duplicate sources of truth — `MVP-SCOPE.md` is historical, the spike-plan sections are authoritative for the active epic.

**Why a separate phase**: forces an explicit "what comes out" step. Current framework only has "what goes in" steps.

**Banner**: `--- Spike Phase 2.5 Complete: Scope Prune (deferred ${count} items) ---`

**Emit**: `spike.phase.2.5.started` / `.completed`, `spike.scope.pruned` with `{epicId, deferredCount, items: [{type, summary}]}`.

**Implementation**: New phase in SKILL.md (~50 LOC), new yaml `phases/spike-phase-2.5.yaml`, new template `MVP_SCOPE_TEMPLATE.md`.

### §3.6 Phase 3 — Ticket size budget + MVP/Future split

**Size budget** (DORA-based):

| Estimated LOC | Status | Action |
|---|---|---|
| ≤ 400 | Green | Default. Proceed. |
| 400-800 | Yellow | Prompt: "Can this be split? If not, justify." Justification recorded in `decision-log.json`. |
| > 800 | Red | Force decompose into sub-tickets. |

`estimatedLoc` field added to TICKET_REF_TEMPLATE.md frontmatter.

**MVP / Deferred two-column structure** in §3 / §4 / §5 of each ticket ref:

```markdown
## §3 API contract slice

### MVP (this PR)
- POST /api/foo
- GET /api/foo/{id}

### Deferred (future PR — context only, NOT to implement here)
- DELETE /api/foo/{id}     ← bad-02
- POST /api/foo/{id}/share ← bad-03
```

**Forward-compat detection** in Phase 3 dialogue:
When user mentions "and we'll need X for PR3", framework prompts:
```
"X is forward-compat. Can this PR ship without it?
- Yes → automatic deferred (added to ticket §3 Deferred column)
- No → MVP, justify why blocking"
```

**Implementation**: SKILL.md Phase 3 (line 215-242) updates. TICKET_REF_TEMPLATE.md restructure. ~40 LOC SKILL.md changes, ~50 LOC template changes.

### §3.7 Phase 4 — Severity-gated review + Removal pass

**Removal pass** (NEW step, before multi-agent gap review):

Single-agent task:
```
Read spike-plan.md and all ticket refs.
Identify items that should be REMOVED (not added). Classify:
- forward-compat (defer to next epic)
- nice-to-have (evidence-free wishlist)
- already-covered (redundant with another section)
- truly redundant (duplicate)
```

User reviews, removes approved items. Then proceed to multi-agent gap review.

**Severity-gated multi-agent consensus**:

| Phase | Agents | Max iter | Exit gate |
|---|---|---|---|
| Phase 1 (requirements) | 1 | 10 | zero Critical + zero Major |
| Phase 2 (architecture) | 1 | 10 | zero Critical + zero Major |
| Phase 4 (gap review) | 2 | 10 | zero Critical + zero Major |

**Severity rubric** (in reviewer agent prompts):
```
Critical: ship 시 data corruption / security breach / production outage 가능
Major:    oncall이 incident 디버그 불가 / documented contract 깨짐 / concurrency bug
Minor:    system 동작. 개선 기회. (test coverage gap, naming, completeness)
Nit:      style / 문서 / 부가 thoroughness
```

**Minor / Nit handling**: appended to `docs/plan/{epic}/review-backlog.md` (NEW artifact). Don't block exit. Each entry has rationale + suggested handling location (`/implement` Phase 4 / follow-up epic / dismissed).

**Reviewer prompt rewrite** (SKILL.md line 254-259) equally weights "remove" vs "missing":
```
Coverage check (additive): epic §1 requirements 중 ticket 셋이 안 다루는 게 있나?
Pruning check (subtractive): MVP에 안 들어가도 되는 게 ticket에 baked in 됐나?
  - Forward-compat (다음 PR을 위한 setup) → defer
  - "While we're here" (관련 없는 cleanup) → 별도 ticket
  - "In case of..." (실증 없는 future-proof) → defer
  - Reversibility: Type 2 (easy-to-reverse) decisions are over-designed?
Dependency check: hard blocker가 실제로 hard인가?
```

**Implementation**: 
- SKILL.md Phase 4 (line 244-282) rewrite — ~50 LOC
- `../implement/references/protocols/multi-agent-consensus.md` — severity rubric + reviewer prompt template, ~40 LOC
- `REVIEW_BACKLOG_TEMPLATE.md` (NEW) — ~25 LOC
- Multi-Agent Consensus section in SKILL.md (line 73-79) — defaults updated

### §3.8 Templates summary

| File | Action | LOC |
|---|---|---|
| `references/templates/SPIKE_PLAN_TEMPLATE.md` | full rewrite — minimum-first, conditional sections, type-1/2 tagging, fitness functions, walking skeleton, deferred items | ~150 |
| `references/templates/TICKET_REF_TEMPLATE.md` | restructure — MVP/Deferred columns, estimatedLoc, mvpScope frontmatter | ~120 |
| `references/templates/MVP_SCOPE_TEMPLATE.md` | NEW — Phase 2.5 prune output | ~30 |
| `references/templates/REVIEW_BACKLOG_TEMPLATE.md` | NEW — severity-gate Minor/Nit accumulator | ~25 |
| `phases/spike-phase-2.5.yaml` | NEW — dispatcher metadata | ~30 |

### §3.9 Backward-compat

**Existing spike-plan.md files (v1.0.0 format)**:
- `/spike --status` parses both formats
- `/spike --from N` resumes on existing format; new sections (§9, §10) optional, prompted-but-skippable
- `/implement` reads ticket refs in either format; missing MVP/Deferred sub-headers → entire section interpreted as MVP

**Frontmatter migration**: `estimatedLoc` and `mvpScope` are optional fields (default `estimatedLoc: null`, `mvpScope: required`). Old files parse cleanly.

**Existing event-log entries**: schema unchanged. New events (`spike.phase.2.5.started`, `spike.scope.pruned`) are additive; reducers ignore unknown event types.

## §4 Implementation plan

### §4.1 Files modified

```
plugins/dev-framework/skills/spike/SKILL.md
plugins/dev-framework/skills/spike/references/templates/SPIKE_PLAN_TEMPLATE.md
plugins/dev-framework/skills/spike/references/templates/TICKET_REF_TEMPLATE.md
plugins/dev-framework/skills/implement/references/protocols/multi-agent-consensus.md
```

### §4.2 Files created

```
plugins/dev-framework/skills/spike/references/templates/MVP_SCOPE_TEMPLATE.md
plugins/dev-framework/skills/spike/references/templates/REVIEW_BACKLOG_TEMPLATE.md
plugins/dev-framework/skills/spike/phases/spike-phase-2.5.yaml
```

### §4.3 Total LOC

~575 LOC across 7 files. Roughly:
- SKILL.md: +180 (Phase 0 + Phase 2.5 + reversibility tagging + fitness functions + severity rubric + removal pass) / -50 (line 166 NFR forced-ask, line 73-79 default agents)
- SPIKE_PLAN_TEMPLATE.md: +150 / -108 = full rewrite
- TICKET_REF_TEMPLATE.md: +120 / -84 = full rewrite
- multi-agent-consensus.md: +40
- MVP_SCOPE_TEMPLATE.md: +30 (new)
- REVIEW_BACKLOG_TEMPLATE.md: +25 (new)
- spike-phase-2.5.yaml: +30 (new)

### §4.4 Suggested commit order

Each commit individually green (skill metadata is parsed at runtime; templates are read on demand):

1. **Templates first** — SPIKE_PLAN_TEMPLATE.md, TICKET_REF_TEMPLATE.md rewrite. New MVP_SCOPE_TEMPLATE.md, REVIEW_BACKLOG_TEMPLATE.md. (Templates are static; safe to land before SKILL.md references them.)
2. **multi-agent-consensus.md** severity rubric addition. Existing `/implement` consumers ignore the new rubric until reviewer prompts reference it; safe.
3. **SKILL.md rewrite** in 4 logical chunks for review tractability:
   3a. Phase 0 scope gate + Pre-Workflow integration
   3b. Phase 1 NFR triage rewrite
   3c. Phase 2 reversibility-weighted + fitness functions sub-section
   3d. Phase 2.5 prune phase + SKILL.md table-of-contents updates
   3e. Phase 3 size budget + MVP/Future split + forward-compat detection
   3f. Phase 4 removal pass + severity-gated consensus + reviewer prompt rewrites
   3g. Multi-Agent Consensus defaults section + Performance Budgets refresh
4. **spike-phase-2.5.yaml** — new dispatcher yaml.
5. **README / discoverability** — update `dev-framework` plugin manifest description if needed (SKILL.md frontmatter `description` field references "5 phases" → update to "5+1 phases" or restructure).

## §5 Validation plan

**Self-application test**: re-run /spike on the Bucket Advisor work as a thought experiment. Expected outcome:
- Phase 0: passes (4-PR epic)
- Phase 1: SLA / privacy / a11y all "no" → NFR section omitted
- Phase 2: 50 metric series → fitness function "cardinality ≤ 50 series declared, MVP emit ≤ 10". Most observability moves to "Future (opt-in)" section.
- Phase 2.5: forward-compat items (source=manual register, body.system reshape, etc.) all moved to Deferred. PR1 scope estimated ~800 LOC instead of 3000.
- Phase 3: ticket size budget catches 30-commit PR1 design → forces decomposition into 3-4 smaller tickets.
- Phase 4: severity-gated → 6 review fixes resolve in ~2 iterations instead of 6.

If the redesign produces ~800 LOC PR1 with all critical/major contracts intact, validation passes.

**Empirical validation**: next non-trivial epic uses redesigned spike. Compare LOC + commit count + cycle time against historical baseline (bucket-advisor PR1 = 30 commits / 3000 LOC / 2 calendar days).

## §6 Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Severity rubric inflation (every finding marked Critical) | Medium | Concrete rubric language ("data corruption / security breach / production outage" gates Critical). User can override with rationale. Inflation patterns surface in Phase 5 retro. |
| Type-1 / Type-2 ambiguity (decisions hard to classify) | Medium | Provide examples in template. Default to Type-2 when unclear (favors faster iteration; if wrong, costs one rework cycle). |
| Walking skeleton too thin to be meaningful | Low | Phase 2 §9 has explicit "exercise every architectural seam once" criterion. If a seam isn't exercised, that's the test. |
| Phase 2.5 prune skipped or rubber-stamped | Medium-high | Prune is a phase with its own gate + emit. Cannot proceed to Phase 3 without it. Backlog file enforces visibility. |
| Backward-compat breaks for in-flight epics (Bucket Advisor's bad-02..bad-04 still planned in v1 format) | Low | Backward-compat section §3.9 — both formats parse. Optional new fields default safely. |
| Users continue to over-scope despite framework | Low (not framework's job to override user judgment) | Framework reduces friction toward MVP path. User can still go big with explicit overrides; those overrides are at least visible in `decision-log.json`. |

## §7 Open questions

None — all design choices resolved through dialogue. Ready for implementation plan.

## §8 Out of scope (explicit)

These are NOT in this redesign:
- Changes to `/implement` skill (separate concern; would be follow-up if same patterns emerge there)
- Changes to event-log architecture or session-management
- Changes to `wake.sh` or status semantics
- Tracker integration (out per v1.0.0 design too)
- Pre-spike intake / triage (same)

## §9 Success criteria

The redesign succeeds when:
1. Next epic that goes through /spike produces a spike-plan.md ≤ 500 lines (current Bucket Advisor: 1800+ lines)
2. First ticket per epic averages ≤ 800 LOC (current Bucket Advisor PR1: 3000 LOC)
3. Multi-agent consensus exits in ≤ 3 iterations on average (current: 6)
4. Review backlog file (`review-backlog.md`) is non-empty (proves Minor/Nit findings are being captured, not just dismissed)
5. Phase 5 retro after first lean-mode epic shows reduced chronic-design-pattern accumulation rate
