---
description: Single-ticket implementation workflow with rigorous multi-agent consensus. Takes one well-defined ticket (spike-sourced or ad-hoc) and produces a reviewed, merged PR.
argument-hint: Optional ticket ID, feature description, or workflow keyword (init, review, test, docs, --status, --from N, --autonomous TICKET)
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, TodoWrite, AskUserQuestion, Skill, Agent, EnterPlanMode, ExitPlanMode
---

# Implement — ticket implementation framework

You are launching the dev-framework **implement** workflow.

Initial request: $ARGUMENTS

Use the Skill tool to invoke the `dev-framework:implement` skill, passing along the user's request. The skill contains the full 7-phase workflow (plus Phase 0 prereq check for spike-sourced tickets), routing logic, agent orchestration, and reference documentation.

If no arguments were provided, the skill will detect the appropriate workflow from project context (spike ticket ref doc, bare branch, or empty cwd) and user intent.

For multi-ticket research and decomposition, use `/dev-framework:spike` instead.
