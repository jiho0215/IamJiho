---
description: Multi-ticket research and decomposition workflow. Takes an epic goal and produces a spike plan plus N per-ticket ref docs committed to docs/plan/{epic}/.
argument-hint: Epic description, epic ID, or --retro EPIC-ID to run the async post-merge retro
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, TodoWrite, AskUserQuestion, Skill, Agent, EnterPlanMode, ExitPlanMode
---

# Spike — universal planning skill

You are launching the dev-framework **spike** workflow.

Initial request: $ARGUMENTS

Use the Skill tool to invoke the `dev-framework:spike` skill, passing along the user's request. The skill routes to the appropriate mode based on the first arg keyword.

## Usage

| Invocation | Mode |
|---|---|
| `/spike <epic-description>` | Epic mode (default; multi-ticket decomposition) |
| `/spike research <topic>` | Standalone Research mode |
| `/spike story <ticket-id>` | Standalone Story mode |
| `/spike --status <epic-or-slug>` | Show session status |
| `/spike --from <N> <epic-or-slug>` | Resume at phase N |
| `/spike --retro <epic-or-slug>` | Run async retro |
| `/spike --revisit <epic-or-slug> --reason <reason>` | Re-spike (verification-failure recovery) |

Routes `$ARGUMENTS` to the spike skill which dispatches the appropriate mode flow. The skill contains the full 5-phase workflow (Requirements → System Design → Ticket Decomposition → Gap Review → Retro), plan-doc assembly, multi-agent consensus orchestration, and reference documentation.

For single-ticket implementation (spike-sourced or ad-hoc), use `/dev-framework:implement` instead.
