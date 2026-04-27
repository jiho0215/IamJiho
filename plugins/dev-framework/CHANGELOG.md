# Changelog

All notable changes to the `dev-framework` plugin.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## 4.2.0 — 2026-04-27

### Changed
- `/dev-framework:spike` v1.0.0 → v2.0.0 — **lean redesign**. Motivated by Bucket Advisor PR1 retro: framework optimized for thoroughness without a counterweight for scope discipline. v2.0 adds the counterweight at minimum cost (~230 LOC across 3 files + 1 new template).
  - **Phase 0 scope-or-implement gate** (NEW) — single-PR work redirected to `/implement`; spike only for genuinely multi-PR epics
  - **Phase 1 NFR triaged** — replaces forced-ask ("Do not let the user skip any") with a checkbox triage; unchecked categories are fully omitted, no "N/A" placeholder
  - **Phase 2 inline scope prune** — at end of Phase 2, single-agent task classifies items as forward-compat / nice-to-have / while-we-here / future-need; deferred items folded into spike-plan.md §10 (NEW). NOT a separate Phase 2.5 (avoids new yaml + banner + emit ceremony — defers structural promotion to v2.1 if evidence warrants)
  - **Phase 3 forward-compat detection** — when user mentions "and we'll need X for PR3", framework prompts whether THIS PR ships without X (yes → automatic deferred). Soft size guidance (≥800 LOC consider split); no hard threshold
  - **Phase 4 reviewer prompt rewrite** — equally weights ADD and REMOVE concerns. Pruning check (subtractive) added alongside Coverage check (additive)
  - **Severity-gated multi-agent consensus** — Critical+Major block exit; Minor+Nit append to `review-backlog.md` (NEW template) without blocking. Hard cap 10 iterations. Agents reduced 3/3/3 → 1/1/2 (Phase 1/2/4) reflecting that consensus quality plateaus after the first few rounds
  - **Power-user escape hatch** (NEW SKILL.md section) — framework defaults lean BUT does not block users from manually adding sections to spike-plan.md / ticket refs for genuine enterprise contexts (HIPAA, high-scale, external API consumers). Cost-awareness explicit
- `multi-agent-consensus.md` — new `exit_on` parameter (`zero_total` back-compat default / `zero_blocking` opt-in for severity gating). New `backlog_path` parameter for routing non-blocking findings. Concrete severity rubric with anti-inflation guardrails. Step 4 iteration check updated for both modes. **Back-compat**: existing /implement consumers see no behavior change (defaults to zero_total).

### Added
- `skills/spike/references/templates/REVIEW_BACKLOG_TEMPLATE.md` — Minor/Nit findings accumulator with disposition log section (accepted / deferred / dismissed tracking).
- `docs/specs/2026-04-27-spike-lean-redesign.md` — full design spec capturing v2.0 changes + v2.1 deferred items + research benchmarks (Walking Skeleton, Two-Way Doors, Evolutionary Architecture, Spike-and-Stabilize, Strangler Fig, Tidy First?, DORA, ADRs).

### Notes
- v2.1 items (type-1/2 forced tagging, fitness functions section, walking skeleton paragraph mandate, MVP-SCOPE.md separate artifact, Phase 2.5 numbered phase, hard 400/800 LOC threshold, removal pass separate step, full template rewrites) are **deferred until evidence**: post-v2.0 retro must show 2+ epics where the missing item caused over-scope before promotion. Without that evidence, promoting them would repeat the over-engineering pattern v2.0 is supposed to fix.
- Existing v1.0 spike-plan.md files keep parsing — `/spike --status`, `--from N`, and `/implement` consumption all work unchanged. New §10 (Deferred items) is additive in v2.0 spike runs only.

## 4.1.0 — 2026-04-22

