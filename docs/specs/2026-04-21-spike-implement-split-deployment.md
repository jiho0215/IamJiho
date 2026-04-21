---
title: "Deployment Checklist — Spike/Implement Split (v4.0.0)"
spec: docs/specs/2026-04-21-spike-implement-split.md
version: 4.0.0
type: deployment-checklist
status: draft
author: dev-framework team
createdAt: 2026-04-21
---

# Deployment Checklist — Spike/Implement Split (v4.0.0)

Companion to [the main design spec](./2026-04-21-spike-implement-split.md). Covers three concerns in order:

1. **Static verification** — can be run automatically or by a reviewer without invoking Claude Code.
2. **Dog-food scenarios** — manual end-to-end walks the skills cannot self-test from inside Claude Code (since Claude Code *is* what runs them).
3. **Release checklist** — version bump, changelog, post-deploy checks.

Do not ship v4.0.0 until every box in §1 is ticked. Dog-food (§2) is strongly recommended pre-ship but may be deferred to a point release if urgent.

---

## 1. Static Verification (must pass before merge)

### 1.1 Plugin manifest integrity

Run from repo root:

```bash
jq '.version, .name' plugins/dev-framework/.claude-plugin/plugin.json
ls plugins/dev-framework/commands/
```

Expected:
- `"4.0.0"` (or the tag being released)
- `"dev-framework"`
- Command files listed include at minimum: `implement.md`, `spike.md`, `dev.md` (tombstone). Commands are auto-discovered from `commands/*.md` — `plugin.json` does not enumerate them.

Also verify no orphaned references to `/dev-framework:dev` survive in the plugin source tree (docs/ may legitimately reference the old name in specs and deployment files):

```bash
grep -rE 'dev-framework:dev\b' plugins/dev-framework/ 2>/dev/null \
  | grep -vE 'commands/dev\.md' \
  | grep -vE 'v4\.0\.0 tombstone|renamed|deprecated' \
  | grep -vE 'CHANGELOG\.md'
```

Expected: empty output. (Documentation under `docs/specs/` is allowed to mention the old command name for historical context.)

### 1.2 File inventory

```bash
# Skill files exist
test -f plugins/dev-framework/skills/implement/SKILL.md
test -f plugins/dev-framework/skills/spike/SKILL.md

# Command thin-routers exist
test -f plugins/dev-framework/commands/implement.md
test -f plugins/dev-framework/commands/spike.md
test -f plugins/dev-framework/commands/dev.md  # tombstone

# Phase YAMLs
for n in 1 2 3 4 5 6 7; do test -f plugins/dev-framework/phases/phase-$n.yaml; done
for n in 1 2 3 4 5;     do test -f plugins/dev-framework/phases/spike-phase-$n.yaml; done

# New reducers
test -f plugins/dev-framework/hooks/scripts/reduce-spike-plan.sh
test -f plugins/dev-framework/hooks/scripts/reduce-ticket-doc.sh

# Design-variant mistake tracker
test -f plugins/dev-framework/skills/spike/references/autonomous/mistake-tracker-protocol.md

# Plan templates
test -f plugins/dev-framework/skills/spike/references/templates/SPIKE_PLAN_TEMPLATE.md
test -f plugins/dev-framework/skills/spike/references/templates/TICKET_REF_TEMPLATE.md
```

All `test -f` commands return exit 0.

### 1.3 Script syntax check

Every shell script in `plugins/dev-framework/hooks/scripts/` must pass `bash -n`:

```bash
for f in plugins/dev-framework/hooks/scripts/*.sh; do
  bash -n "$f" || { echo "SYNTAX FAIL: $f"; exit 1; }
done
echo "All scripts: syntax OK"
```

Optionally (warnings-only): run `shellcheck plugins/dev-framework/hooks/scripts/*.sh` and confirm no new SC2-series errors vs the v3.0.1 baseline.

### 1.4 Phase YAML parseability

Every phase YAML must be readable by `read-phase.sh`:

```bash
for y in plugins/dev-framework/phases/*.yaml; do
  phase=$(bash plugins/dev-framework/hooks/scripts/read-phase.sh "$y" phase)
  name=$(bash plugins/dev-framework/hooks/scripts/read-phase.sh "$y" name)
  [ -n "$phase" ] && [ -n "$name" ] || { echo "YAML READ FAIL: $y"; exit 1; }
  echo "$y → phase=$phase name=$name"
done
```

Expected: 12 lines output (7 implement + 5 spike), each with non-empty `phase` and `name`.

