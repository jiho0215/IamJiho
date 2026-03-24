# Observability

Every operation must be traceable. Structured logging with correlation IDs. Metrics for key operations. Health checks.

## The Three Pillars

### 1. Logging

**Structured logging only.** Every log entry is a structured object (key-value pairs), not a concatenated string.

```
// GOOD: Structured
log.info("Order processed", {
  orderId: "ORD-123",
  userId: "USR-456",
  total: 50.00,
  itemCount: 3,
  durationMs: 142
})

// BAD: String concatenation
log.info("Processed order ORD-123 for user USR-456, total $50.00, 3 items in 142ms")
```

**Log levels:**
- **ERROR:** System failures that need immediate attention
- **WARN:** Degraded operation (external service slow, fallback used)
- **INFO:** Business events (order created, user logged in, payment processed)
- **DEBUG:** Development-time details (not in production)

**Sensitive data:** Never log passwords, tokens, PII, credit card numbers, or API keys. If you must reference them, use partial masking (e.g., `email: "j***@example.com"`).

### 2. Tracing

Every request gets a **correlation ID** that flows through all components:

- Generated at the entry point (API gateway, message consumer)
- Passed in headers to downstream services
- Included in every log entry
- Stored in trace spans

**Trace spans** wrap key operations:
- Incoming HTTP requests
- Outgoing HTTP calls
- Database queries
- Message queue operations
- Significant business operations

### 3. Metrics

Capture quantitative data about system behavior:

- **Request rate** — requests per second by endpoint
- **Error rate** — errors per second by type
- **Latency** — response time distribution (p50, p95, p99)
- **Saturation** — resource utilization (CPU, memory, connections)
- **Business metrics** — domain-specific counts (orders processed, users registered)

## Health Checks

Every service exposes a health check endpoint that returns:

```
{
  "status": "healthy" | "degraded" | "unhealthy",
  "checks": {
    "database": { "status": "healthy", "responseTimeMs": 5 },
    "cache": { "status": "healthy", "responseTimeMs": 2 },
    "externalApi": { "status": "degraded", "responseTimeMs": 1500 }
  }
}
```

## Rules

1. **Significant public functions log their entry and/or exit** — specifically: external calls, business operations, error paths, and operations with side effects. Pure utility functions, simple getters, and trivial transformations do not require entry/exit logging.
2. **Every error is logged with full context** (correlation ID, operation, inputs)
3. **Every external call has a trace span** with timing
4. **Every service has a health check** that tests real dependencies
5. **Correlation IDs flow through the entire call chain** — no breaks
6. **Metrics are collected for key operations** — at minimum: rate, errors, latency

## Performance Impact

Observability should not significantly impact performance:
- Use async/buffered log writers
- Sample traces at high throughput (e.g., 10% of requests)
- Aggregate metrics in-process, not per-event
