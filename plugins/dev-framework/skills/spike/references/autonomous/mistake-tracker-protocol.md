# Mistake Tracker Protocol — Design Variant

Cross-epic learning system for architectural / design mistakes. Invoked during `/spike` Phase 5 (retro), which aggregates `ticket.discovery` events and direct retro findings into reusable design patterns that prevent the same structural mistakes in future epics. This is the **design-pattern** variant. See [`../../../implement/references/autonomous/mistake-tracker-protocol.md`](../../../implement/references/autonomous/mistake-tracker-protocol.md) for the code-pattern variant invoked by `/implement` Phase 7.

## Issue Source Separation (design vs code issues)

Scope deliberately differs from the code variant:

| Source | Captured here? | Consumed by |
|---|---|---|
| `ticket.discovery` events from `/implement` | **Yes** — primary input | `/spike` Phase 5 retro |
| Phase 5 retro direct observations (cross-ticket, e.g., "we consistently under-scoped migration rollback") | **Yes** | `/spike` Phase 5 retro |
| Phase 3 /implement design issues (plan gaps) | No (same as code variant) | Logged for audit only |
| Phase 5/6 /implement code issues (bugs, conventions) | No | Code-pattern variant |

The two variants are **orthogonal stores**. A bug in null-handling is not a design pattern; a missing migration rollback step is not a code pattern.

## Pattern Categories (design taxonomy)

Unlike code patterns (e.g. "missing null check"), design patterns describe structural mistakes at the epic / ticket-decomposition level:

| Category | Example |
|---|---|
| `architecture` | "Shared service introduced without clear ownership — multiple epics conflict later" |
| `boundary` | "Cross-epic boundary leaked state via the wrong side's persistence layer" |
| `interface` | "API contract frozen before consumers validated — breaking change within 2 sprints" |
| `migration` | "Schema migration lacked rollback script; incident-hour debugging blocked" |
| `coupling` | "Two tickets declared soft-blocker that was actually hard — deployment out of order" |
| `scoping` | "Ticket decomposed too coarsely; single ticket became 3-week freeze-doc war" |
| `observability` | "Cross-ticket trace correlation id not defined in spike plan; ops paged without context" |

Categories are open-ended. New ones appear when evidence accumulates; retire when empty for > `config.pipeline.cleanRunsForDemotion` retros.

## Pattern Matching Algorithm

LLM-driven match (not string comparison):

1. For each `ticket.discovery` + retro observation, compare against all Known/Chronic design patterns.
2. **Match criteria:** same category AND same structural root cause (strip epic-specific details).
3. If match found: increment `frequency`, append to `examples[]` with `{epicId, correction}`.
4. If no match: generalize (remove epic / ticket / file names) and create new pattern with `frequency: 1`, `status: "known"`.
5. Log each match / promote / demote decision to `decision-log.json` (category: `pattern-design`).

## Pattern Lifecycle

Same state machine as the code variant, different thresholds configurable separately if needed (currently shares `config.pipeline.chronicPromotionThreshold` and `cleanRunsForDemotion`):

```
Epic 1: "Migration lacked rollback" → D1, status=known, frequency=1
Epic 2: Seen again → D1, frequency=2
Epic 3: Seen again → D1 PROMOTED to chronic (≥ threshold)
  → prevention strategy written, synced to ~/.claude/CLAUDE.md
Epic 4+: Prevention active; NOT seen → does NOT count as clean run
Epic N: Manually removed from prevention AND not seen for ≥ cleanRunsForDemotion retros → resolved
```

IDs are stable (`D1, D2, D3, ...`) to make cross-epic references durable. Promotion is a status change, not an ID change.

## Storage — `~/.claude/autodev/chronic-design-patterns.json`

JSON (not markdown) because this store is consumed programmatically by `load-chronic-patterns.sh` and never edited directly by humans during an active session. The code variant's markdown format is an artifact of being older; new stores should prefer JSON.

### Schema

```json
{
  "schemaVersion": 1,
  "patterns": [
    {
      "id": "D1",
      "pattern": "Migration step shipped without companion rollback script",
      "category": "migration",
      "status": "chronic",
      "frequency": 4,
      "firstSeen": "2026-04-10T12:00:00Z",
      "lastSeen": "2026-05-02T09:30:00Z",
      "prevention": "When a /spike Phase 3 ticket touches migrations/**, require `rollback: <step>` field in the ticket ref doc §4 (data) frontmatter before GATE approval.",
      "examples": [
        {"epicId": "EPIC-42", "correction": "Added rollback in retro"},
        {"epicId": "EPIC-57", "correction": "Caught at GATE 2; fixed pre-merge"}
      ]
    }
  ],
  "runLog": [
    {
      "runId": "run-2026-05-02T09-30-00-abcd",
      "epicId": "EPIC-57",
      "at": "2026-05-02T09:30:00Z",
      "discoveriesProcessed": 6,
      "patternsPromoted": 1,
      "patternsDemoted": 0
    }
  ]
}
```

