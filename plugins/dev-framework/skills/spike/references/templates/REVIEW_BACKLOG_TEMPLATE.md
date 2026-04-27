---
epicId: <epic-slug>
purpose: "Minor/Nit findings from spike multi-agent consensus that did not block exit"
---

# Review backlog — <epic-slug>

> Findings classified as **Minor** or **Nit** during `/spike` Phase 1, 2, or 4
> consensus rounds. They did NOT block convergence (per `exit_on: zero_blocking`)
> but were captured here so they don't disappear silently.
>
> **This file is auto-appended** during multi-agent review rounds. Do not
> re-order entries by severity — chronological iteration order matters for
> retro analysis. Items can be:
>
> - **Accepted** during `/implement` Phase 4 (small fixes during ticket work)
> - **Deferred** to a follow-up epic (move to `bad-XX-followup.md`)
> - **Dismissed** with rationale (move to `decision-log.json` category `review-backlog-dismissed`)
>
> Every entry below should be one of the above by the time `/spike --retro`
> runs — items lingering without disposition are a signal to revisit
> the severity rubric or the prune step in design phases.

## Phase 2 iter 1 (architecture review)

<!-- Example entry — replace with real findings during operation:

- **[Minor]** Span event `ghost_bucket_rejected` regex non-match path silently
  skips emission. Forensic blind spot if validator's field naming changes.
  *Suggested handling*: WARN log at non-match branch. *Disposition*: deferred
  to /implement Phase 4 backlog (small fix during the ticket that touches
  the validator).

- **[Nit]** `RecordApplyEventPublished` doc says "publish attempts" — could
  clarify this is dispatch attempts, not delivery confirmations.
  *Suggested handling*: doc improvement during routine maintenance pass.
  *Disposition*: dismissed (cosmetic, low value).

-->

## Phase 4 iter 1 (cross-ticket gap review)

<!-- (empty until first Phase 4 review run) -->

## Disposition log

When an item above is accepted / deferred / dismissed, record HERE so the
backlog stays clean:

<!-- Format:
- 2026-04-27: <item snippet> → ACCEPTED in `/implement` ticket pay-123
- 2026-04-28: <item snippet> → DEFERRED to follow-up epic `bad-XX`
- 2026-04-28: <item snippet> → DISMISSED — see decision-log.json#review-backlog-dismissed-001
-->
