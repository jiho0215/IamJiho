---
ticketIdOrSlug: <id-or-slug>
epicId: <epic-id-or-null>
question: <one-line>
status: DRAFT  # DRAFT | APPROVED
approvedAt: <iso-utc-or-null>
approvedBy: <user-or-null>
methodology:
  externalDocs: 0
  codebaseExplore: 0
  empiricalTest: 0
  userCollab: 0
  behavioralObservation: 0
---

# Research: <one-line title>

## §1 Question

<Parent-supplied question + scope. State what we're trying to learn and why it blocks Story specs.>

## §2 Methodology

<Strategies used and counts. Example:
- external-docs: 3 URLs (Stripe API ref v3.2; webhook guide v2; community blog dated 2025-11)
- codebase-explore: 12 files in src/payments/
- empirical-test: 5 calls (signature verify happy path + 4 edge cases)
- user-collab: 1 confirmation (refund timing semantics)
>

## §3 Findings

<Key facts. Each finding has a confidence tag and a citation.

Format:
- **<finding>** — `verified-empirically` | `doc-only` | `inferred-from-code` | `user-confirmed`
  Source: <url-or-file-line-or-call-id>
  Notes: <optional clarifier>
>

## §4 Schemas / Types

<Extracted shapes (TS, JSON, OpenAPI). Also commit as separate files under `docs/plan/{epic-or-slug}/schemas/`.>

```ts
// Example
export type StripeChargeRefunded = {
  id: string;
  object: 'charge';
  amount_refunded: number;
  // ...
};
```

## §5 Edge Cases Observed

<Behaviors NOT in docs but observed empirically or in code. Each entry has a confidence tag.>

## §6 Open Questions

<Items unresolved by this research. Parent escalates to user if blocking.>

## §7 Decision Impact

<Which Story specs (or future implementation choices) are affected and how. Used by parent spike at P4 to update freeze docs.>

## §8 References

<URLs (with doc version), payload sample paths (under `docs/plan/{epic-or-slug}/samples/`; secrets masked).>

## §9 Verification Backlog

<doc-only or inferred findings load-bearing for >=1 blocked Story ticket. Each item has a verification recipe.

Format:
- **Finding:** <text>
  Confidence: doc-only
  Affected Stories: <ticket-ids>
  Recipe:
  ```
  curl -X POST http://localhost/webhooks/stripe \
    -H "Stripe-Signature: invalid" -d '{"type":"test"}'
  ```
  Expected: 401. Actual: ___
>