### 1.5 Sentinel round-trip in templates

Both plan templates must carry their sentinel markers verbatim:

```bash
grep -qF '<!-- BEGIN AUTO-GENERATED REGISTRY -->' \
  plugins/dev-framework/skills/spike/references/templates/SPIKE_PLAN_TEMPLATE.md
grep -qF '<!-- END AUTO-GENERATED REGISTRY -->' \
  plugins/dev-framework/skills/spike/references/templates/SPIKE_PLAN_TEMPLATE.md
grep -qF '<!-- BEGIN AUTO-GENERATED IMPL LOG -->' \
  plugins/dev-framework/skills/spike/references/templates/TICKET_REF_TEMPLATE.md
grep -qF '<!-- END AUTO-GENERATED IMPL LOG -->' \
  plugins/dev-framework/skills/spike/references/templates/TICKET_REF_TEMPLATE.md
echo "Sentinels: OK"
```

### 1.6 Cross-reference integrity

All relative-path references from `/spike` to `/implement` must resolve. Both skills are siblings under `skills/`, so the canonical shape is `../implement/references/...`:

```bash
cd plugins/dev-framework/skills/spike
grep -oE '\.\./implement/references/[A-Za-z0-9/_.-]+\.md' SKILL.md \
  | sort -u \
  | while read p; do
      [ -f "$p" ] && echo "OK   $p" || echo "MISS $p"
    done

# Also check phase YAMLs (requiredRefs are resolved by the dispatcher relative to
# skills/<skill>/references/, so `../../implement/references/...` in a spike phase YAML
# resolves from skills/spike/references/ — cd there before testing).
cd ../../skills/spike/references
grep -hoE '\.\./\.\./implement/references/[A-Za-z0-9/_.-]+' ../../../phases/spike-phase-*.yaml \
  | sort -u \
  | while read p; do
      [ -f "$p" ] && echo "OK   phases: $p" || echo "MISS phases: $p"
    done
```

Expected: every printed path has `OK`, none `MISS`.

### 1.7 Event schema completeness

All new v4.0 event types must appear in the schema doc:

```bash
doc=plugins/dev-framework/skills/implement/references/autonomous/events-schema.md
for t in spike.started spike.phase.N.started spike.phase.N.completed \
         spike.tickets.decomposed spike.gate.approved spike.gate.rejected \
         spike.integration.verified spike.retro.completed \
         ticket.decomposed ticket.started ticket.discovery ticket.merged; do
  grep -qF "\`$t\`" "$doc" || { echo "SCHEMA MISSING: $t"; exit 1; }
done
echo "Event schema: complete"
```

### 1.8 Tombstone behavior

`commands/dev.md` must route users to `/implement`, not silently do nothing. Read the file; confirm it contains both:
- A user-visible deprecation message
- A pointer to `/dev-framework:implement`

```bash
grep -iq 'implement' plugins/dev-framework/commands/dev.md \
  && grep -iq -E 'deprecated|renamed|v4\.0' plugins/dev-framework/commands/dev.md \
  && echo "Tombstone: OK"
```

---

## 2. Dog-Food Scenarios (manual, strongly recommended)

These scenarios verify end-to-end behavior that can't be caught by static checks. Each scenario ends with concrete expected observations — not "it works," but "check this file, look for this field."

Pre-conditions for all scenarios:
- Clean working tree on a test branch (NOT `main`)
- `~/.claude/autodev/config.json` exists (or is willing to be created by `ensure-config.sh`)
- `jq` is on PATH
- A throwaway repo or scratch directory where plan-docs can be freely created

### Scenario A — Happy path: spike → decompose → implement → retro

**Goal:** confirm the full bi-directional flow works end-to-end on a toy epic.

**Steps:**

1. In a fresh worktree, invoke: `/dev-framework:spike Build a greeter service that says hi in Korean, English, and Japanese`
2. Answer `/spike` Phase 1 questions (or let it autonomously synthesize — the toy epic is small enough that 2-3 clarifying exchanges suffice).
3. Let Phase 2 produce the epic architecture. It should reach `docs/plan/<epicId>/spike-plan.md` with populated §1-§6 and an empty §7 between the sentinels.
4. Phase 3 should emit `ticket.decomposed` events — watch the registry populate. Typical expected output: 2-4 tickets (`greeter-ko`, `greeter-en`, `greeter-ja`, maybe `greeter-api`).
5. Approve Phase 4 at the human signoff.
6. For **one** of the tickets (say `greeter-ko`), run `/dev-framework:implement greeter-ko`.
7. Phase 0 should print the Big Picture / This Ticket's Role / Proceeding banner and emit `ticket.started`.
8. Let `/implement` run Phase 1-7 normally. At GATE 2 option [1], emit `ticket.merged`.
9. Repeat steps 6-8 for the remaining tickets.
10. After all tickets merge, run `/dev-framework:spike --retro <epicId>`.

