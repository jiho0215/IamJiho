'use strict';
// Issue body rendering for a plan item, and the Cites: line reader (issue bodies and PR bodies).
const { PlanError } = require('./plan');

const NOTE = 'Acks are issue comments of the form `ack <issue#> <plan-sha>: <impact>`.';

function renderBody(item, { hashes, issueNumbers, planSha, config }) {
  const planPath = (config && config.plan && config.plan.path) || 'docs/plan';
  const own = hashes.get(item.id);
  if (!own) throw new PlanError(`${item.id}: no plan hash`);
  const cites = [`${item.id}@${own}`];
  for (const d of item.decisions) {
    const h = hashes.get(d);
    if (!h) throw new PlanError(`${item.id}: decision ${d} not found in DECISIONS.md / RULINGS.md`);
    cites.push(`${d}@${h}`);
  }
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

module.exports = { renderBody, parseCites };
