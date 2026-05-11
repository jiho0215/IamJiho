# Research Dispatch Protocol

**Internal protocol** — read by `skills/spike/SKILL.md` when handling a Research dependency. Not user-facing.

## Trigger

- **Epic mode**: spike P3 Decompose identifies a Research child ticket.
- **Story mode**: spike P2 Investigate determines a blocking question requires a Research agent.

## Steps

1. **Compute slug**: ticket-id for separate Research children, or descriptive slug (`research-<noun>-<aspect>`) for inline-in-Story.

2. **Compute paths**:
   - `outputDocPath = docs/plan/{epic-or-slug}/research-{ticketIdOrSlug}.md`
   - `schemasDir = docs/plan/{epic-or-slug}/schemas/`
   - `samplesDir = docs/plan/{epic-or-slug}/samples/`

3. **Build input JSON** matching the agent's input contract (see `agents/research-investigator.md`). Include `blockedStoryTickets: [ticketId, ...]` listing the Story tickets that depend on this research's output.

4. **Fan out the agent**:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/fan-out.sh \
     --name "research-${TICKET_OR_SLUG}" \
     --share-events
   # Returns child SESSION_DIR; child events flow into parent's events.jsonl
   ```

5. **Emit `research.dispatched`** with the input JSON's identifying fields.

6. **Invoke the agent in the child session** (via execute.sh or equivalent dispatcher) with the input JSON as task description.

7. **Wait for `research.completed`** event in the shared events.jsonl. Parent's reducer derives `ticket.research.completed` and unblocks the affected Story tickets (those listed in input `blockedStoryTickets`) in P4 Spec.

## Crash recovery

If parent resumes (`/spike --from N` or stateless wake) and `research.dispatched` exists for a ticket without a matching `research.completed`:

1. Inspect child SESSION_DIR for partial state. If `outputDocPath` exists, treat it as resumable input.
2. Emit `research.redispatched` with `{epicId, ticketIdOrSlug, attempt: N+1}`.
3. Re-fan-out the agent with the same input (idempotent — agent reads partial output and continues).

The agent's hard constraint #3 ensures it appends to prior output rather than overwriting.

## Parallelism

Independent Research children (no shared dependencies) MAY be dispatched in parallel — fan-out per ticket, all sharing the parent's events.jsonl via mkdir-locked seq counter (M1 atomic guarantee).

Do NOT parallelize Research children that depend on each other (DAG edges from P3 Decompose). Topological order required.

## Interaction routing

If `interactionAllowed=true` and the agent calls `AskUserQuestion`, the question surfaces to the same user driving the parent /spike. (See §7 of v5 spec for open verification of cross-session UI propagation; if the platform does not propagate, the agent escalates via a user-targeted message string in `research.findings.captured`.)
