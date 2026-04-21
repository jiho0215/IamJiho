# Result Pattern

All operations that can fail return a uniform Result type. No exceptions for control flow.

## Principle

Every function that can fail returns a Result containing either a success value or a structured error. The caller explicitly handles both cases. This eliminates hidden control flow, makes error handling visible, and ensures errors are never silently ignored.

## The Pattern (Pseudocode)

```
Result<T> = Success<T> | Failure

Success<T> {
  ok: true
  value: T
}

Failure {
  ok: false
  error: {
    code: string          // Machine-readable error code (e.g., "NOT_FOUND")
    message: string       // Human-readable description
    category: ErrorCategory  // "user" | "system" | "external"
    context: object       // Additional context (optional)
  }
}
```

## Usage

```
// Returning success
return Result.ok(user)

// Returning failure
return Result.fail({
  code: "USER_NOT_FOUND",
  message: "No user found with the given ID",
  category: "user"
})

// Handling the result
result = getUserById(id)
if (!result.ok) {
  // Handle error — the type system forces you to check
  log.info("User not found", { error: result.error, userId: id })
  return Result.fail(result.error)  // Propagate
}
user = result.value  // Safe to access
```

## Rules

1. **All fallible operations return Result<T>** — database queries, API calls, validation, business logic
2. **No exceptions for flow control** — exceptions are for truly exceptional situations (out of memory, stack overflow), not for expected error cases like "user not found"
3. **Errors propagate explicitly** — if a function calls another function that returns Result, it must handle the failure case explicitly (return it, transform it, or recover from it)
4. **Error codes are machine-readable** — use SCREAMING_SNAKE_CASE (e.g., `INVALID_INPUT`, `NOT_FOUND`, `RATE_LIMITED`)
5. **Error messages are human-readable** — clear enough for a developer to understand the problem without looking at source code
6. **Error categories classify handling behavior** — see ERROR_HANDLING.md for how each category is handled

## Language-Specific Implementations

During `/implement init`, the Result type is generated for the project's language:

- **TypeScript:** Discriminated union with `type Result<T> = { ok: true; value: T } | { ok: false; error: AppError }`
- **C#:** `public record Result<T>` with static factory methods `Result<T>.Ok(value)` and `Result<T>.Fail(error)`
- **Go:** Return tuple `(T, error)` with a structured error type
- **Python:** `@dataclass Result` or a library like `returns`
- **Rust:** Native `Result<T, E>` (already built-in)

## Anti-Patterns

- Returning null/undefined instead of a Result with a failure
- Throwing exceptions for expected failure cases
- Silently swallowing errors with empty catch blocks
- Using boolean return values without error context
- Mixing Result and exception patterns in the same codebase
