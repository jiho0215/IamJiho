# PaymentService Integration Test Dependency Strategy

## Guiding principle

For integration tests we want **high fidelity for code we own and can run locally** (real containers) and **deterministic, offline, contract-based fakes for 3rd-party SaaS** we cannot run in Docker. The line is not "internal vs external" — it is "can we run a production-equivalent binary in a container without hitting someone else's network?"

## Decision table

| # | Dependency | Strategy | Specific technique | Why |
|---|------------|----------|--------------------|-----|
| 1 | `UserService` (ours, has `buckit-user-api:latest` image) | **Docker** | Spin the real image via Testcontainers (`.NET` Testcontainers module) or a `docker-compose.test.yml` wired into the xUnit `IAsyncLifetime` fixture. Seed it through its public HTTP API (or a test-only seed endpoint, prod-gated). | We own the image and it already runs in prod that way. Running the real binary exercises real HTTP contracts, auth headers, serialization, and error shapes — catches drift between services. Cheap: it's just another container next to the API. |
| 2 | Postgres (ours) | **Docker** | `Testcontainers.PostgreSql` (`PostgreSqlBuilder`) per test-class fixture. Apply EF Core migrations on startup via `dbContext.Database.MigrateAsync()`. Use Respawn or a per-test transaction rollback for isolation. | DB behavior (constraints, transactions, concurrency, SQL dialect) is not mockable with fidelity. A real Postgres container is fast (<2s warm) and gives true integration coverage. Never mock your own DB in integration tests. |
| 3 | Stripe (3rd-party) | **Mock** | In-process fake implementing `IPaymentGateway` (DI swap, same pattern as `FakePlaidGateway` in this repo). Back it with recorded fixture JSON for common flows (charge succeeded, card declined, 3DS required, idempotency replay, webhook signatures). For a richer option, run `stripe-mock` (Stripe's official OpenAPI-driven mock server) as a sidecar container and point `StripeClient` at it. | Stripe cannot be run in Docker for real; hitting `api.stripe.com` from CI is flaky, rate-limited, requires secrets, and is non-deterministic. A DI fake (or `stripe-mock`) gives deterministic, offline tests. Keep a separate, out-of-band **contract test** against Stripe Sandbox to detect upstream drift. |
| 4 | SendGrid (3rd-party) | **Mock** | In-process fake `IEmailSender` that captures sent messages to an in-memory list the test can assert on. Alternatively run MailHog / `smtp4dev` in Docker if the code path goes through raw SMTP. | Emails are fire-and-forget side effects — the interesting assertion is "we asked to send X to Y," not "SendGrid's SMTP works." No value in hitting the real API; lots of cost (deliverability, quotas, secrets, flakiness). |
| 5 | `AuditLogService` (ours) | **Docker** | Same as UserService — run the real image via Testcontainers/compose. If it writes to its own datastore, include that container too. If it is purely write-only and slow to spin up, a thin HTTP fake (WireMock.Net) that records requests is an acceptable fallback. | Default to the real image for the same reason as UserService: contract fidelity between services we own. Only downgrade to WireMock if boot cost or dependency sprawl makes it unworkable. |
| 6 | OpenAI (3rd-party, fraud scoring) | **Mock** | DI-swapped `IFraudScorer` fake returning deterministic scores keyed off the input (e.g. amount > threshold → high risk). For HTTP-layer coverage, use WireMock.Net with recorded response fixtures. | LLM calls are non-deterministic, paid, rate-limited, and network-dependent — three things integration tests must not be. Determinism is worth more than realism here; test the integration boundary (request shape, response parsing, timeout/error handling) with WireMock, and test business logic with the DI fake. |

## Summary

- **Docker (real binary):** Postgres, UserService, AuditLogService — things we own and can run.
- **Mock (DI fake or WireMock/stripe-mock):** Stripe, SendGrid, OpenAI — 3rd-party SaaS.

## Justification of the split

1. **Own-it vs rent-it is the right axis.** "Internal vs external" is a weaker heuristic — what matters is whether you can run a production-equivalent artifact hermetically. We can for Postgres and our own services; we can't for Stripe/SendGrid/OpenAI.

2. **Fidelity where it pays.** DB semantics and inter-service HTTP contracts are the two places integration bugs actually live. Mocking either hides the bugs the test suite exists to catch. Testcontainers makes real-binary testing cheap enough that there's no reason to fake them.

3. **Determinism where fidelity is impossible.** 3rd-party SaaS calls over the public internet are non-deterministic by construction (latency, rate limits, sandbox resets, model drift). Integration tests must be deterministic and offline-runnable in CI; fakes are the only way to hit both bars.

4. **Contract drift is handled separately.** The risk of mocking 3rd parties is that our fake diverges from reality. Mitigate with a small, **separate** suite of contract tests that run against Stripe Sandbox / OpenAI on a nightly schedule — not inside the main integration test run.

5. **Consistent with this repo's conventions.** `buckitApi` already uses the `FakePlaidGateway` DI-swap pattern for Plaid and Testcontainers-style Docker for the main E2E stack (`buckit-e2e`). This design extends the same pattern: real containers for owned infra, DI fakes for 3rd-party SaaS.

6. **Cost and CI runtime.** Real 3rd-party calls cost money (OpenAI), require live secrets in CI (Stripe/SendGrid), and slow the suite with network latency. Fakes keep the suite free, secret-less, and fast.

## Implementation sketch (xUnit + .NET 8)

```csharp
public class PaymentServiceFixture : IAsyncLifetime
{
    public PostgreSqlContainer Postgres { get; } =
        new PostgreSqlBuilder().WithImage("postgres:16").Build();

    public IContainer UserService { get; } =
        new ContainerBuilder()
            .WithImage("buckit-user-api:latest")
            .WithPortBinding(8080, true)
            .Build();

    public IContainer AuditLog { get; } =
        new ContainerBuilder()
            .WithImage("buckit-audit-api:latest")
            .WithPortBinding(8080, true)
            .Build();

    // DI swaps registered in WebApplicationFactory:
    // services.Replace(ServiceDescriptor.Singleton<IPaymentGateway, FakeStripeGateway>());
    // services.Replace(ServiceDescriptor.Singleton<IEmailSender, CapturingEmailSender>());
    // services.Replace(ServiceDescriptor.Singleton<IFraudScorer, DeterministicFraudScorer>());

    public async Task InitializeAsync()
    {
        await Task.WhenAll(Postgres.StartAsync(), UserService.StartAsync(), AuditLog.StartAsync());
        // run EF migrations, seed users via UserService HTTP, etc.
    }

    public Task DisposeAsync() =>
        Task.WhenAll(Postgres.DisposeAsync().AsTask(),
                     UserService.DisposeAsync().AsTask(),
                     AuditLog.DisposeAsync().AsTask());
}
```
