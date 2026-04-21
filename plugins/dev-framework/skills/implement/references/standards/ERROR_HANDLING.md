# Error Handling

Errors are categorized, handled consistently, and preserve context through the call chain.

## Error Categories

Every error falls into one of three categories. Each category has defined handling behavior.

### User Errors
Caused by invalid user input or actions. The user can fix these.

- **HTTP status:** 400 (Bad Request), 404 (Not Found), 409 (Conflict), 422 (Unprocessable)
- **Logging:** INFO level (expected behavior)
- **User message:** Friendly, actionable ("Please provide a valid email address")
- **Examples:** Invalid form input, resource not found, duplicate entry

### System Errors
Caused by bugs, misconfigurations, or unexpected failures. The developer must fix these.

- **HTTP status:** 500 (Internal Server Error)
- **Logging:** ERROR level with full stack trace
- **User message:** Generic ("Something went wrong. Please try again later.")
- **Alert:** Trigger alerting/notification
- **Examples:** Null reference, assertion failure, missing configuration

### External Errors
Caused by third-party services or infrastructure the system depends on.

- **HTTP status:** 502 (Bad Gateway), 503 (Service Unavailable), 504 (Gateway Timeout)
- **Logging:** WARN level (not our bug, but needs attention)
- **User message:** Descriptive but not leaking internals ("Payment service is temporarily unavailable")
- **Retry:** May be retried with exponential backoff
- **Examples:** API timeout, database connection failure, DNS resolution failure

## Error Context Preservation

When an error propagates through layers, context must be preserved:

```
// Each layer adds its own context without losing the original
Layer 3 (Controller): "Failed to process order #123"
  └─ Layer 2 (Service): "Failed to charge payment for $50.00"
    └─ Layer 1 (Gateway): "Stripe API returned 503: service unavailable"
```

## Rules

1. **Categorize every error** — never throw a generic "Error" without categorization
2. **Preserve context** — wrap errors with additional context as they propagate up
3. **User messages are friendly** — never expose stack traces, SQL queries, or internal paths
4. **System errors are detailed** — include everything a developer needs to diagnose
5. **External errors are retryable** — implement retry logic with exponential backoff and circuit breakers
6. **Log at the right level** — don't ERROR on user mistakes, don't INFO on system failures
7. **No silent swallowing** — every catch block must either handle, re-throw, or log the error

## Anti-Patterns

- Catching all exceptions with empty catch blocks
- Logging the same error at multiple layers (log once at the boundary)
- Exposing internal details in user-facing error messages
- Using string matching on error messages instead of error codes
- Retrying non-retryable errors (user input errors won't fix themselves)
