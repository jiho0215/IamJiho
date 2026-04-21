# Freeze Doc Template

Single-artifact contract for a feature's research phase. Written during Phase 1-3 of `/implement`, approved by the user at GATE 1 (end of Phase 3), and treated as the immutable truth source during Phase 4-7 execution.

## File Location

`docs/specs/[feature-slug]-freeze.md`

`[feature-slug]` is derived from the feature description or ticket title — lowercase kebab-case, stable across all artifacts for the feature.

## Template

```markdown
---
feature: [feature-slug]
status: DRAFT
createdAt: [ISO-8601 UTC]
approvedAt: null
approvedBy: null
approvalMode: null            # "interactive" or "autonomous" when set at approval time
bypassHistory: []
supersededBy: null
frozenCategories:
  - business-logic
  - api-contracts
  - third-party
  - data
  - error-model
  - acceptance-criteria
  - security
  - performance
nonFrozenAllowList:
  - observability
  - railroad-composition
  - pure-function-composition
customCategories: []
---

# Freeze Doc: [Feature Name]

Purpose: a single-artifact contract that freezes every decision required to execute this feature. After GATE 1 approval, all categories §1-§8 become immutable for the duration of execution. Changes require ticket update (supersede this freeze doc).

---

## § 1. Business Logic

**Purpose:** Domain rules, decision flows, validation rules.

### Decisions
| ID | Rule | Rationale | Source |
|----|------|-----------|--------|
| BL-01 | [rule] | [why] | [ticket/discussion ref] |

### Open Questions
All items must be empty before GATE 1 approval.
- [ ] (none)

---

## § 2. API Contracts (Internal)

**Purpose:** Internal endpoint paths, methods, request/response schemas, auth.

**Rule:** Follow existing repo conventions first. Document deviations explicitly in "Proposed Deviations."

### Conventions Followed
List observed patterns from the existing codebase that this feature will follow.
- [pattern, e.g., "REST style: /api/v1/{resource}/{id}"]
- [pattern, e.g., "Response wrapper from src/api/response.ts"]

### Endpoints
| Method | Path | Auth | Request Schema | Response Schema |
|--------|------|------|----------------|-----------------|
| [METHOD] | [path] | [required/optional/none] | [schema name] | [schema name] |

### Request/Response Schemas
Concrete type definitions for each schema referenced above. Use the target language's type syntax (TypeScript, C# record, Python dataclass, etc.) matching repo conventions.

```typescript
// Example
type CreateXRequest = {
  // ...
};

type XResponse = {
  data: { /* ... */ };
  error: null;
  meta: { requestId: string };
};
```

### Proposed Deviations
None. / Or: list deviations with rationale. Each deviation requires explicit user acknowledgment at GATE 1.

---

## § 3. 3rd Party Integrations

**Purpose:** External API usage — payload, rate limit, retry, cache.

### Integrations
| Service | Endpoint | Payload Ref | Rate Limit | Retry Policy | Cache TTL |
|---------|----------|-------------|------------|--------------|-----------|
| [Name] | [path] | [schema link] | [req/s] | [strategy] | [duration or N/A] |

### Secrets & Credentials
- **Storage:** [where credentials live, e.g., AWS Secrets Manager path]
- **Rotation:** [policy or N/A]
- **Scope of access:** [which service account, narrowest permissions]

---

## § 4. Data & Database

**Purpose:** DB schema changes, enums, migrations, backfills. These are always decided together — a schema change without a migration plan is incomplete.

### Schema Changes
```sql
-- DDL for new tables, columns, indexes, constraints
```

### Enums
| Enum | Values | Default | Notes |
|------|--------|---------|-------|
| [Name] | [VALUE1, VALUE2, ...] | [default] | [transition rules, ref to § 1] |

### Migration Strategy
- **Forward:** [migration file or approach]
- **Rollback:** [approach, including data preservation]

### Backfill Plan
- **Existing rows:** [handling — default values, computed, left null, etc.]
- **Timing:** [when backfill runs — inline in migration, separate job, on-demand]
- **Estimated duration:** [time for N rows]

---

## § 5. Error Model

**Purpose:** Error codes, user-facing messages, recovery paths.

### Errors
| Code | Message (user-visible) | HTTP | Recovery Action |
|------|------------------------|------|-----------------|
| [CODE] | [message shown to user] | [status] | [what the user or system does next] |

---

## § 6. Acceptance Criteria

**Purpose:** Testable feature-complete conditions. Each item must be verifiable by an automated test or observable behavior.

- [ ] AC-01: [testable condition]
- [ ] AC-02: [testable condition]

---

## § 7. Security / Auth

**Purpose:** Authorization model, sensitive data handling, threat surface.

### Authorization Model
- **Endpoint scopes:** [permissions required per endpoint]
- **Row-level access:** [who can read/modify which rows]

### Sensitive Data Handling
- **PII:** [fields, masking rules in logs, encryption at rest]
- **Credentials/tokens:** [storage rules, never-log rules]

### Threat Surface
- **Identified threats:** [IDOR, CSRF, payment amount tampering, etc.]
- **Mitigations:** [what is in place for each]

---

## § 8. Performance

**Purpose:** SLA, throughput, resource budgets.

### Budgets
| Metric | Target | Measurement Point |
|--------|--------|-------------------|
| p95 latency | [ms] | [endpoint or operation] |
| p99 latency | [ms] | [same] |
| Sustained throughput | [req/s] | [same] |
| DB queries per request | [N] | [no N+1] |
| Memory delta per request | [MB] | [heap profiling target] |

---

## § 9. Non-Frozen Questions (Execution-Phase Rules)

**Purpose:** Rules for LLM question handling during Phase 4-7.

### Zone 1 — 🛑 FROZEN (workflow halts on violation)
All decisions in §1-§8 above. Any question that would change one of these decisions triggers:
```
🛑 HALT: Question requires change to frozen category [name].
Update the ticket/freeze doc (supersede this freeze doc) before proceeding.
```

### Zone 2 — ✅ NON-FROZEN (may ask user)
- Observability details (log level, metric name, span naming)
- Railroad / Result chain composition
- Pure function composition and decomposition

Plus any additional entries in `nonFrozenAllowList` (config extension).

### Zone 3 — 🤔 AMBIGUOUS (4-tier context rule)
1. **Existing code in this repo** → follow the pattern silently. If deviation seems necessary, ask using the "Ask with Suggestion" format.
2. **User-provided reference repo/example** → treat same as existing code.
3. **Initial implementation (no anchor)** → ask liberally to capture user intent.
4. **None of the above** → self-decide using `references/standards/`.

### Zone 4 — ⚙️ SELF-DECIDE (no question)
Pure technical choices: variable/function naming, internal module boundaries, refactor/extract decisions, test fixture implementation details. Decide using standards and context.

### "Ask with Suggestion" Format (mandatory)

When Zone 3 tier 1 or tier 2 requires a question:

```
📋 Context: [observed existing pattern or reference]
🔍 Observation: [why this case seems to need deviation]
💡 Proposal: [proposed alternative with reasoning]
❓ Decision needed: [concrete question for user]
```
```

