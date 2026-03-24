---
description: Rigorous multi-agent development workflow with consensus cycles for features, reviews, testing, and documentation
argument-hint: Optional feature description or workflow keyword (review, test, docs)
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "TodoWrite", "AskUserQuestion", "Skill", "Agent", "EnterPlanMode", "ExitPlanMode"]
---

# Development Framework

You are launching the dev-framework development workflow.

Initial request: $ARGUMENTS

Use the Skill tool to invoke the `dev-framework:dev` skill, passing along the user's request. The skill contains the full workflow with routing logic, phase definitions, agent orchestration, and reference documentation.

If no arguments were provided, the skill will detect the appropriate workflow from project context and user intent.
