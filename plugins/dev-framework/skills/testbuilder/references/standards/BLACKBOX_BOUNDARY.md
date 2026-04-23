# Blackbox Boundary

Where each test tier physically lives and what it is allowed to import. Applied in Phase 3 (Design) and Section I (Init).

## The Three Tiers

| Tier | Visibility | Allowed to import | Runs against |
|---|---|---|---|
| **Unit** | Whitebox | Source code directly (`ProjectReference` / import of internal modules) | In-process, all deps stubbed |
| **Integration** | Mixed | Source code + test infra helpers | In-process OR Docker-backed real internal services |
| **E2E** | Blackbox | Nothing from source. Only HTTP, CLI, browser, built images | Full built artifact over the wire |

## Why the boundary matters

The tier boundary is a **compile-time firewall**. If an E2E test can `import` or `ProjectReference` source code, developers will (eventually) reach into internals for convenience, and the test stops exercising the real public contract. The "E2E" then becomes an integration test in a trench coat.

Enforcing the boundary in the build system (not just convention) is what makes the blackbox real.

## Physical placement rules

### Unit tier

- Lives next to source OR in a sibling test project (`*.UnitTests`).
- `ProjectReference` / import to source is allowed.
- All external deps (DB, HTTP, file system) stubbed via DI.
- Fast. Milliseconds per test. Full suite in under a minute.

**C# example**: `Buckit.BucketService.UnitTests/` references `Buckit.BucketService/` via `<ProjectReference>`.

### Integration tier

- Lives in `*.IntegrationTests` or `test/integration/`.
- `ProjectReference` / import to source IS allowed (this is still whitebox-adjacent — we are testing our own wiring).
- Real internal services (DB, Redis, queue) via Docker per [DEPENDENCY_POLICY.md](DEPENDENCY_POLICY.md).
- 3rd-party still mocked.
- Moderate speed. Seconds per test. Full suite in a few minutes.

**C# example**: `Buckit.IntegrationTests/` references `Buckit.Database/` + `BuckitApi/` for `WebApplicationFactory` tests.

### E2E tier

- Lives in a **separate repo** or a fenced subtree that forbids source imports.
- **No `ProjectReference`** / import to any source repo.
- Compose files use `image: <name>:<tag>` — **never** `build: context:`.
- A single script (e.g., `build-api-image.sh`) is the ONE point of coupling to source; everything else in the E2E tree reads only the built image.
- Tests drive via HTTP / CLI / browser against the running image.
- Slow. Tens of seconds per scenario. Runs on critical paths, not exhaustive.

**Reference pattern**: the Buckitrek monorepo splits `buckitApi/` (source + unit + integration) from `buckit-e2e/` (E2E + Playwright + Maestro + compose). The boundary is enforced by `buckit-e2e/` having zero `<ProjectReference>` entries pointing at `buckitApi/`.

## Decision tree for placement

For each test case from `gap-analysis.json`:

```
Does the test exercise multiple services/processes over the wire?
├─ Yes → E2E (blackbox). Does the compose need source? → No. Use image tag.
└─ No → Does it need a real DB / Redis / internal service to be meaningful?
        ├─ Yes → Integration. Docker the internal service.
        └─ No → Unit. Stub everything.
```

## Anti-patterns to reject in Phase 3

| Anti-pattern | Fix |
|---|---|
| Unit test with a `testcontainers` / `MsSqlContainer` setup | Promote to Integration tier |
| Integration test with `HttpClient` to `https://api.stripe.com` | Mock the 3rd-party (see DEPENDENCY_POLICY) |
| E2E test that `using Buckit.Domain.Entities;` | Rewrite as HTTP call; entity coupling kills blackbox |
| E2E compose with `build: ../buckitApi` | Replace with `image: buckit-api:${TAG}` + build script upstream |
| Integration test that mocks our own DbContext | Docker the DB; the mock hides EF provider-specific bugs |

## E2E repo split — when to extract

An E2E suite embedded in the source repo is fine early on. Extract to a sibling repo when ANY of:

- The E2E suite grows large enough (200+ tests) that full runs dominate CI time on source changes
- The team wants "green E2E" to block main merges without coupling every commit to a 15-minute run
- The E2E suite needs its own release cadence (e.g., weekly smoke + on-demand vs. per-PR)
- The E2E needs to run against multiple source builds (e.g., main, release/1.x)

Keep the split discipline per DEPENDENCY_POLICY: the extracted repo uses `image:` tags only, never `build: context:`.

## InternalsVisibleTo considerations (C#)

For unit/integration tiers, `[InternalsVisibleTo("*.UnitTests")]` is fine and useful. For E2E, it is inappropriate and should not be added — E2E consuming `internal` types is a blackbox violation waiting to happen. Phase 3 reviewers flag any new `InternalsVisibleTo` that targets an E2E assembly.

## TypeScript / JavaScript parallel

- Unit tier: test files colocated with source (`*.test.ts` next to `*.ts`), or under `__tests__/`.
- Integration tier: `test/integration/*.test.ts`; uses Docker-compose fixtures or testcontainers-node.
- E2E tier: separate package (`app-e2e/`) with no path alias or import into the app's source. Uses Playwright/Cypress against the built app.

## Python parallel

- Unit tier: `tests/unit/` with source in `src/package_name/`.
- Integration tier: `tests/integration/` with `pytest.fixture` scoped Docker-up.
- E2E tier: separate package or repo; uses `requests` / `httpx` / Playwright against the deployed service.