### Added
- `/dev-framework:testbuilder` skill — standalone testing workflow. Takes any repo state (TDD starter tests from `/implement`, legacy tests, manual tests, or nothing) and builds a formalized, complete test suite at 95%+ **case coverage** across unit, integration, and E2E tiers, organized under one `TESTING.md` per repo. Pure function of repo state — does not depend on `/implement`. 6 phases: Assess → Gap Analysis → Design → Build → Document (TESTING.md) → Verify.
- `skills/testbuilder/references/standards/HYGIENE.md` — no empty test shells; `[Skip]` requires tracking link + exit criterion + truthful message (grep-verifiable); no `.only`/`.skip` leaks; Known Gaps ledger enforced.
- `skills/testbuilder/references/standards/DEPENDENCY_POLICY.md` — 3rd-party → mock; internal services → Docker (image-pinned, health-gated). Never invert.
- `skills/testbuilder/references/standards/BLACKBOX_BOUNDARY.md` — tier placement rules; E2E has zero source `ProjectReference`; compose uses `image:` tag only.
- `skills/testbuilder/references/protocols/coverage-gap-analysis.md` — multi-agent Phase 2 consensus. Two-dimensional coverage (code + case); default 10-item case checklist per entry point; 95% case-coverage target.
- `skills/testbuilder/references/protocols/ci-organization.md` — orphan detection, redundancy detection, filter correctness, CI-vs-local parity audit.
- `skills/testbuilder/references/templates/TESTING_MD_TEMPLATE.md` — the per-repo testing-ledger skeleton with 7 sections (Overview / Run / CI / Writing / Coverage / Known Gaps / Appendix).
- `/dev-framework:testbuilder --init` mode — scaffold `TESTING.md` for a new or legacy repo.
- `/dev-framework:testbuilder --audit` mode — report gaps without writing.
- `commands/testbuilder.md` command passthrough.

### Changed
- Plugin description expanded to cover three skills (spike, implement, testbuilder).
- Keywords: added `testbuilder`, `case-coverage`, `testing-mothership`, `mock-vs-docker`, `skip-hygiene`, `blackbox-boundary`.

### Removed
- `commands/dev.md` tombstone — the `/dev-framework:dev` → `/dev-framework:implement` redirect shipped in v4.0.0 is now gone. Typing `/dev-framework:dev` yields "unknown command"; use `/dev-framework:implement` instead.

### Notes
- `/testbuilder` runs independently of `/implement`. No dispatch, no handoff contract — the two skills share only the epic-scoped event log when invoked against the same epic. Ad-hoc invocation against a legacy module or greenfield repo is a first-class mode.
- `/implement`'s Phase 4 Test Planning and Phase 6 Coverage Fill are unchanged. Tests it produces (or doesn't produce) are simply input to `/testbuilder` Phase 1; `/testbuilder` Phase 5 (Document) has absolute authority to rewrite or delete any existing test that violates HYGIENE/DEPENDENCY_POLICY/BLACKBOX_BOUNDARY, regardless of origin.

## 4.0.0 — 2026-04-21

### Breaking
- `/dev-framework:dev` renamed to `/dev-framework:implement`. Tombstone provided for v4.0.x; removed in v4.1.0.
- Session folder keying changed from `{repo}--{branch}` to `{repo}--epic-{epicId}`. Ad-hoc `/implement` synthesizes `epicId = ad-hoc-<sanitized-branch>` for backward compatibility; existing in-flight sessions must either finish on v3.0.1 or be restarted on v4.0.0.

### Added
- `/dev-framework:spike` skill for multi-ticket research and decomposition (5 phases; Phase 5 retro is async and fires after all tickets merge).
- Plan-doc convention at `<repo>/docs/plan/{epicId}/` with `spike-plan.md` and per-ticket ref docs; PR-reviewable.
- `/implement` Phase 0 "Prereq Check" for spike-sourced tickets (hard/soft blocker validation; freeze-doc §1-§5 pre-seeding).
- Bi-directional events: `ticket.started` / `ticket.discovery` / `ticket.merged` / `spike.*`.
- Reducers: `reduce-spike-plan.sh` (§7 registry) and `reduce-ticket-doc.sh` (§6 impl log + frontmatter status).
- Retro-per-skill: design-pattern variant at `~/.claude/autodev/chronic-design-patterns.json` with taxonomy `architecture / boundary / interface / migration / coupling / scoping / observability`.
- `domain` discriminator (`code | design`) on `patterns.*` events.

### Changed
- `load-chronic-patterns.sh` now loads both code and design chronic stores at SessionStart; emits `patterns.loaded` once per populated domain.
- `events-schema.md` extended with `spike.*` and `ticket.*` catalogs.
- `regenerate-views.sh` invokes two new reducers unconditionally (they no-op safely off-epic).

### Deprecated
- `/dev-framework:dev` command (tombstone redirect only; removed in v4.1.0).

## 3.0.1 — 2026-04-20

### Fixed
- Removed duplicate `hooks` reference in plugin manifest (caused double-registration on some Claude Code versions).

## 3.0.0 — 2026-04-20

### Added
- Managed Agents architecture rollup: event log (`events.jsonl`), atomic `seq`, reducer-regenerated views, `wake.sh` stateless restart, `replay.sh` seq-level rewind, phase YAML dispatcher (`read-phase.sh`, `execute.sh`), multi-brain fan-out.
- `modelProfile` config knob (`conservative` / `balanced` / `trust-model`) for tuning iteration caps + review agent fan-out.
