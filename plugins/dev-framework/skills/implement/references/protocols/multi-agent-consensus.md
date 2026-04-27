# Multi-Agent Consensus Protocol

> Internal reference for `skills/implement/SKILL.md`. Invoked by reading this file, not via the Skill tool.

A reusable protocol for running N agents in parallel on any task, then converging to the best solution through structured discussion and iterative validation.

This is the engine behind the dev-framework's quality guarantees. It works the same way whether reviewing requirements, designing architecture, validating code, or resolving issues.

## Why This Works

A single pass by a single agent misses things. Multiple independent perspectives catch blind spots, surface edge cases, and produce stronger outcomes. The iterative convergence loop ensures issues are actually resolved — not just acknowledged and forgotten.

## Configuration

The protocol accepts these parameters. The caller provides them (or uses defaults):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `agents` | 3 | Number of agents to run in parallel |
| `max_iterations` | 10 | Maximum iteration rounds before forced stop |
| `exit_on` | `zero_total` | Convergence criterion: `zero_total` (current behavior — every Minor/Nit blocks) or `zero_blocking` (only Critical+Major block; Minor+Nit go to backlog without gating) |
| `zero_threshold` | 2 | When `exit_on=zero_total`: consecutive zero-issue rounds needed. When `exit_on=zero_blocking`: ignored (single zero-blocking round exits). |
| `task_type` | — | One of: `plan`, `implement`, `validate`, `review` |
| `agents_list` | — | Which specific agents to dispatch (by name) |
| `context` | — | Task description, requirements, files to examine |
| `quality_target` | "high" | Quality bar: "high" requires thorough reasoning |
| `backlog_path` | null | When `exit_on=zero_blocking`: path to a markdown file where Minor/Nit findings are appended for caller follow-up. Null = findings logged in iteration output only (caller routes manually). |

When invoking this skill, the caller specifies these parameters. Example:

```
Invoke multi-agent-consensus with:
  agents: 3
  max_iterations: 10
  zero_threshold: 2
  task_type: validate
  agents_list: [code-quality-reviewer, observability-reviewer, performance-reviewer]
  context: "Review implementation of user authentication feature against requirements in docs/specs/auth-requirements.md"
```

## Critical Rule — Never Short-Circuit the Loop

**NEVER fix issues and declare convergence in a single pass.** The protocol requires:

1. Dispatch agents → find issues → fix issues → **re-dispatch agents to verify fixes**
2. Only declare CONVERGED after `zero_threshold` consecutive rounds with zero NEW issues
3. A round where you fix issues but do not re-validate is **NOT** a zero-issue round — it is an incomplete iteration

If you catch yourself thinking *"I fixed everything, so it's done"* — **STOP**. That thought is the exact moment the loop matters most. Fixes can introduce new issues, miss edge cases, or be incomplete. Only the re-validation round can confirm the fix actually worked.

**Common violations to watch for:**
- Running 1 reviewer, fixing issues, declaring "done" without re-running reviewers
- Substituting a manual single-agent check for the full N-agent parallel dispatch
- Counting a "fix round" as a "zero-issue round" because you believe the fixes are correct

---

## Protocol Phases

The protocol has three phases. The caller chooses which phase(s) to run. Each phase follows the same core loop but with different objectives.

---

### Phase: PLAN

**Objective**: Produce the best possible plan for a task.

**Step 1 — Parallel Planning**
Dispatch `agents` count of agents concurrently. Each agent independently:
1. Analyzes the context/requirements
2. Produces a plan with reasoning for every decision
3. Identifies risks, trade-offs, and alternatives considered
4. Targets high quality — no shortcuts, no hand-waving

**Step 2 — Discussion Round**
Once all agents complete:
1. Collect all plans
2. Identify areas of agreement (these are likely correct)
3. Identify areas of disagreement (these need resolution)
4. For each disagreement, agents present their reasoning
5. Select the strongest approach based on reasoning quality, not majority vote alone — a well-reasoned minority opinion beats a poorly-reasoned majority

