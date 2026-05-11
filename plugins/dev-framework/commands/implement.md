---
description: Single-ticket implementation workflow with rigorous multi-agent consensus. Takes one well-defined ticket (spike-sourced or ad-hoc) and produces a reviewed, merged PR.
argument-hint: Optional ticket ID, feature description, or workflow keyword (init, review, test, docs, --status, --from N, --autonomous TICKET)
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, TodoWrite, AskUserQuestion, Skill, Agent, EnterPlanMode, ExitPlanMode
---

# Implement — ticket implementation framework

You are launching the dev-framework **implement** workflow.

Pure execution. Reads an APPROVED freeze doc produced by `/spike` and runs E1/E2/E3.

Initial request: $ARGUMENTS

Use the Skill tool to invoke the `dev-framework:implement` skill, passing along the user's request. v5: pure execution. Reads APPROVED freeze doc -> E1 Execute -> E2 Verify -> E3 Finalize. freeze-doc-path required.

## Usage

| Invocation | Behavior |
|---|---|
| `/implement <freeze-doc-path>` | Start E1 against the given freeze doc |
| `/implement --from <N> <freeze-doc-path>` | Resume at phase E<N> (1=E1, 2=E2, 3=E3) |
| `/implement --status <freeze-doc-path>` | Status print |

The freeze-doc-path is REQUIRED. If you do not have one, run `/spike story <ticket>` (or `/spike <epic>`) first to produce one. The freeze doc must have `status: APPROVED`; v5 also requires `approvedHash` to match the canonical body.

For multi-ticket research and decomposition, use `/dev-framework:spike` instead.
