# Dependency Policy — Mock vs Docker

The rule for how external dependencies are handled in tests. Applied in Phase 3 (Design).

## The Rule

| Dependency class | Strategy |
|---|---|
| **3rd-party** (Stripe, Plaid, Twilio, OpenAI, Anthropic, SendGrid, Auth0, Google, Apple, SMS providers, payment gateways, any vendor you don't operate) | **Mock** |
| **Internal** (our own other APIs, our DB, our Redis, our message queue, our auth service, any runtime we operate) | **Docker** |

**Never invert.** Mocking our own services creates false confidence — the mock drifts from the real service and hides contract breaks. Hitting real 3rd-party services in CI creates flakes, leaks secrets, runs up bills, and tangles us in vendor rate limits.

## 3rd-Party → Mock

Acceptable mocking mechanisms, in preference order:

1. **Recorded fixtures** — capture a real response during development, replay in tests. Best for stable contract surfaces. Tools: `vcr.py`, `nock`, `node-replay`, `WireMock recording`, `WireMock.NET`, custom `HttpMessageHandler` with fixture replay.
2. **Fake provider** — a hand-written implementation of the 3rd-party's contract, wired via DI substitution (`FakePlaidGateway`, `FakeAICoreProvider` patterns). Best when the contract is small and stable.
3. **Framework mocks** (`Moq`, `Mockito`, `unittest.mock`, `sinon`) — last resort. Ties tests to the mock's shape rather than the real contract. Use only for narrow assertion-style checks, never for whole-flow simulation.

Required properties of 3rd-party mocks:

- **Deterministic** — same request → same response, no random fields.
- **Contract-pinned** — schema version recorded. When the vendor updates their API, the fixture breaks, forcing a review.
- **Documented in TESTING.md** — the mock provider name + location is in the Overview section.

## Internal → Docker

Acceptable Docker mechanisms, in preference order:

1. **Shared compose stack** (`docker-compose.test.yml`, `docker-compose.e2e-api.yml`, etc.) — used by integration and E2E tiers. Services brought up once per test run.
2. **Testcontainers** — per-test or per-class container via `Testcontainers.MsSql`, `testcontainers-python`, `testcontainers-go`. Best isolation, slower.
3. **CI-managed service containers** (GitHub Actions `services:`, GitLab services) — same image, different orchestrator.

Required properties of internal Docker setups:

- **Image-pinned** — specific tag, never `latest`. When the image updates, the pin change is an explicit PR.
- **Ephemeral state** — volume cleanup between runs OR per-test transaction rollback.
- **Port-stable** — known ports documented in TESTING.md Running Locally.
- **Health-gated** — tests wait for `healthcheck` before first call.

## Blackbox E2E rule (corollary)

For the E2E tier, the Docker rule becomes stricter: internal services used by E2E MUST be referenced by **image tag only**, never `build: context:`. The image is built upstream (separate CI step or local script) and the E2E suite consumes the artifact. This enforces the blackbox boundary — see [BLACKBOX_BOUNDARY.md](BLACKBOX_BOUNDARY.md).

```yaml
# GOOD — E2E compose references the image
services:
  api:
    image: buckit-api:${API_IMAGE_TAG:-e2e}

# BAD — E2E compose builds from source, creating coupling
services:
  api:
    build: ../buckitApi
```

## Boundary cases

### "But this internal service is flaky, can I mock it?"

No. Fix the flake. The whole reason we use Docker for internal services is to catch contract breaks early. Mocking a flaky internal service is trading a short-term green build for a long-term production outage.

If the service is genuinely unstable (e.g., a legacy system pending replacement), quarantine the test with the [HYGIENE.md](HYGIENE.md) skip contract — tracking link + exit criterion.

### "But this 3rd-party has a sandbox mode, can I hit it in integration?"

No (in CI). A sandbox is still an external service: it has rate limits, requires secret rotation, produces flakes during vendor maintenance windows, and costs money if abused. Use a recorded fixture of the sandbox response instead.

Exception: a dedicated "vendor-smoke" CI job that runs weekly/nightly against the real sandbox to catch contract drift. This job is **separate** from the main test run and must never gate a PR merge.

### "But we don't own this service but also don't pay for it (e.g., an internal org service run by another team)."

Treat it as internal — use Docker (they should publish an image) OR request a contract fixture from that team. Do not mock it unilaterally; that hides cross-team contract breaks.

### "What about databases seeded with specific data for a test?"

That's an integration concern. Docker-up the real DB. Seed via the test's `Arrange` step (transaction-scoped or fixture loader). Roll back in `Dispose`. Per-test isolation, no shared mutable state across tests.

## Enforcement

Phase 3 (Design) produces `design.json` with `deps: [{name, strategy}]` per test. Phase 4 (Build) rejects any test where a DB import / `HttpClient` to an internal host / Redis client instantiation is present without a corresponding Docker entry. Phase 4 rejects any test where a known 3rd-party host (domain lookup against a configurable allowlist in `~/.claude/autodev/config.json` under `.pipeline.thirdPartyDomains`) is called without a mock wrapper.
