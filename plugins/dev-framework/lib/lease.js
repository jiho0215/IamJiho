'use strict';
// The orchestrator lease line: line 1 of <plan.path>/START-HERE.md. Same format as bin/lease (Plan 1).
const LEASE_RE = /^orchestrator: ([0-9a-f]{16}) · (.+) · since ([0-9TZ:-]{20})$/;

// -> { token, machine, since } | null
function parseLeaseLine(line) {
  const m = LEASE_RE.exec(String(line === undefined || line === null ? '' : line).replace(/\r/g, ''));
  return m ? { token: m[1], machine: m[2], since: m[3] } : null;
}

module.exports = { parseLeaseLine, LEASE_RE };
