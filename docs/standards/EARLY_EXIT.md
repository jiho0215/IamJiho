# Early Exit

Functions validate preconditions first and return immediately on failure. The happy path is never nested inside conditionals.

## Principle

Guard clauses at the top of a function check preconditions and exit early on failure. The main logic runs at the base indentation level, not inside nested if/else blocks. This reduces cognitive load — the reader knows that once past the guards, all preconditions are met.

## The Pattern (Pseudocode)

```
// GOOD: Early exit with guard clauses
function processOrder(order) {
  if (!order) return Result.fail("ORDER_REQUIRED", "Order is required")
  if (!order.items.length) return Result.fail("EMPTY_ORDER", "Order has no items")
  if (order.total <= 0) return Result.fail("INVALID_TOTAL", "Order total must be positive")

  // Happy path — all preconditions met, no nesting
  validated = validateInventory(order.items)
  if (!validated.isSuccess) return validated

  charged = chargePayment(order.total)
  if (!charged.isSuccess) return charged

  return Result.ok(createConfirmation(order))
}

// BAD: Nested conditionals
function processOrder(order) {
  if (order) {
    if (order.items.length > 0) {
      if (order.total > 0) {
        // Happy path buried in 3 levels of nesting
        ...
      } else {
        return error
      }
    } else {
      return error
    }
  } else {
    return error
  }
}
```

## Rules

1. **Guard clauses first** — validate all preconditions at the top of the function
2. **Return immediately on failure** — don't set a variable and check it later
3. **One level of indentation for happy path** — if your happy path is indented more than once, refactor
4. **Chain Result checks linearly** — when calling multiple fallible operations, check each result and return early on failure
5. **No else after return** — if the guard returns, the else is implicit

## Benefits

- **Readability:** The reader sees all failure cases upfront, then reads the happy path without interruption
- **Reduced nesting:** Functions stay flat and linear
- **Easier testing:** Each guard clause is an independently testable condition
- **Fewer bugs:** No chance of executing happy-path code when a precondition fails

## Anti-Patterns

- Nested if/else pyramids (the "arrow" anti-pattern)
- Setting a boolean flag and checking it later instead of returning early
- Using try/catch for validation instead of explicit guard clauses
- Deep nesting to handle optional values (use optional chaining or early return)
