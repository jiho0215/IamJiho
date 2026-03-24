# Code Review Checklist

Use this checklist during Phase 6 verification and standalone quality reviews.

## Standards Compliance

- [ ] **Result pattern:** All fallible operations return Result<T>
- [ ] **Early exit:** Guard clauses first, happy path not nested
- [ ] **Error handling:** Errors categorized (user/system/external), context preserved
- [ ] **File size:** No file exceeds 200 lines
- [ ] **Function size:** No function exceeds 30 lines
- [ ] **Single responsibility:** Each file/function does one thing
- [ ] **Naming:** Descriptive names, no abbreviations

## Testing

- [ ] **Branch coverage:** >= 90%
- [ ] **Unit tests:** All functions tested in isolation
- [ ] **Integration tests:** Component interactions verified
- [ ] **Smoke tests:** System starts, critical paths respond
- [ ] **E2E tests:** Key user workflows tested end-to-end
- [ ] **Test quality:** No flaky tests, tests are independent and deterministic
- [ ] **Traceability:** Every test maps to a requirement

## Observability

- [ ] **Structured logging:** All logs are structured (key-value), not string concatenation
- [ ] **Log levels:** Appropriate levels (ERROR for failures, INFO for business events)
- [ ] **Correlation IDs:** Present and flowing through the call chain
- [ ] **Tracing:** External calls and key operations have trace spans
- [ ] **Metrics:** Key operations have timing/count/error-rate metrics
- [ ] **Health checks:** Service health endpoint exists and tests real dependencies
- [ ] **No sensitive data:** Passwords, tokens, PII never logged

## Performance

- [ ] **Performance budgets:** Defined and met
- [ ] **No N+1 queries:** Data access is batched
- [ ] **Independent operations parallelized:** Not serialized unnecessarily
- [ ] **Resources disposed:** Connections, streams, handles closed properly
- [ ] **Appropriate algorithms:** No O(n^2) when better alternatives exist

## Architecture

- [ ] **Follows existing patterns:** Consistent with the codebase
- [ ] **Clean boundaries:** Components have well-defined interfaces
- [ ] **Dependencies flow correctly:** No circular dependencies
- [ ] **ADRs documented:** Design decisions captured in ADRs

## Documentation

- [ ] **Feature spec updated:** Reflects final implementation
- [ ] **Test plan updated:** Actual coverage numbers included
- [ ] **ADRs current:** Any implementation deviations documented
- [ ] **API contracts documented:** If new endpoints or interfaces added
