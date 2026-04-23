# PaymentService Integration Test — Dependency Strategy

Applies the testbuilder `DEPENDENCY_POLICY.md` rule: **3rd-party → mock; internal services we operate → Docker. Never invert.**

## Decision Table

| # | Dependency | Class | Strategy | Specific Technique | Why |
|---|---|---|---|---|---|
| 1 | `UserService` (`buckit-user-api:latest`) | Internal (we operate it) | **Docker** | Shared compose stack referencing `image: buckit-user-api:<pinned-tag>` (not `latest`); health-gated before tests run | Mocking our own service would let its contract drift from reality and hide cross-service breaks. Docker runs the real binary so contract changes surface in CI. |
| 2 | Postgres (our DB) | Internal (our runtime) | **Docker** | Shared compose `postgres:<pinned-tag>` for the integration suite; per-test isolation via transaction rollback or truncation in `Dispose`; seed via test `Arrange` | Databases seeded for specific tests are an integration concern per policy — Docker-up the real engine and seed per test. Catches real SQL/migration/constraint issues. |
| 3 | Stripe | 3rd-party vendor | **Mock** | Recorded fixtures (e.g. `WireMock.NET` replay of real Stripe responses) fronted by the payment gateway interface; schema/API-version pinned | Hitting real (or even sandbox) Stripe in CI means rate limits, secret rotation, billing risk, and vendor-maintenance flakes. Recorded fixtures are deterministic and break loudly when Stripe's contract changes. |
| 4 | SendGrid | 3rd-party vendor | **Mock** | Fake provider (`FakeEmailGateway` / `FakeSendGridClient`) DI-swapped in integration config; captures sent messages for assertion | Email contract is small and stable, so a hand-written fake is cleaner than recorded HTTP. Lets tests assert "email X was queued to recipient Y" without ever touching the network. |
| 5 | `AuditLogService` (internal) | Internal (we operate it) | **Docker** | Shared compose stack with the real audit-log service image (pinned tag); health-gated | Same rule as UserService — never mock our own service. If PaymentService's audit-emission contract breaks, the integration run must catch it, not a stub that always says "ok". |
| 6 | OpenAI (fraud scoring) | 3rd-party vendor | **Mock** | Recorded fixtures via an `IFraudScoreProvider` interface with a `RecordedOpenAIProvider` replaying captured responses; deterministic scores keyed by request fingerprint | LLM calls are non-deterministic, expensive, and rate-limited — unusable in CI. Recorded fixtures give reproducible scores; a nightly "vendor-smoke" job can hit real OpenAI separately to detect contract drift without gating PRs. |

## Justification (Policy Mapping)

**Why the split is non-negotiable:**

- *Mocking internal services creates false confidence.* The mock drifts from the real `UserService` / `AuditLogService`, so the day a breaking change ships, CI stays green and production breaks. Running the real image under Docker is the only way the PaymentService→UserService and PaymentService→AuditLogService contracts get exercised on every run.
- *Hitting real 3rd-party services in CI is a trap.* Stripe/SendGrid/OpenAI all have rate limits, auth-secret rotation, billing exposure, and maintenance windows. Each is a flake source and a leak vector. Recorded fixtures or hand-written fakes are deterministic, free, and fail loudly on contract drift.

**Required properties enforced per dependency:**

- **Docker deps (UserService, Postgres, AuditLogService):** image tag pinned (never `latest` — note: replace the stated `buckit-user-api:latest` with a concrete SHA/version tag in the compose file), ephemeral state (volume wipe or per-test rollback), known stable ports documented in `TESTING.md`, health-gated startup before first call.
- **Mocked deps (Stripe, SendGrid, OpenAI):** deterministic (same input → same output, no random fields), contract-pinned (API/schema version recorded so vendor updates break fixtures loudly), documented in `TESTING.md` Overview (name + location of each fake/fixture set).

**Boundary-case handling per policy:**

- Stripe *has a sandbox* — still mocked in CI. A separate nightly "vendor-smoke" job may hit the real Stripe sandbox to detect contract drift, but it never gates PR merges.
- OpenAI is non-deterministic by nature, reinforcing the fixture approach; drift detection happens out-of-band.
- If `UserService` or `AuditLogService` is flaky, the policy is *fix the flake*, not downgrade to a mock. Genuine instability gets a `[Skip]` with tracking link + exit criterion, not a permanent mock.

**Tier note:** this is the **integration** tier, so whitebox DI swapping for the 3rd-party fakes is allowed. For the E2E tier the same internal services must be referenced by `image:` tag only (never `build: context:`) to preserve the blackbox boundary.
