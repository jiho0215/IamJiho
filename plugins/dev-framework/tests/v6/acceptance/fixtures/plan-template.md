# Plan

## Stage A — Acceptance

### P-{{RUN}}-1 · Add a ping endpoint
- stage: A
- kind: code
- state: ready
- area: api — `src/ping.js`
- depends: —
- decisions: D-1
- ticket: —

Expose a ping endpoint that answers ok.

### P-{{RUN}}-2 · Add a version endpoint
- stage: A
- kind: code
- state: ready
- area: api — `src/version.js`
- depends: —
- decisions: D-2
- ticket: —

Expose a version endpoint.

### P-{{RUN}}-3 · Log every request
- stage: A
- kind: code
- state: ready
- area: api — `src/log.js`
- depends: P-{{RUN}}-1
- decisions: —
- ticket: —

Write one log line per request.
