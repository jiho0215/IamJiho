# Plan

## Stage A — Gates

### P-0-3 · Add health endpoint
- stage: A
- kind: code
- state: ready
- area: acme-api — `src/Health.cs`
- depends: —
- decisions: D-1
- ticket: —

Expose a health endpoint.

### P-0-4 · Serve Swagger only outside production
- stage: A
- kind: code
- state: ready
- area: acme-api — `src/Program.cs`
- depends: P-0-3
- decisions: D-8, RL-7
- ticket: —

Disable Swagger in production builds.

### P-0-5 · Show build number in settings
- stage: A
- kind: code
- state: ready
- area: acme-mobile — `src/Settings.tsx`
- depends: P-0-4
- decisions: —
- ticket: —

Render the build number.
