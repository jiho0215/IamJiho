# Decision Making — Issue Validity & ADR Lifecycle

The full multi-agent consensus protocol is defined in the `dev-framework:multi-agent-consensus` skill. This document covers supplementary guidance: issue validity criteria and ADR lifecycle rules.

## Issue Validity Criteria

An issue is **valid** if it:
- Causes incorrect behavior
- Violates a stated requirement
- Breaks a coding standard
- Creates technical debt

An issue is **invalid** if it:
- Is cosmetic preference
- Is already addressed by existing design decisions
- Is out of scope for the current task
- Is a duplicate of another issue

**Non-convergence:** If the consensus protocol does not converge within `max_iterations`, escalate to the user with the remaining issues, what was tried, and why it didn't converge. The user decides: accept current state, provide guidance, or extend the loop.

## Architecture Decision Records (ADRs)

Every architectural or design decision is documented as an ADR.

### ADR Lifecycle

1. **Proposed** — Initial draft during Phase 2
2. **Accepted** — After Phase 2 final confirmation, or Phase 3 user gate
3. **Superseded** — When a new decision replaces this one

### Immutability Rule

Once an ADR's status is "Accepted", its content is immutable. To change a decision:
1. Create a new ADR
2. Add `supersedes: ADR-NNN` to the new ADR's frontmatter
3. Update the old ADR's status to "Superseded by ADR-NNN"
4. Update the old ADR's `superseded_by` frontmatter field to the new ADR's ID

This preserves the decision history — you can always trace why things changed.
