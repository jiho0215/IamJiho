# Dispatcher Spec

SKILL.md's phase body is prose; metadata lives in `../../../../../phases/phase-N.yaml`. The dispatcher preamble reads the YAML at phase entry and uses it to:

1. **Lazy-load required references** (`requiredRefs[]`) — only read what this phase needs.
2. **Emit entry events** (`emits.entry[]`).
3. **Gate** on `gates.begin[]` scripts (via `execute.sh hook`).
4. **Consult SKILL.md prose** for `skillMdSection` — this is the *narrative* (how to actually do the work, including LLM prompts and user dialogue).
5. **Invoke** tools via `execute.sh <kind> <name>` per `invokes[]`.
6. **Produce** artifacts per `produces[]`.
7. **Gate** on `gates.end[]` scripts.
8. **Emit exit events** (`emits.exit[]`).

This separation keeps narrative editable (change SKILL.md) while making metadata machine-actionable (change YAML).

## Dispatcher pseudocode

```
on phase entry:
  yaml = read_phase("phases/phase-${N}.yaml")

  # Lazy refs
  for ref in yaml.requiredRefs:
    Read(skills/dev/references/${ref})

  # Entry events
  for ev in yaml.emits.entry:
    bash emit-event.sh ${ev.type} --data ${ev.data}

  # Begin gates
  for g in yaml.gates.begin:
    bash execute.sh hook ${g.script} --input '{"args": ${g.args}}'

  # Consult narrative (prose in SKILL.md)
  # — the phase body below in SKILL.md is still the authoritative how-to

  # Invocations (the LLM handles skill/agent forwarding)
  for inv in yaml.invokes:
    resolved_name = substitute(inv.config or inv.name)
    if inv.when unset or inv.when evaluates true:
      bash execute.sh ${inv.kind} ${resolved_name} --input ${resolved_input}

  # Verify artifacts
  for p in yaml.produces:
    verify p.path exists (or for verification kind, verify the assertion holds)

  # End gates
  for g in yaml.gates.end:
    bash execute.sh hook ${g.script} --input '{"args": ${g.args}}'

  # Exit events
  for ev in yaml.emits.exit:
    bash emit-event.sh ${ev.type} --data ${ev.data}
```

## Variable substitution

YAML tokens → runtime substitution table:

| Token | Source |
|---|---|
| `${featureSlug}` | `progress-log.json .featureSlug` |
| `${ticket}` | `progress-log.json .ticket` |
| `${sessionDir}` | Result of `resolve_session_dir` |
| `${config.pipeline.skills.X}` | `config.json` at that path |
| `${config.pipeline.agents.X}` | `config.json` at that path |
| `${phaseMetrics}` | Dispatcher assembles from event log at phase end (iterations, issuesFixed, etc.) |
| `${totalMinutes}` | (Phase 7 only) Elapsed minutes from `session.started.at` to now |
| `${architectureTitle}` | (Phase 2) Short title slug derived from ADR subject |

Unresolved tokens are left as-is (with a warning logged to session.precompact event if the token is referenced by an emit payload) so partial data still enables troubleshooting.

## Invocation semantics by kind

| kind | What `execute.sh` does | What the orchestrator LLM does |
|---|---|---|
| `hook` | Runs `hooks/scripts/${name}` with input.args. Captures stdout/stderr. | Nothing — hook runs to completion synchronously. |
| `protocol` | Verifies reference file exists, emits event recording load. | Reads the reference file with the Read tool and applies its contents. |
| `skill` | Emits `tool.call.started`, returns dispatch payload JSON. | Invokes the named Skill tool with the payload's input, then calls `execute.sh --complete skill <name> --output <result>`. |
| `agent` | Same as skill. | Dispatches the named Task subagent with payload, then `execute.sh --complete agent <name>`. |

If a skill/agent is unavailable and YAML declares `fallback: inline`, the orchestrator continues using the narrative prose in SKILL.md without the missing skill. If `fallback: skip`, the invocation is recorded as skipped.

## Config modelProfile

`config.pipeline.modelProfile ∈ {conservative, balanced, trust-model}`:

| Profile | maxReviewIterations | consecutiveZerosToExit | agents.review | Notes |
|---|---|---|---|---|
| `conservative` | 15 | 3 | 3 | Older or cheaper models; maximum safety |
| `balanced` (default) | 10 | 2 | 3 | M1/M2 baseline |
| `trust-model` | `null` (model declares convergence) | `null` | `auto` (1 for frontier) | Opus 4.7+ class |

Profile changes are recorded in `session.started.data.modelProfile`. Event-log retrospection across runs lets us compare quality metrics (post-GATE2 rework, consensus iteration counts) across profiles.

M3 introduces the knob but does not alter the existing defaults' values — orchestrator behavior is unchanged unless the user explicitly switches profiles.

## Non-requirements (what this is NOT)

- **Replacing SKILL.md prose with YAML-as-data.** Prose narrative stays — M3b adds **structured action checklists** alongside the prose (see below), not instead of it.
- **Machine-evaluated preconditions/postconditions.** YAML declares; dispatcher/LLM checks.
- **Full multi-brain parallelism.** That's M4.
- **Byte-equality of views with procedural writes.** M2 accepts semantic equivalence; M2.5 adds the missing event types (`config.snapshot.recorded`, `plan.files.set`, `patterns.loaded`) so byte-equality becomes *possible*; the procedural write path still runs.

## `instructions` field (M3b+)

Each phase YAML may carry an `instructions` map containing structured step lists (typically keyed `entry`, `main`, `exit`, plus phase-specific keys like `gate`, `layer1_review`, `frozen_integrity`, `mistake_capture`). These are **"what to do" checklists** that complement — never replace — the SKILL.md prose which explains **"why" and "how to think about" each step**.

When executing a phase, the dispatcher consults the YAML `instructions.main` (or the phase-specific section) for the step order, and cross-references SKILL.md §skillMdSection for reasoning, examples, and dialogue templates.

### Why keep both

- **YAML `instructions`**: machine-actionable checklist; survives model capability bumps; easy to extend/version.
- **SKILL.md prose**: human-readable narrative; explains rationale; includes dialogue templates and examples.

Future model generations may rely increasingly on the YAML (less prose needed), but the prose remains the source of truth for why things work the way they do.

### Schema keys per phase

| Phase | Typical instruction sections |
|---|---|
| 1-4, 6 | entry / main / exit |
| 5 | entry / execution_rules / main / layer1_review / exit |
| 3 | entry / main / gate / exit |
| 6 | entry / main / layer2_review / frozen_integrity / exit |
| 7 | entry / documentation / mistake_capture / gate / exit |

Keys are advisory — the dispatcher reads `instructions.*` as a whole and follows them in document order.

## Invariants

1. **Idempotent re-reads.** `read-phase.sh` called twice returns the same YAML content.
2. **Event log is the memory.** The dispatcher holds no state across invocations; `wake.sh` plus event log determine next action.
3. **Additive changes only.** Adding a new field to a phase YAML is backward-compatible. Renaming a field requires migrating all 7 YAMLs in the same commit.
