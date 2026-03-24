# Development Cycle

The development framework enforces a 7-phase cycle for every feature, task, or change. No exceptions regardless of task size.

## Core Philosophy

- **Move slow, do it right.** Reduce revisits and refactoring.
- **Full rigor always.** 3+ agents per step, discussion loops until zero issues.

## Phases Overview

| Phase | Mode | Description |
|-------|------|-------------|
| 1. Requirements | Interactive | Gather and validate requirements with user |
| 2. Architecture | Interactive | Design system structure, produce ADRs |
| 3. Planning | Interactive → Gate | Create implementation plan, get user approval |
| 4. Testing Strategy | Autonomous | Design test approach, produce test plan |
| 5. Implementation | Autonomous | TDD implementation following the plan |
| 6. Verification | Autonomous | Run all tests, verify standards, code review |
| 7. Documentation | Autonomous | Update docs, ADRs, test documentation |

## Phase Details

### Phase 1: Requirements

**Goal:** Validated, complete, testable requirements with zero unresolved issues.

1. Gather information from the user through one-at-a-time clarifying questions
2. Dispatch 3 agents (requirements-analyst, architect, test-strategist) in parallel
3. Run consensus protocol (see DECISION_MAKING.md)
4. Output: Requirements document with acceptance criteria

### Phase 2: Architecture

**Goal:** Sound architecture with ADR documentation and zero unresolved issues.

1. Run consensus protocol with 3 agents on architecture design
2. Invoke `superpowers:brainstorming` for design exploration
3. Produce ADRs using the template
4. Output: ADR documents and architecture design

### Phase 3: Planning

**Goal:** Detailed implementation plan approved by the user.

1. 3 agents independently review the plan
2. Invoke `superpowers:writing-plans` for structured plan creation
3. Run consensus protocol
4. **User Gate:** Present plan for approval. Do not proceed without explicit confirmation.

### Phase 4: Testing Strategy

**Goal:** Comprehensive test plan covering all 4 test types with >= 90% branch coverage target.

1. 3 agents design the test approach
2. Map tests to requirements (traceability)
3. Produce test plan document
4. Output: Test plan with traceability matrix

### Phase 5: Implementation

**Goal:** Working code that passes all tests, following TDD.

1. Invoke `superpowers:test-driven-development` — tests first
2. Invoke `superpowers:executing-plans` — follow the plan
3. 3 review agents (code-quality, observability, performance) review the implementation
4. Run consensus protocol on review findings

### Phase 6: Verification

**Goal:** All tests pass, coverage meets threshold, all standards met.

1. Run all tests (unit, integration, smoke, E2E)
2. Verify >= 90% branch coverage
3. Invoke `superpowers:verification-before-completion`
4. Invoke `superpowers:requesting-code-review`
5. 3 agents verify against requirements, architecture, plan, and standards
6. Run consensus protocol

### Phase 7: Documentation

**Goal:** Documentation reflects what was built.

1. Update ADRs for implementation deviations
2. Update feature specs
3. Update test documentation with actual coverage
4. Scope boundary: documentation only — no new features or refactoring
