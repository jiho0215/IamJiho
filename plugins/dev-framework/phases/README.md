# Phase YAMLs

Each `phase-N.yaml` captures Phase N's **metadata** — what it needs, emits, invokes, and produces. Narrative prose lives in [`../skills/dev/SKILL.md`](../skills/dev/SKILL.md).

Read by the dispatcher preamble at phase entry (see [`../skills/dev/references/autonomous/dispatcher-spec.md`](../skills/dev/references/autonomous/dispatcher-spec.md)).

## Schema

```yaml
phase: <int 1-7>
name: <human-readable phase name>
skillMdSection: <anchor into SKILL.md, e.g. "Phase 1 — Requirements">

requiredRefs:
  - <path under skills/dev/references/, e.g. "methodology/DECISION_MAKING.md">
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
