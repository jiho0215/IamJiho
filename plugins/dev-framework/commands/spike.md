---
description: Multi-ticket research and decomposition workflow. Takes an epic goal and produces a spike plan plus N per-ticket ref docs committed to docs/plan/{epic}/.
argument-hint: Epic description, epic ID, or --retro EPIC-ID to run the async post-merge retro
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, TodoWrite, AskUserQuestion, Skill, Agent, EnterPlanMode, ExitPlanMode
---

# Spike — research spike framework

You are launching the dev-framework **spike** workflow.

Initial request: $ARGUMENTS

Use the Skill tool to invoke the `dev-framework:spike` skill, passing along the user's request. The skill contains the full 5-phase workflow (Requirements → System Design → Ticket Decomposition → Gap Review → Retro), plan-doc assembly, multi-agent consensus orchestration, and reference documentation.

For single-ticket implementation (spike-sourced or ad-hoc), use `/dev-framework:implement` instead.