**Expected observations:**

- After step 4, `cat docs/plan/<epicId>/spike-plan.md | sed -n '/BEGIN AUTO-GENERATED REGISTRY/,/END AUTO-GENERATED REGISTRY/p'` shows a populated markdown table with all tickets' `status=planned`.
- After step 7, the registry row for the in-progress ticket flips to `status=in-impl` on the next `regenerate-views.sh` pass (triggered by any hook event).
- After step 8, the registry row shows `status=merged`.
- Each per-ticket ref doc's `§6 Implementation Notes` block (between `BEGIN AUTO-GENERATED IMPL LOG` sentinels) contains entries for `ticket.started`, each `phase.started`/`phase.completed`, at least one `consensus.converged`, and final `ticket.merged`.
- Ticket doc frontmatter `status:` progresses `planned` → `in-impl` → `merged`.
- Retro in step 10 emits `spike.retro.completed` and writes / updates `~/.claude/autodev/chronic-design-patterns.json`.

**Failure modes to watch for:**

- Sentinel markers missing after regeneration (would indicate `reduce-spike-plan.sh` or `reduce-ticket-doc.sh` overwriting instead of bracket-replacing). File should retain every pre-sentinel line verbatim.
- Duplicate entries in §6 impl log → reducer isn't deduping events by seq.
- `runId` missing from `ticket.started` event → events table shape drift in `emit-event.sh`.

### Scenario B — Phase 0 hard-blocker exit

**Goal:** verify hard blockers actually stop `/implement` before any freeze doc is seeded.

**Steps:**

1. Complete Scenario A through Phase 4 approval but do NOT implement any ticket yet.
2. Manually edit one ticket's ref doc frontmatter to add a hard blocker referencing another ticket:
   ```yaml
   implBlockedBy:
     - ticketId: greeter-api
       kind: hard
       reason: "Depends on shared translation interface"
   ```
3. Invoke `/dev-framework:implement greeter-ko` (assuming `greeter-api` is still `planned`).

**Expected observations:**

- The workflow exits at Phase 0 with a "🛑 Blocked" message listing `greeter-api` and its reason.
- No freeze doc is created in `docs/specs/`.
- `events.jsonl` shows a `phase.failed` event with `{"phase":0,"error":"hard blocker(s) unmet"}`.
- No `ticket.started` event for `greeter-ko`.

Then merge `greeter-api` and re-run `/implement greeter-ko` to confirm it now proceeds.

### Scenario C — ticket.discovery round-trip

**Goal:** verify that corrections found during `/implement` surface in `/spike` retro.

**Steps:**

1. During Scenario A step 8 (Phase 5 of some ticket), manually emit a discovery event via the shell:
   ```bash
   bash plugins/dev-framework/hooks/scripts/emit-event.sh ticket.discovery \
     --actor orchestrator \
     --data '{"epicId":"<epicId>","ticketId":"greeter-ko","section":"spike-plan §3","correction":"API contract missed Accept-Language header"}'
   ```
2. Let the ticket continue to GATE 2.
3. At GATE 2, expect a "Spike Plan Corrections Discovered" section in the approval summary listing this discovery.
4. Approve the gate.
5. After all tickets merge, run the spike retro.

**Expected observations:**

- Retro aggregates the discovery: `chronic-design-patterns.json` either contains a new pattern with `examples[0].correction` matching the discovery text, or matches an existing pattern and increments its frequency.
- `events.jsonl` shows `spike.retro.completed` with non-zero `patternsPromoted` or an appended runLog entry.

### Scenario D — ad-hoc `/implement` (no ref doc)

**Goal:** verify that `/implement` still works for plain feature descriptions (no spike).

**Steps:**

1. Run `/dev-framework:implement add health-check endpoint to the greeter service` on a branch with NO matching ref doc under `docs/plan/*/`.

**Expected observations:**

- Phase 0 is a no-op (prints nothing beyond "no ref doc found, proceeding ad-hoc").
- `epicId` is set to `ad-hoc-<sanitized-branch>` in `progress-log.json`.
- No `ticket.started`, `ticket.merged`, or `ticket.discovery` events are emitted throughout the run.
- Phase 1-7 complete normally; freeze doc populates from scratch.

