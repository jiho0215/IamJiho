# Testing Strategy

Testing is not optional. Every feature requires all 4 test types and >= 90% branch coverage.

## Coverage Requirement

**Metric: Branch coverage >= 90%**

Branch coverage measures whether both true and false paths of every conditional are exercised. This is more meaningful than line coverage because it catches missing logic paths.

Use the project's coverage tool to measure. Common tools:
- JavaScript/TypeScript: c8, istanbul, v8
- C#/.NET: coverlet
- Python: coverage.py
- Go: go test -cover
- Java: JaCoCo

## Test Types

All 4 types are mandatory for every feature.

### Unit Tests

**Purpose:** Test a single function/module in isolation.

- External dependencies are mocked (databases, APIs, file system)
- One test file per source file
- Test both happy path and error paths
- Test edge cases and boundary conditions
- Should run in milliseconds

### Integration Tests

**Purpose:** Test multiple modules working together.

- May use real databases, file systems, or services
- Verify that components communicate correctly
- Test data flows through multiple layers
- Should cover the main integration paths

### Smoke Tests

**Purpose:** Verify the system starts and critical paths respond.

- Run first in CI as a gate — if smoke tests fail, don't run the full suite
- Test that the application boots successfully
- Test that critical endpoints/routes respond with expected status codes
- Test that database connections work
- Should complete in under 30 seconds

### E2E Tests

**Purpose:** Test complete user workflows through the actual interface.

- Use a real browser (for web), real device/emulator (for mobile), or real CLI
- Test the most important user journeys end-to-end
- For libraries: exercise the public API surface with real inputs/outputs
- May be slower — focus on critical paths, not exhaustive coverage

## Test-Requirements Traceability

Every test must trace back to a specific requirement. Maintain a traceability matrix:

| Requirement | Test File | Test Name | Test Type |
|-------------|-----------|-----------|-----------|
| REQ-001 | auth.test.ts | should login with valid credentials | Unit |
| REQ-001 | auth.integration.test.ts | should persist session | Integration |

## Test Quality

- **Independent:** Each test runs independently — no test depends on another's side effects
- **Deterministic:** Same input always produces same result — no flaky tests
- **Fast:** Unit tests in milliseconds, integration in seconds, E2E in tens of seconds
- **Descriptive:** Test names describe the behavior being tested, not the implementation
- **Maintainable:** Tests survive refactoring — test behavior, not implementation details

## TDD Workflow

Tests are written first, before implementation:

1. Write a failing test that describes the desired behavior
2. Write the minimum code to make it pass
3. Refactor while keeping tests green
4. Repeat

This is enforced by the `superpowers:test-driven-development` skill during Phase 5.
