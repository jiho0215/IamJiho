'use strict';
// Issue body rendering for a plan item, and the Cites: line reader (issue bodies and PR bodies).
const { PlanError } = require('./plan');

const NOTE = 'Acks are issue comments of the form `ack <issue#> <plan-sha>: <impact>`.';

// keepCites: Map(id -> hash) already on an EXISTING issue. Those hashes are written back as-is, and an ID the issue
// does not cite stays out of the line: it never silently takes the current hash (that would clear needs-ack after
// someone deleted it on GitHub). Only --refresh-cites (keepCites undefined) renders every ID at the current plan.
function renderBody(item, { hashes, issueNumbers, planSha, config, keepCites }) {
  const planPath = (config && config.plan && config.plan.path) || 'docs/plan';
  if (!hashes.get(item.id)) throw new PlanError(`${item.id}: no plan hash`);
  for (const d of item.decisions) {
    if (!hashes.get(d)) throw new PlanError(`${item.id}: decision ${d} not found in DECISIONS.md / RULINGS.md`);
  }
  const ids = [item.id, ...item.decisions];
  const cites = keepCites
    ? ids.filter((id) => keepCites.has(id)).map((id) => `${id}@${keepCites.get(id)}`)
    : ids.map((id) => `${id}@${hashes.get(id)}`);
  const nums = issueNumbers || new Map();
  const deps = item.deps.length ? item.deps.map((d) => (nums.get(d) ? `${d} (#${nums.get(d)})` : d)).join(', ') : '—';
  const f = item.fields;
  const lines = [
    `> Mirror of \`${planPath}/PLAN.md\` item **${item.id}**, plan at \`${String(planSha).slice(0, 7)}\`. The repo is the source of truth; an edit made here is not the plan.`,
    '',
    `## ${item.id} · ${item.title}`,
    '',
  ];
  if (item.body) lines.push(item.body, '');
  lines.push(
    `- **Stage:** ${f.stage}`,
    `- **Kind:** ${f.kind}`,
    `- **State:** ${f.state}`,
    `- **Cites:** ${cites.join(', ')}`,
    `- **Area:** ${f.area}`,
    `- **Depends:** ${deps}`,
    '',
    '## Ack log',
    '',
    NOTE,
  );
  return lines.join('\n') + '\n';
}

// Reads the "Cites:" line of any body: Map(id -> hash12).
function parseCites(text) {
  const map = new Map();
  for (const line of String(text || '').replace(/\r/g, '').split('\n')) {
    const m = /^\s*(?:[-*]\s*)?\*{0,2}Cites:\*{0,2}\s*(.*)$/.exec(line);
    if (!m) continue;
    for (const c of m[1].matchAll(/([A-Za-z][A-Za-z0-9-]*)@([0-9a-f]{12})/g)) map.set(c[1], c[2]);
  }
  return map;
}

// Strict reader for the merge gate: every comma-separated entry of a Cites line must be ID@12hex.
// Returns { cites: Map, malformed: [raw entries], conflicts: [{ id, hashes }] } so a damaged entry cannot be
// dropped unchecked, and an ID cited twice with different hashes is reported instead of the last one winning.
function parseCitesStrict(text) {
  const cites = new Map();
  const malformed = [];
  const seen = new Map(); // id -> Set of hashes
  for (const line of String(text || '').replace(/\r/g, '').split('\n')) {
    const m = /^\s*(?:[-*]\s*)?\*{0,2}Cites:\*{0,2}\s*(.*)$/.exec(line);
    if (!m) continue;
    for (const raw of m[1].split(',').map((s) => s.trim()).filter(Boolean)) {
      const e = /^([A-Za-z][A-Za-z0-9-]*)@([0-9a-f]{12})$/.exec(raw);
      if (!e) { malformed.push(raw); continue; }
      if (!seen.has(e[1])) seen.set(e[1], new Set());
      seen.get(e[1]).add(e[2]);
      cites.set(e[1], e[2]);
    }
  }
  const conflicts = [...seen].filter(([, hs]) => hs.size > 1).map(([id, hs]) => ({ id, hashes: [...hs] }));
  return { cites, malformed, conflicts };
}

module.exports = { renderBody, parseCites, parseCitesStrict };
