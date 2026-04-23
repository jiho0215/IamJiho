---
description: Standalone testing workflow. Takes any repo state (TDD starter tests, legacy tests, or nothing) and builds a formalized complete test suite at 95%+ case coverage across unit, integration, and E2E — organized under one TESTING.md per repo. Independent of /implement.
argument-hint: Epic ID, ticket ID, or module path. Add --init to scaffold TESTING.md for a new repo, --audit to only report gaps without writing.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, TodoWrite, AskUserQuestion, Skill, Agent, EnterPlanMode, ExitPlanMode
---

# Testbuilder — standalone testing framework

You are launching the dev-framework **testbuilder** workflow.

Initial request: $ARGUMENTS

Use the Skill tool to invoke the `dev-framework:testbuilder` skill, passing along the user's request. The skill contains the full workflow: coverage assessment → gap analysis → tiered test construction (unit/integration/E2E) → TESTING.md reconciliation → CI wiring.

Testbuilder is a pure function of repo state. It runs against greenfield repos, post-`/implement` repos, or legacy repos alike — consuming whatever tests exist as Phase 1 input and building the complete test empire from there. It enforces skip-test hygiene, the mock-vs-Docker dependency rule, the blackbox/whitebox tier boundary, and CI wiring hygiene.

For single-ticket implementation (which may run before or not at all), use `/dev-framework:implement`. For multi-ticket epic decomposition, use `/dev-framework:spike`.
