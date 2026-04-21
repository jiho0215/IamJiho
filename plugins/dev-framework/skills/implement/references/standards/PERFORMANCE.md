# Performance

Define performance budgets per project. Measure before optimizing. No premature optimization, but no lazy algorithms either.

## Performance Budgets

Every project defines budgets during initialization. Common budgets:

| Metric | Typical Budget | Measure With |
|--------|---------------|--------------|
| API response time | < 200ms (p95) | Server-side timing middleware |
| App startup time | < 2 seconds | Profiler / manual timing |
| Page load (web) | < 3 seconds (LCP) | Lighthouse / Web Vitals |
| Memory per request | < 50MB peak | Runtime profiler |
| Bundle size (web) | < 200KB gzipped | Build analyzer |
| Test suite runtime | < 5 minutes | CI timing |

Budgets are defined in the project's CLAUDE.md or a dedicated `PERFORMANCE_BUDGETS.md` and enforced during Phase 6 verification.

## Algorithmic Efficiency

### Do

- Use appropriate data structures (hash maps for lookups, sorted arrays for range queries)
- Process collections incrementally when possible (streams, generators, pagination)
- Parallelize independent operations (concurrent API calls, parallel test execution)
- Cache expensive computations with bounded size and TTL
- Use batch operations for database writes and API calls

### Don't

- Write O(n^2) algorithms when O(n log n) is available
- Load entire datasets into memory when pagination/streaming is possible
- Make sequential API calls that could be parallelized
- Re-compute values that could be cached
- Fetch more data than needed (SELECT * when you need 3 columns)

## N+1 Query Prevention

The most common performance anti-pattern in data-driven applications:

```
// BAD: N+1 queries
users = getUsers()           // 1 query
for user in users:
  orders = getOrders(user.id) // N queries

// GOOD: Batch query
users = getUsers()           // 1 query
orders = getOrdersByUserIds(users.map(u => u.id))  // 1 query
```

## Measurement Before Optimization

1. **Profile first** — don't guess where bottlenecks are
2. **Measure the baseline** — know where you start before changing anything
3. **Change one thing at a time** — isolate the impact of each optimization
4. **Verify improvement** — measure again to confirm the optimization worked
5. **Document the trade-off** — if optimization adds complexity, explain why it's worth it

## Rules

1. **Define performance budgets** during project initialization
2. **Measure before optimizing** — intuition about bottlenecks is often wrong
3. **No N+1 queries** — batch all data access
4. **Parallelize independent operations** — don't serialize what can be concurrent
5. **Use appropriate data structures** — the right structure makes the right algorithm obvious
6. **Dispose resources** — close connections, streams, and handles when done
