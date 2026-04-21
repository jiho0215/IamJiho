# Changelog

All notable changes to the `dev-framework` plugin.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

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
