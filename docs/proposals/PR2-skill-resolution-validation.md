# PR #2 — Skill-mapping validation at startup (enhancement C)

**Target:** `jiho0215/IamJiho` — dev-framework plugin
**Affects:** `skills/dev-pipeline/SKILL.md` (Pre-Pipeline step 2) + new validation helper
**Priority:** Second — catches PR #3's bugs at install-time
**Backward compatible:** Yes (warnings only, never blocks pipeline start)

## Problem

SKILL.md currently says: *"If the resolved skill is unavailable at runtime, the phase operates without skill-specific guidance."*

This silent-degradation pattern means a user can run `/dev` for weeks before noticing a phase isn't invoking the skill they think it is. The canonical example: default `pipeline.skills.exploration → feature-dev:code-explorer` — but `code-explorer` is an **agent**, not a skill. The Skill tool fails to find it. Silently.

## Proposed change

In `Pre-Pipeline` step 2 (immediately after reading/creating `config.json`), add a resolution pass:

```
Extract all values from:
  - pipeline.skills.*
  - pipeline.agents.* (lists)
  - reviewBoss.reviewers[].skill (if present)

For each non-null value:
  - Parse "pluginName:skillName" format
  - Check pluginName is in the enabled plugins list (read from ~/.claude/settings.json enabledPlugins)
  - Check skillName is findable within that plugin's skills/ directory

For any unresolved references, emit a structured warning:

  WARNING: pipeline has <N> unresolved reference(s):
    - pipeline.skills.exploration → feature-dev:code-explorer (NOT FOUND: plugin has 'code-explorer' as agent, not skill)
    - pipeline.skills.architect → feature-dev:code-architect (NOT FOUND: same reason)

  The affected phases will run without skill-specific guidance.
  To fix: set the key to null, or install a plugin that provides this skill.
```

Do NOT block pipeline start. Do NOT auto-fix. Just report clearly.

## Schema validation (additional value)

While in the same helper, also validate the config schema itself:
- Unknown top-level keys → warning ("config.json has unknown key 'phases' — will be ignored")
- `pipeline.skills.*` entries that aren't the canonical 15 slots → warning
- `pipeline.agents.*` entries not in `{plan, review}` → warning

This helps users migrating between schema versions (e.g. someone with old `phases.*` layout).

## Test plan

- Unit: resolver returns no warnings when all skills resolve
- Unit: resolver returns specific warning when plugin is disabled
- Unit: resolver returns specific warning when skill name doesn't exist in plugin
- Unit: resolver returns specific warning when skill name is actually an agent name
- Integration: real config with 1 broken reference → pipeline starts, warning printed, no crash

## Rollout

- Additive; no migration
- Users with broken configs see warnings and can choose to fix or ignore
- After this ships, PR #3 (fix defaults) becomes verifiable