**Step 3 — Produce Merged Plan**
Synthesize the best elements from all plans into one cohesive plan. Document why each choice was made.

---

### Phase: IMPLEMENT

**Objective**: Produce the best possible implementation of a task.

**Step 1 — Parallel Implementation**
Dispatch `agents` count of agents concurrently. Each agent independently:
1. Implements the task following the plan (if one exists)
2. Documents reasoning for implementation choices
3. Self-validates the result against requirements
4. Produces a concrete deliverable (code, document, config, etc.)

**Step 2 — Discussion Round**
Once all agents complete:
1. Collect all implementations
2. Compare approaches: correctness, completeness, elegance, maintainability
3. Identify the strongest implementation or best elements from each
4. Resolve conflicts through reasoning — the implementation that best satisfies requirements wins

**Step 3 — Produce Merged Result**
Take the best implementation (or merge best elements) into one deliverable. Validate it against requirements.

---

### Phase: VALIDATE

**Objective**: Find and resolve all issues until convergence.

This is the iterative phase. It loops until convergence.

**Step 1 — Parallel Validation**
Dispatch `agents` count of agents concurrently. Each agent independently:
1. Reviews the target (code, document, plan, etc.) thoroughly
2. Produces a list of issues with:
   - Clear description of the issue
   - Evidence (specific file, line, or section)
   - Severity per the rubric below — agents MUST use this rubric, not their own interpretation
   - Reasoning for why it's an issue
   - Suggested fix
3. Self-validates each issue: "Is this actually a problem, or am I being overly pedantic?"

**Severity Rubric** (concrete definitions — included in agent prompts to prevent inflation):

| Severity | Definition | Examples |
|----------|------------|----------|
| **CRITICAL** (a.k.a. Blocking) | Ship 시 data corruption / security breach / production outage 가능 | SQL injection, race condition causing duplicate writes, missing auth check, broken migration |
| **HIGH** (a.k.a. Major / Blocking) | Oncall이 incident 디버그 불가 / documented contract 깨짐 / concurrency bug | Missing required telemetry on critical path, breaking API change without deprecation, untested concurrency-sensitive code |
| **MEDIUM** (a.k.a. Minor / Non-blocking) | System 동작. 개선 기회 (test coverage gap, naming, completeness) | Test coverage gap on edge case, suboptimal but functional naming, missing-but-not-required documentation |
| **LOW** (a.k.a. Nit / Non-blocking) | Style / 문서 / 부가 thoroughness | Whitespace, doc-comment improvements, alternate phrasing suggestions |

**When `exit_on=zero_blocking`**: only CRITICAL + HIGH issues block convergence. MEDIUM + LOW issues are listed in the iteration output AND optionally appended to `backlog_path` (when caller provides one), but do NOT gate the loop. This prevents low-severity findings from accumulating across iterations and inflating scope — a known anti-pattern where iterative review converts every "could be more thorough" comment into a must-fix.

**When `exit_on=zero_total` (default for back-compat)**: every issue regardless of severity blocks convergence per the original protocol. Use this when the consumer requires absolute zero-issue convergence (e.g., security-critical contexts where Minor/Nit findings should not be deferred).

**Severity inflation guardrails**: agents tend to over-classify findings as CRITICAL or HIGH to ensure they're addressed. Mitigation:
- The rubric uses concrete examples ("SQL injection", "missing auth check") so agents have a baseline
- Caller MUST include the rubric block verbatim in agent task prompts
- If the caller observes inflation patterns (e.g., 80% CRITICAL across iterations), they should add a calibration note to the prompt: "If your finding doesn't match the CRITICAL examples above, classify lower"
- User can override severity in the merged output with rationale recorded in `decision-log.json`

**Step 2 — Issue Consolidation**
Once all agents complete:
1. Collect all issue lists
2. Deduplicate: same issue found by multiple agents = higher confidence
3. Validate each unique issue:
   - Does the reasoning hold up?
   - Is there actual evidence?
   - Would fixing this meaningfully improve quality?
4. Discard false positives with clear reasoning for dismissal
5. Produce a validated issue list

