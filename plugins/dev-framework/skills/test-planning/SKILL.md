---
name: test-planning
version: 1.0.0
description: |
  Generate structured test plans with layered architecture, event-type grouping,
  and cross-validation patterns. Use when: planning tests for a feature or ticket,
  user says "plan tests", "test strategy", "TDD plan", or dev-pipeline Phase 4 runs.
---

# Test Planning

Generate a structured, layered test plan for a feature or ticket. Produces a `tdd-plan.md` document with test IDs, dependency chains, event-type grouping, and execution order.

## Inputs Required

Before running this skill, you need:
- **Feature/ticket description** — what's being built
- **Codebase architecture** — what components exist, how data flows
- **Implementation plan** — what will be changed/created

If invoked by dev-pipeline, these come from Phase 1-3 artifacts in the session folder.

---

## Step 1: Identify Test Layers

Map the feature to a layered test architecture. Not every feature needs all layers — skip what doesn't apply.

| Layer | What It Tests | When to Include |
|-------|--------------|-----------------|
| **Layer 0: Data Pipeline** | Backend data flow (API → service → DB) | Feature has API endpoints, data transformations, or external integrations |
| **Layer 1: Cross-Validation** | Same data verified across multiple views | Feature data appears in 2+ screens/components |
| **Layer 2: Per-Feature** | Page/component-level behavior by event type | Always — every feature has this layer |

**Layer 0** proves the backend produces correct data.
**Layer 1** proves all consumers of that data agree.
**Layer 2** proves each consumer works correctly in isolation.

If Layer 0 passes, Layer 2 tests can trust seed/mock data (no need to test the pipeline in every screen test).

---

## Step 2: Group Tests by Event Type

For each Layer 2 feature, categorize ALL possible tests into event types. This ensures nothing is missed — every interaction the user or system can have is covered.

| Event Type | What to Test | Examples |
|------------|-------------|---------|
| **Data events** | Query loading, success, empty state, derived values, cache invalidation, type normalization, edge values (zero, negative, null) | "Query succeeds with data", "Empty list shows placeholder", "Derived total excludes credit cards" |
| **User events** | Taps, toggles, multi-select, pull-to-refresh, forms, double-tap guards, panel mutual exclusion | "Tap header collapses section", "Pull-to-refresh triggers refetch" |
| **Navigation events** | Deep links, tab focus (fresh vs stale), back button state preservation, parameter passing between screens | "Deep link scrolls to target account", "Back button preserves panel state" |
| **System events** | Offline/online transitions, cache hydration (cold start), expired cache, logout cleanup, flaky network | "Offline shows banner + disables mutations", "Logout clears all cached data" |
| **Time events** | staleTime expiry, timeout cleanup, debounce, token refresh timing | "After 60s, tab refocus triggers background refetch" |
| **Error events** | HTTP errors by code (401/403/404/500), network errors, retry behavior, error-specific UI messages | "403 shows 'no access' message", "500 retries twice then shows error" |

**Rule:** If an event type has zero tests for a feature, explicitly document why (e.g., "No time events — no staleTime-dependent behavior").

---

## Step 3: Define Seed/Mock Profiles

Identify data profiles needed for deterministic testing:

| Profile | Purpose | Data Characteristics |
|---------|---------|---------------------|
| `standard` | Empty state tests, pipeline tests | Users exist, no linked data |
| `data-loaded` | All UI tests (fast, deterministic) | Full data: accounts, transactions, relationships |
| `error-state` | Error path testing | Configured to trigger specific error responses |

**Rules:**
- Seed profiles must produce **identical** data on every run (deterministic)
- Document exactly what data each profile creates
- If testing against a real pipeline (Layer 0), also verify seed data matches pipeline output

---

## Step 4: Map Dependency Chains

Identify prerequisite relationships:

```
TEST-A → TEST-B means B requires A to pass first
```

Group tests into execution chains. Tests within a chain run sequentially; independent chains can run in parallel.

**Example:**
```
Chain 1: PL01 → PL04 → PL06 → PL08 → PL09
Chain 2: AC-D01 → AC-D02 → AC-D03 → AC-U01
Chain 3: TX-D01 → TX-U01 → TX-U09 → TX-U11
```

