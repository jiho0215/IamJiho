# Test Plan: [Feature Name]

**Date:** YYYY-MM-DD
**Feature Spec:** [Link to spec]
**Coverage Target:** >= 90% branch coverage

## Test Scope

### In Scope
- [What is being tested]

### Out of Scope
- [What is NOT being tested and why]

## Test Types

### Unit Tests

| Test ID | Description | Input | Expected Output | Requirement |
|---------|-------------|-------|-----------------|-------------|
| UT-001 | [Description] | [Input] | [Output] | REQ-001 |
| UT-002 | [Description] | [Input] | [Output] | REQ-001 |

### Integration Tests

| Test ID | Description | Components | Expected Behavior | Requirement |
|---------|-------------|------------|-------------------|-------------|
| IT-001 | [Description] | [Components] | [Behavior] | REQ-002 |

### Smoke Tests

| Test ID | Description | Expected Result |
|---------|-------------|-----------------|
| SM-001 | System starts successfully | HTTP 200 on health endpoint |
| SM-002 | Critical path responds | [Expected result] |

### E2E Tests

| Test ID | User Journey | Steps | Expected Outcome | Requirement |
|---------|-------------|-------|------------------|-------------|
| E2E-001 | [Journey] | [Steps] | [Outcome] | REQ-001 |

## Traceability Matrix

| Requirement | Unit Tests | Integration Tests | Smoke Tests | E2E Tests |
|-------------|-----------|-------------------|-------------|-----------|
| REQ-001 | UT-001, UT-002 | IT-001 | - | E2E-001 |
| REQ-002 | UT-003 | IT-002 | SM-002 | E2E-001 |

## Test Environment

- **Unit:** In-memory, mocked dependencies
- **Integration:** [Database, services used]
- **Smoke:** [Deployed environment]
- **E2E:** [Full environment]

## Coverage Report

(Updated after Phase 6 verification)

- **Branch coverage:** [X%]
- **Uncovered areas:** [List]
- **Justification for gaps:** [Why certain areas are not covered]
