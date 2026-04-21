# Phase YAMLs

Two skills, two phase-file prefixes:

- `phase-N.yaml` — `/implement` phases 1-7. Narrative prose: [`../skills/implement/SKILL.md`](../skills/implement/SKILL.md).
- `spike-phase-N.yaml` — `/spike` phases 1-5. Narrative prose: [`../skills/spike/SKILL.md`](../skills/spike/SKILL.md).

Each YAML captures a phase's **metadata** — what it needs, emits, invokes, and produces.

Read by the dispatcher preamble at phase entry (see [`../skills/implement/references/autonomous/dispatcher-spec.md`](../skills/implement/references/autonomous/dispatcher-spec.md)). `read-phase.sh` takes a file path, so both naming conventions work without any dispatcher change.

## Schema

```yaml
phase: <int>                  # 1-7 for /implement; 1-5 for /spike
name: <human-readable phase name>
skillMdSection: <anchor into SKILL.md, e.g. "Phase 1 — Requirements">
skill: implement | spike      # optional; defaults to "implement" for unprefixed files

requiredRefs:
  - <path under the owning skill's references/, e.g. "methodology/DECISION_MAKING.md">
  # Cross-skill refs use relative paths, e.g. "../../implement/references/protocols/multi-agent-consensus.md"
  # Dispatcher lazy-loads these at phase entry. Empty list means phase relies
  # only on the global companion-references table.

emits:
  entry:
    - type: phase.started
      data: "{\"phase\":<N>}"
  exit:
    - type: phase.completed
      data: "{\"phase\":<N>}"

invokes:
  - kind: skill | agent | protocol | hook
    config: pipeline.skills.requirements           # for kind=skill, path into config.json
    name: multi-agent-consensus                    # for kind=protocol, reference file stem
    when: "mode == 'interactive'"                  # optional; else always
    fallback: inline                               # "inline" | "skip"
    input:                                         # optional invocation input
      task_type: validate
      agents_config: pipeline.agents.plan
      context: "..."

produces:
  - kind: artifact
    path: "docs/specs/${featureSlug}-requirements.md"
  - kind: freeze-doc-sections
    sections: [1, 5, 6]

instructions:
  # (M3b) Structured per-phase checklist. Entry/main/exit steps are what the
  # dispatcher should DO; SKILL.md §skillMdSection remains authoritative for
  # WHY and HOW-TO-THINK.
  entry:
    - "Read each requiredRef path into working context."
    - "Emit entry events and run begin gates."
  main:
    - "Dialogue-gather requirements (interactive) or extract from ticket (autonomous)."
    - "Invoke requirements skill per invokes[0]."
    - "Run multi-agent-consensus validation per invokes[1]."
    - "Write docs/specs/${featureSlug}-requirements.md."
    - "Populate freeze doc §1, §5, §6."
  exit:
    - "Emit exit events and run end gates."
    - "Banner: '--- Phase N Complete: Name ---'."

gates:
  begin:
    - script: phase-gate.sh
      args: ["begin", "<N>"]
  end:
    - script: phase-gate.sh
      args: ["end", "<N>"]

budget:
  seconds: <int>

userGate: none | 1 | 2  # marks GATE 1 (phase 3) or GATE 2 (phase 7) phases
```

## Variable substitution

Tokens like `${config.pipeline.skills.requirements}` or `${featureSlug}` are expanded by the dispatcher at runtime using `config.json` and session state.

| Token | Source |
|---|---|
| `${featureSlug}` | `progress-log.json .featureSlug` |
| `${ticket}` | `progress-log.json .ticket` |
| `${config.<path>}` | `config.json` at that JSON path |
| `${phaseMetrics}` | Dispatcher assembles from event log at phase end |

## Why YAML and not JSON

Hand-editability and multi-line string support (prompt templates if they ever appear here). The schema is deliberately flat — no deeply-nested structures beyond one level — so `read-phase.sh` works without heavy parser dependencies.

## Invariants

1. **Metadata only.** No narrative. If you want to explain *how* to do something, update SKILL.md prose.
2. **No runtime state.** Phase YAML must not contain mutable state. State lives in `events.jsonl`.
3. **Stable references.** Every path in `requiredRefs[]` must exist in the repo.
4. **Schema stability.** Adding optional fields is allowed; renaming existing fields is a breaking change.
