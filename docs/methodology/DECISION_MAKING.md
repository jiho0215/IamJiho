# Decision Making — Multi-Agent Consensus Protocol

Every phase of the development cycle uses this protocol to ensure decisions are thorough, well-reasoned, and validated from multiple perspectives.

## The Protocol

### Step 1: Independent Analysis

Dispatch 3+ agents in parallel. Each agent works independently with no visibility into other agents' outputs. This isolation prevents groupthink and ensures diverse perspectives.

**Mechanism:** Multiple `Agent` tool calls in a single message. Each agent runs as a separate subprocess with its own context.

### Step 2: Discussion Round

The orchestrator collects all agent outputs and combines them:
- Identify areas of agreement (these are likely correct)
- Identify conflicts (these need resolution)
- Identify gaps (these need additional analysis)
- Tag each issue with severity and the agent that raised it

### Step 3: Issue Resolution Loop

**Maximum 5 iterations.** For each valid issue:

1. Dispatch agents in parallel to propose solutions with reasoning
2. Orchestrator evaluates proposals and selects the best by reasoning quality
3. Apply the selected solution

**Issue Validity Criteria:**

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

**Non-convergence:** If the loop reaches 5 iterations without zero issues, escalate to the user with:
- The remaining issues
- What was tried for each
- Why it didn't converge
- The user decides: accept current state, provide guidance, or extend the loop

### Step 4: Final Confirmation Round

Dispatch all agents in parallel for one final review:
- Each confirms zero valid issues from their perspective
- If ANY agent finds a new issue → back to Step 3 (counts toward iteration limit)
- Only proceed when ALL agents confirm zero issues

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

This preserves the decision history — you can always trace why things changed.