### Field rules

- `schemaVersion` is the index into a migration ladder; future schema changes bump it and ship a migrator.
- `patterns[].id` is `D<n>` where `n` is monotonically increasing across the whole file's history (never reused, even after resolution).
- `patterns[].status ∈ {"known", "chronic", "resolved"}`. Only `chronic` patterns sync to CLAUDE.md.
- `patterns[].examples[]` preserves epic-level evidence; truncate to the most recent 10 entries per pattern to cap file growth.
- `runLog[]` is append-only; the idempotency key is `runId`.

## CLAUDE.md Sync (Sentinels)

Target: `~/.claude/CLAUDE.md` (user global), NOT the plugin CLAUDE.md. Design patterns are user-portable guidance, not plugin config.

Sentinels:
```
<!-- BEGIN CHRONIC DESIGN PATTERNS -->
<!-- END CHRONIC DESIGN PATTERNS -->
```

Block content when ≥ 1 chronic pattern exists:
```markdown
## Chronic Design Patterns

When designing or decomposing epics, proactively prevent these recurring structural mistakes:
- D1: {pattern} — {prevention}
- D3: {pattern} — {prevention}
```

If zero chronic patterns: remove the entire sentinel-enclosed block (inclusive of sentinels is optional; keeping empty sentinels is also fine — consumers check for content, not sentinels).

**Atomic write:** copy `~/.claude/CLAUDE.md` → `.backup`, write `.tmp`, validate sentinels + non-empty-outside, rename `.tmp` → final, delete `.backup`. On Windows file-lock, retry once after 1s. This is identical to the code variant's sync mechanics, targeting a different file.

**All content outside the sentinels is preserved verbatim.**

## Hard Cap Enforcement

Same structure as the code variant. If `known + chronic > config.pipeline.maxActivePatterns`:

1. Sort Known by `frequency` (ascending), then `lastSeen` (oldest first). Demote lowest-priority to resolved until count ≤ cap.
2. If all are chronic: demote oldest chronic by `lastSeen` for **at most 1** new Known per retro. Log the demotion as a warning.
3. Remaining new discoveries that don't fit: logged to `events.jsonl` as `spike.retro.patterns.overflow` with the count — do NOT silently drop.

## Demotion Rules

**Clean retro definition:** pattern was NOT in prevention checklist AND NO matching `ticket.discovery` was aggregated during that retro.

**Two routes:**
1. **Manual:** human removes from prevention (edits `~/.claude/CLAUDE.md` or the JSON store). After `config.pipeline.cleanRunsForDemotion` consecutive clean retros → resolved.
2. **Cap overflow:** emergency valve (see Hard Cap above). Logged as warning, event `spike.retro.patterns.demoted` with `reason: "cap-overflow"`.

## Idempotency

Before aggregation, check `runLog[]` for an entry with the current `runId`. If present, skip aggregation and return the stored summary. Otherwise, aggregate, then append the runLog entry after the JSON write succeeds. This mirrors the code variant's Run Log check.

## Events emitted by this protocol

| Event type | When |
|---|---|
| `patterns.promoted` (actor: `skill:spike:retro`, domain: `design`) | Each known → chronic transition |
| `patterns.demoted` (actor: `skill:spike:retro`, domain: `design`) | Each chronic → resolved (manual) or cap-overflow |
| `spike.retro.completed` | End of aggregation; carries `{epicId, patternsPromoted, patternsDemoted}` |

The shared event types (`patterns.promoted` / `patterns.demoted`) are distinguished from code-pattern events by the `actor` field (`skill:spike:retro` vs `skill:implement:phase-7`) and by an additional `data.domain: "design" | "code"` discriminator added to the payload. View reducers key by domain.

## Why JSON instead of markdown

| Aspect | Markdown (code variant) | JSON (this variant) |
|---|---|---|
| Human-editable | Yes | With jq/tooling |
| Programmatic read | Requires regex | Direct jq query |
| Atomicity | File-level (fine) | File-level (fine) |
| Schema evolution | Implicit | Explicit `schemaVersion` |
| Examples collection | Cluttered in tables | Nested arrays, clean |

The code variant inherited its markdown layout from a pre-events era; migrating it is out of scope for v4.0. New stores (like this one) should prefer JSON.
