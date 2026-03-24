# Code Quality

Clean, consistent, maintainable code. Small files. Single responsibility. Descriptive naming.

## File Size

- **Maximum:** 200 lines per file (prefer smaller)
- **Target:** 50-150 lines
- **If a file exceeds 200 lines:** Split by responsibility — each file should do one thing

## Function Size

- **Maximum:** 30 lines per function (prefer smaller)
- **Target:** 5-20 lines
- **If a function exceeds 30 lines:** Extract helper functions with descriptive names

## Single Responsibility

- Each file has one purpose (one component, one service, one utility)
- Each function does one thing (one operation, one transformation, one validation)
- Each module has one reason to change

**Test:** Can you describe what a file/function does in one sentence without using "and"? If not, it does too much.

## Naming Conventions

- **Descriptive:** Names explain what the thing does, not how
- **No abbreviations:** `getUserById`, not `getUsrById`
- **Consistent casing:** Follow the project's convention (camelCase, snake_case, PascalCase)
- **Booleans:** Start with `is`, `has`, `can`, `should` (e.g., `isValid`, `hasPermission`)
- **Functions:** Start with a verb (e.g., `createUser`, `validateInput`, `fetchTransactions`)
- **Constants:** SCREAMING_SNAKE_CASE (e.g., `MAX_RETRY_COUNT`, `DEFAULT_TIMEOUT_MS`)

## Directory Structure

Organize by feature, not by type:

```
// GOOD: Feature-based
src/
├── auth/
│   ├── auth.service.ts
│   ├── auth.controller.ts
│   ├── auth.types.ts
│   └── auth.test.ts
├── orders/
│   ├── orders.service.ts
│   ├── orders.controller.ts
│   └── orders.test.ts

// ACCEPTABLE: Type-based (when features are small)
src/
├── services/
├── controllers/
├── types/
└── tests/
```

## Test Coverage

- **Metric:** Branch coverage >= 90%
- **All 4 test types mandatory:** Unit, Integration, Smoke, E2E
- **Test file co-location:** Test files live next to the code they test

## Code Review Checklist

Before considering code complete, verify:

- [ ] All functions follow early exit pattern
- [ ] All fallible operations return Result<T>
- [ ] No file exceeds 200 lines
- [ ] No function exceeds 30 lines
- [ ] All names are descriptive (no abbreviations)
- [ ] Error handling follows categorization (user/system/external)
- [ ] Observability is implemented (logging, tracing, metrics)
- [ ] Performance budgets are not violated
- [ ] Tests cover all requirements (traceability matrix)
- [ ] Branch coverage >= 90%
- [ ] Documentation is updated
