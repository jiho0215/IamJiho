---
description: Autonomous 10-phase development pipeline with cross-session learning
argument-hint: TICKET_ID [--from N] [--status]
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "TodoWrite", "AskUserQuestion", "Skill", "Agent"]
---

# Dev Pipeline

You are launching the dev-pipeline autonomous workflow.

Initial request: $ARGUMENTS

Use the Skill tool to invoke the `dev-framework:dev-pipeline` skill, passing along the user's request. The skill contains the full 10-phase pipeline with session management, review loops, mistake tracking, and human gate.

If no ticket ID was provided, ask the user for one before invoking the skill.