### Scenario E — v3 → v4 upgrade (`/dev` tombstone)

**Goal:** confirm existing users invoking `/dev` get redirected cleanly.

**Steps:**

1. From Claude Code, invoke `/dev-framework:dev some feature description`.

**Expected observations:**

- User sees a deprecation message like: "`/dev-framework:dev` has been renamed to `/dev-framework:implement` as of v4.0.0. Please invoke `/dev-framework:implement <your args>` instead. This tombstone command will be removed in v4.1.0."
- No Phase 1 work is started; the tombstone does not silently trigger the implement skill.

---

## 3. Release Checklist

Work through in order. Each step is either mechanical or requires a human sign.

### 3.1 Version bumps

- [ ] `plugins/dev-framework/.claude-plugin/plugin.json` → `"version": "4.0.0"` (verify, was bumped in Phase 2)
- [ ] `plugins/dev-framework/skills/implement/SKILL.md` frontmatter → `version: 4.0.0`
- [ ] `plugins/dev-framework/skills/spike/SKILL.md` frontmatter → `version: 1.0.0` (new skill, not 4.0)

### 3.2 Changelog

Produce or append to `plugins/dev-framework/CHANGELOG.md` (create if missing):

```markdown
## 4.0.0 — 2026-04-21

### Breaking
- `/dev-framework:dev` renamed to `/dev-framework:implement`. Tombstone provided for v4.0.x; removed in v4.1.0.
- Session folder keying changed from `{repo}--{branch}` to `{repo}--epic-{epicId}`. Ad-hoc `/implement` synthesizes `epicId = ad-hoc-<sanitized-branch>` for backward compatibility; existing in-flight sessions must either finish on v3.0.1 or be restarted on v4.0.0.

### Added
- `/dev-framework:spike` skill for multi-ticket research and decomposition (5 phases; Phase 5 retro is async).
- Plan-doc convention at `<repo>/docs/plan/{epicId}/` with `spike-plan.md` and per-ticket ref docs.
- `/implement` Phase 0 "Prereq Check" for spike-sourced tickets (hard/soft blocker validation; freeze-doc §1-§5 pre-seeding).
- Bi-directional events: `ticket.started` / `ticket.discovery` / `ticket.merged` / `spike.*`.
- Reducers: `reduce-spike-plan.sh` (§7 registry) and `reduce-ticket-doc.sh` (§6 impl log + frontmatter status).
- Retro-per-skill: design-pattern variant at `~/.claude/autodev/chronic-design-patterns.json`.
- `domain` discriminator on `patterns.*` events.

### Changed
- `load-chronic-patterns.sh` now loads both code and design chronic stores at SessionStart.
- `events-schema.md` extended with `spike.*` and `ticket.*` catalogs.
- `regenerate-views.sh` invokes two new reducers unconditionally (they no-op safely off-epic).
```

### 3.3 Final review + ship

- [ ] `git log main..HEAD --oneline` matches the six-phase outline (phase 1 spec archive + phases 2-6 implementation).
- [ ] Static verification (§1) all green on CI or local.
- [ ] At least Scenario A and Scenario E from §2 run manually on a sandbox project.
- [ ] Tag `v4.0.0` on main after merge.
- [ ] Plugin registry publish (if applicable — `.claude-plugin/plugin.json` served from whichever registry the team uses).

### 3.4 Post-deploy verification

After v4.0.0 is in user hands:

- [ ] Monitor `~/.claude/autodev/sessions/*/events.jsonl` on the deploy team's machines for 1 week.
- [ ] Confirm `ticket.decomposed` / `ticket.started` / `ticket.merged` appear in at least one real epic end-to-end.
- [ ] Confirm no user reports of lost v3.0.x sessions (should be impossible since session folder naming changed, but worth confirming users got the message).
- [ ] Schedule v4.1.0 milestone for tombstone removal (one minor cycle).

---

## 4. Rollback plan

If v4.0.0 breaks in the field:

1. Revert the plugin registry entry to v3.0.1.
2. Users on v4.0.0 with in-flight epic sessions will lose the epic-scoped session folder; their data is not lost (it's still on disk at `~/.claude/autodev/sessions/<old-key>/`) but won't be found by v3.0.1's branch-scoped resolver.
3. Provide a recovery script (post-mortem deliverable) that renames `{repo}--epic-ad-hoc-<branch>/` folders back to `{repo}--<branch>/` so v3.0.1 picks them up.

No database or persistent external service is involved, so rollback is strictly filesystem-level.
