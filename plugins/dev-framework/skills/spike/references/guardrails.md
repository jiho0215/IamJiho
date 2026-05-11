# Global Guardrails

These principles apply to every agent dispatched by `/spike` and to every artifact produced (freeze docs, research docs, ADRs, code). Reference this file from agent system prompts; do not inline.

## Design

- **SOLID** — single responsibility, open/closed (interfaces for extensibility), Liskov, interface segregation, dependency inversion. Even one-shot internal modules ship with an interface seam.
- **DRY** — but not at the cost of premature abstraction. Three repetitions before extraction.
- **YAGNI** — produce what the current ticket needs; defer forward-compat to its own ticket. "While we're here" is a smell.
- **Small start, edge-case complete** — minimum viable scope, but every named edge case is test-covered.

## Code

- **Follow existing repo style.** Read 3-5 files in the area before writing. Match naming, error handling, async/sync patterns.
- **Inline comments minimal.** Code should explain itself via naming and structure. Comments only for non-obvious *why* (not *what*).

## Documentation

- **ADRs concise.** One decision, one reasoning, one set of consequences. Link rather than restate.
- **Spec/freeze docs are contracts.** Once approved, immutable. Modify via `/spike --revisit`.

## Investigation (Research agent specific)

- **Doc != Reality.** Findings tagged with confidence; load-bearing doc-only items get verification recipes.
- **Read-only by default.** Mutating ops (HTTP write methods, DB writes, fs writes outside docs/plan/, process control) require explicit per-call user confirm.
- **Secrets never persist.** Mask before write; never log.
