# Testing

## Overview

`my-api` uses a three-tier testing strategy:

| Tier | Framework | Location | Purpose |
|------|-----------|----------|---------|
| Unit | Jest | `test/unit/` | Fast, isolated tests of individual modules (e.g. `user.service.ts`). No I/O; external services (Stripe, Twilio) are mocked. |
| Integration | Jest + Testcontainers | `test/integration/` | Exercise services against a real Postgres instance spun up on-demand via `testcontainers` (e.g. `order.service.ts`). |
| E2E | Playwright | `test/e2e/` | Full user-flow tests against a running stack (e.g. `checkout.e2e.spec.ts`). |

Supporting infrastructure for local runs (Postgres 15, Redis 7) is defined in `docker-compose.test.yml`.

Third-party production dependencies — **Stripe** (payments) and **Twilio** (SMS) — are never called from tests. Use the official sandboxes/mocks:

- Stripe: mock the SDK in unit/integration tests; use Stripe test keys + test cards in E2E.
- Twilio: mock the SDK in unit/integration tests; use the Twilio test credentials (magic numbers) in E2E.

## Running locally

### Prerequisites

- Node.js (see `.nvmrc` / `package.json` `engines`)
- Docker (for integration tests via Testcontainers and for the E2E compose stack)

### Install

```bash
npm install
npx playwright install   # one-time: download Playwright browsers
```

### Commands

```bash
# Unit + integration (everything except E2E)
npm test

# Unit only
npm test -- test/unit

# Integration only (requires Docker running)
npm test -- test/integration

# E2E (Playwright)
npm run test:e2e
```

### Supporting services

Integration tests manage their own Postgres container via `testcontainers` — no manual setup required.

For E2E, bring up the shared stack:

```bash
docker compose -f docker-compose.test.yml up -d
npm run test:e2e
docker compose -f docker-compose.test.yml down
```

### Environment variables

E2E runs expect sandbox credentials for third-party services. Typical `.env.test`:

```
STRIPE_SECRET_KEY=sk_test_...
TWILIO_ACCOUNT_SID=AC_test_...
TWILIO_AUTH_TOKEN=...
DATABASE_URL=postgres://postgres:postgres@localhost:5432/my_api_test
REDIS_URL=redis://localhost:6379
```

Never commit real keys; `.env.test` is gitignored.

## CI

Two GitHub Actions workflows live under `.github/workflows/`:

| Workflow | Trigger | Runs |
|----------|---------|------|
| `test.yml` | `push` | Jest suite, filtered to exclude E2E (`test/unit/` + `test/integration/`). |
| `e2e.yml` | `pull_request` | Playwright E2E suite (`test/e2e/`). |

Integration tests use Testcontainers inside CI; the runner must have Docker available (GitHub-hosted Ubuntu runners do). The E2E workflow additionally brings up `docker-compose.test.yml` before invoking Playwright.

A PR must pass both workflows before merge.

## Writing new tests

### Choose the right tier

- **Pure logic, no I/O** -> unit test in `test/unit/<module>.test.ts`.
- **Touches the database or cache** -> integration test in `test/integration/<module>.integration.test.ts` using Testcontainers.
- **Whole-system user flow across HTTP** -> Playwright spec in `test/e2e/<flow>.e2e.spec.ts`.

### Naming conventions

| Tier | Pattern |
|------|---------|
| Unit | `*.test.ts` |
| Integration | `*.integration.test.ts` |
| E2E | `*.e2e.spec.ts` |

The Jest config on `push` (`test.yml`) filters out `*.e2e.spec.ts`, so the pattern matters.

### Guidelines

- One behavior per test; use `describe` blocks per module/feature.
- **Never hit real Stripe or Twilio.** Mock the SDKs in unit/integration; use sandbox credentials only in E2E.
- Integration tests should rely on Testcontainers, not a developer-managed database — this keeps CI and local behavior identical.
- Prefer deterministic fixtures over randomized data; if you need randomness, seed it.
- Clean up resources (containers, DB rows, Stripe customers) in `afterEach`/`afterAll`.
- Keep E2E tests hermetic: each spec should be runnable in isolation and in any order.

### Example layout

```
test/
├── unit/
│   └── user.service.test.ts
├── integration/
│   └── order.integration.test.ts
└── e2e/
    └── checkout.e2e.spec.ts
```

## Coverage

Generate a coverage report locally:

```bash
npm test -- --coverage
```

Jest writes HTML + lcov output to `coverage/`. Open `coverage/lcov-report/index.html` in a browser to inspect per-file coverage.

Coverage is collected from Jest (unit + integration) only; Playwright E2E runs are not included in the coverage number.

## Known Gaps

None at this time.