## Rendering Notes

- Categories in `frozenCategories` (frontmatter) must match the order and names of the body sections §1-§8.
- `nonFrozenAllowList` entries are consulted by the LLM during Phase 4-7 question handling.
- `customCategories` (from `~/.claude/autodev/config.json` → `pipeline.freezeDoc.categories` extensions) get additional `§` sections rendered after §8 using the template from `config.pipeline.freezeDoc.customCategoryTemplatesDir/{category}.md`.
- `bypassHistory` is append-only. Entries are added by Phase 7 GATE 2 (the sole writer) which merges records from `bypass.json` and `bypass-audit.jsonl` (filtered by current `runId`, deduped by `at`). Each entry contains `{ at, reason, feature, userMessage, runId, preservedAt? }`. `preservedAt` is present only when the entry was archived through `bypass-audit.jsonl` (i.e., the session was interrupted after the bypass was created but before Phase 7 ran).
- **Frozen categories extension:** the `frozenCategories` list in frontmatter must be extended at render time if `config.pipeline.freezeDoc.categories` contains entries beyond the default 8. SKILL.md Phase 3 populates this list dynamically.

## Status Transitions

```
DRAFT ──(Phase 1-3 population)──▶ DRAFT ──(all open questions closed)──▶ PENDING_APPROVAL
PENDING_APPROVAL ──(GATE 1 approve)──▶ APPROVED
PENDING_APPROVAL ──(GATE 1 reject)──▶ DRAFT (reopen specified categories)
APPROVED ──(ticket update needed)──▶ SUPERSEDED (new freeze doc created, supersededBy set)
```

## Example Real Freeze Doc (abbreviated)

```yaml
---
feature: order-bulk-create
status: APPROVED
createdAt: 2026-04-19T09:00:00Z
approvedAt: 2026-04-19T11:32:00Z
approvedBy: jane@example.com
approvalMode: interactive
bypassHistory: []
supersededBy: null
frozenCategories:
  - business-logic
  - api-contracts
  - third-party
  - data
  - error-model
  - acceptance-criteria
  - security
  - performance
nonFrozenAllowList:
  - observability
  - railroad-composition
  - pure-function-composition
customCategories: []
---

# Freeze Doc: Order Bulk Create

## § 1. Business Logic
| ID | Rule | Rationale | Source |
|----|------|-----------|--------|
| BL-01 | Confirmed orders require successful payment | Prevents refund risk | ACME-123 |
| BL-02 | Bulk create accepts partial failures (returns per-item status) | Client UX decision | Design review 2026-04-15 |

## § 2. API Contracts (Internal)
### Conventions Followed
- REST style: /api/v1/{resource}
- Response wrapper from src/api/response.ts: { data, error, meta }

### Endpoints
| Method | Path | Auth | Request Schema | Response Schema |
|--------|------|------|----------------|-----------------|
| POST | /api/v1/orders/bulk | required | BulkCreateRequest | BulkCreateResponse |

(... remaining sections filled in similarly ...)
```