**Step 3 — Issue Resolution**
For each validated issue (highest severity first):
1. All agents propose a fix with reasoning
2. Select the best fix based on reasoning quality
3. Apply the fix
4. Verify the fix doesn't introduce new issues

**Step 4 — Iteration Check**

After resolving all issues in this round, behavior depends on `exit_on`:

**`exit_on: zero_total` (default — back-compat)**:
- If validated issues found > 0: increment iteration counter, apply fixes, **then go back to Step 1 to re-validate the fixes** (this is mandatory — never skip re-validation)
- If validated issues found = 0 (agents were dispatched and found nothing new): increment zero counter
  - If zero counter >= `zero_threshold`: **CONVERGED** — stop
  - Otherwise: go back to Step 1 for one more confirmation round
- If iteration counter >= `max_iterations`: **FORCED STOP** — escalate remaining issues to caller

**`exit_on: zero_blocking` (severity-gated)**:
- Partition issues by severity: blocking = CRITICAL + HIGH, non-blocking = MEDIUM + LOW.
- Append all non-blocking issues to `backlog_path` (when provided) with iteration-N attribution.
- If blocking issues > 0: increment iteration counter, apply fixes for blocking issues only (non-blocking deferred to backlog), **go back to Step 1 to re-validate**.
- If blocking issues = 0: **CONVERGED** — stop. (Single zero-blocking round suffices; `zero_threshold` is ignored in this mode.)
- If iteration counter >= `max_iterations`: **FORCED STOP** — escalate ALL remaining blocking issues to caller (non-blocking already in backlog).

**Important:** In both modes, the zero counter / convergence trigger only fires when agents are dispatched and return zero issues at the relevant severity level. Fixing issues without re-dispatching agents does not count toward convergence.

---

## The Core Loop (Visual)

```
┌─────────────────────────────────────────┐
│          DISPATCH N AGENTS              │
│      (parallel, independent work)       │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│         COLLECT & DISCUSS               │
│   (compare, debate, reason together)    │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│       MERGE / RESOLVE / FIX             │
│  (best reasoning wins, apply changes)   │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│         CONVERGENCE CHECK               │
│  issues=0 twice in a row? → DONE        │
│  iterations >= max? → ESCALATE          │
│  otherwise → LOOP BACK                  │
└─────────────────────────────────────────┘
```

## Output Format

Every invocation produces a structured report:

```markdown
# Multi-Agent Consensus Report

## Configuration
- Agents: [count]
- Task type: [plan/implement/validate/review]
- Max iterations: [N]
- Zero threshold: [N]

## Iteration Log

### Iteration 1
- **Issues found by Agent 1**: [N] ([list])
- **Issues found by Agent 2**: [N] ([list])
- **Issues found by Agent 3**: [N] ([list])
- **After dedup/validation**: [N] valid issues
- **Resolutions applied**: [list of fixes with reasoning]

### Iteration 2
[...]

## Convergence
- **Converged at iteration**: [N]
- **Total issues found and resolved**: [N]
- **Remaining unresolved** (if forced stop): [list]

## Decisions Made
[List of significant decisions for docs/decisions.md]
```

## Integration Notes

This protocol is read (via the Read tool) by `skills/implement/SKILL.md` in every phase that uses multi-agent consensus. The orchestrator provides the specific agents, context, and parameters — this file provides the protocol mechanics.

When a consensus round resolves a significant decision, the orchestrator should follow `references/protocols/project-docs.md` to log it in `docs/decisions.md`.

## Discussion Quality Guidelines

The goal of discussion is not democratic voting — it's finding the strongest reasoning. Guidelines for agents during discussion:

- **Disagree with evidence**: "I found X at line Y which contradicts this approach because Z"
- **Concede with reasoning**: "Agent-2's approach handles edge case X better than mine because..."
- **Escalate genuine trade-offs**: "Both approaches are valid but optimize for different things: A optimizes for performance, B for maintainability. The caller should decide."
- **Never agree to avoid conflict**: If you believe something is wrong, say so with evidence. Silent agreement is worse than a resolved disagreement.