---

## Step 5: Build Cross-Validation Matrix

If the same data appears in multiple views, create cross-validation tests:

| Data Point | View A | View B | View C | Test ID |
|-----------|--------|--------|--------|---------|
| Account balance | Accounts page | Buckets page | Home page | XC-01 |
| Transaction row | Transactions page | Bucket detail | Home recent | XC-02 |

**Cross-validation rules:**
- Same data source (seed or pipeline) → must render identically across views
- Different data sources (seed vs pipeline) → must produce equivalent results
- If a cross-validation test fails, it indicates a data flow inconsistency (highest-value finding)

---

## Step 6: Generate Test Plan Document

Write to `{SESSION_DIR}/tdd-plan.md` (or project docs if standalone):

```markdown
# Test Plan: {TICKET or Feature Name}

> Generated: {date}
> Coverage target: {config.pipeline.testCoverageTarget}% branch coverage

## Test Summary

| Layer | Tests | Description |
|-------|-------|-------------|
| Layer 0: Data Pipeline | {N} | Backend data flow verification |
| Layer 1: Cross-Validation | {N} | Cross-view data consistency |
| Layer 2: Per-Feature | {N} | Component behavior by event type |
| **Total** | **{N}** | |

## Seed Profiles

| Profile | Purpose | Key Data |
|---------|---------|----------|

---

## Layer 0: Data Pipeline

| ID | Event | API/Trigger | Verification | Prereq | Status |
|----|-------|-------------|-------------|--------|--------|

---

## Layer 1: Cross-Validation

| ID | Data Point | Views Compared | Verification | Status |
|----|-----------|---------------|-------------|--------|

---

## Layer 2: Per-Feature

### {Feature/Page Name}

#### Data Events ({N} tests)
| ID | Event | Trigger | Expected Result | Prereq | Status |
|----|-------|---------|----------------|--------|--------|

#### User Events ({N} tests)
| ID | Event | Trigger | Expected Result | Prereq | Status |

#### Navigation Events ({N} tests)
| ID | Event | Trigger | Expected Result | Prereq | Status |

#### System Events ({N} tests)
| ID | Event | Trigger | Expected Result | Prereq | Status |

#### Time Events ({N} tests)
| ID | Event | Trigger | Expected Result | Prereq | Status |

#### Error Events ({N} tests)
| ID | Event | Error | Expected Result | Prereq | Status |

---

## Dependency Graph

{Mermaid or ASCII dependency chains}

## Execution Order

1. Layer 0 (data pipeline) — proves data correctness
2. Layer 1 (cross-validation) — proves data consistency
3. Layer 2 per-feature by priority:
   - P0: Core path (empty → data → interact → navigate)
   - P1: Important (cross-account, offline, errors, timing)
   - P2: Defensive (normalization, null guards, race conditions)

## Task Execution Cycle

Each test group follows this cycle:

### Phase 1: Review
- Read code paths end-to-end for this group
- Check existing tests — what's already covered?
- Map all branches and edge cases

### Phase 2: Plan
- Identify missing scenarios
- Add to this plan document if discovered

### Phase 3: Implement
- Write tests for this group
- Run all tests — every test must pass

### Phase 4: Review Loop
- Max iterations: config.pipeline.maxReviewIterations
- Early exit: config.pipeline.consecutiveZerosToExit consecutive clean rounds
- Check: code quality, plan alignment, coverage gaps, conventions

### Phase 5: Update
- Mark completed tests: ❌ → ✅
- Update counts and progress percentage
```

---

## Rules

1. **One test group at a time** — complete and verify before moving to next
2. **All tests must pass** — no skipped or pending tests left behind
3. **Event-type grouping is exhaustive** — if an event type has zero tests, document why
4. **Cross-validation tests have highest value** — prioritize after Layer 0
5. **Seed profiles must be deterministic** — same data on every run
6. **Test IDs are stable** — use prefix per layer/feature (PL-, XC-, AC-D-, TX-U-, etc.)
7. **Coverage target is a floor** — `config.pipeline.testCoverageTarget`% branch minimum
