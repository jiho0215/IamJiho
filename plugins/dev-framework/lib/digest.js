'use strict';
// SessionStart digest. Pure: digest({ planText, startHereText, sha, branch, version, stale }) -> string (<= MAX chars).
const { parsePlan } = require('./plan');
const { parseLeaseLine } = require('./lease');

const MAX = 10000;
const FOCUS_MAX = 2000;

// Plan ITEMS only. parsePlan treats every `### <ID> · <title>` heading as an item and demands its fields, so
// decision entries (`### D-3 · ...`) are removed before parsing; an item is a block whose ID starts with `P-`.
function itemsOf(planText) {
  const kept = [];
  let keep = true;
  for (const line of String(planText || '').replace(/\r/g, '').split('\n')) {
    if (/^### /.test(line)) keep = /^### P-/.test(line) || !/^### [A-Z]+(?:-[a-z0-9]+)*-[0-9]+ · /.test(line);
    else if (/^## /.test(line)) keep = true;
    if (keep) kept.push(line);
  }
  return parsePlan(kept.join('\n')).filter((it) => it.id.startsWith('P-'));
}

function focusOf(startHereText) {
  const lines = String(startHereText || '').replace(/\r/g, '').split('\n');
  const at = lines.findIndex((l) => /^## Focus\s*$/.test(l));
  if (at < 0) return ['focus: none'];
  const body = [];
  for (const l of lines.slice(at + 1)) {
    if (/^#{1,6} /.test(l)) break;
    body.push(l);
  }
  while (body.length && !body[body.length - 1].trim()) body.pop();
  while (body.length && !body[0].trim()) body.shift();
  const out = [];
  let used = 0;
  for (const l of body) {
    if (used + l.length + 1 > FOCUS_MAX) break;
    out.push(l);
    used += l.length + 1;
  }
  return ['## Focus', ...out];
}

function digest({ planText, startHereText, sha, branch, version, stale }) {
  const head = [`${stale ? 'STALE (fetch failed) · ' : ''}dev-framework ${version} · plan origin/${branch}@${String(sha).slice(0, 12)}`];
  const first = String(startHereText || '').replace(/\r/g, '').split('\n')[0];
  head.push(parseLeaseLine(first) ? first : 'lease: none');
  head.push(...focusOf(startHereText));
  head.push('open items:');
  // An item with no `state:` counts as open (parsePlan requires one, so this only matters for hand-built input).
  const items = itemsOf(planText)
    .filter((it) => it.fields.state !== 'done')
    .map((it) => `${it.id} · ${it.title} [${it.fields.state}]`);
  for (let k = items.length; k >= 0; k--) {
    const lines = [...head, ...items.slice(0, k)];
    if (k < items.length) lines.push(`… ${items.length - k} more open items; read the plan through the orchestrate skill`);
    const text = lines.join('\n');
    if (text.length <= MAX) return text;
  }
  return head.join('\n').slice(0, MAX);
}

module.exports = { digest, MAX };

// CLI for the hook: node digest.js <plan-file> <start-here-file> <sha> <branch> <version> <stale:0|1>
if (require.main === module) {
  const fs = require('node:fs');
  const [planF, startF, sha, branch, version, stale] = process.argv.slice(2);
  process.stdout.write(digest({
    planText: fs.readFileSync(planF, 'utf8'), startHereText: fs.readFileSync(startF, 'utf8'),
    sha, branch, version, stale: stale === '1',
  }) + '\n');
}
