// Network-free fence for `a9-two-machine.mjs --compare`. Run: node --test acceptance/a9-compare.unit.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'a9-two-machine.mjs');
const row = (machine, round, result, lostAt, startedAt) => JSON.stringify({ round, machine, startedAt, result, lostAt });
// plan[i] = [winner 'A'|'B'|'both', how the loser lost]
function fixture(plan, hostB = 'beta') {
  const A = [], B = [];
  plan.forEach(([winner, lostAt], i) => {
    const k = i + 1, t = 1000000 + k * 30000;
    const wa = winner === 'A' || winner === 'both', wb = winner === 'B' || winner === 'both';
    A.push(row('alpha', k, wa ? 'claimed' : 'lost', wa ? null : lostAt, t));
    B.push(row(hostB, k, wb ? 'claimed' : 'lost', wb ? null : lostAt, t + 120));
  });
  return [A.join('\n'), B.join('\n')];
}
function compare(a, b) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'a9cmp-'));
  try {
    fs.writeFileSync(path.join(d, 'a.jsonl'), a); fs.writeFileSync(path.join(d, 'b.jsonl'), b);
    // no sandbox env on purpose: --compare must not need the network or the sandbox
    const r = spawnSync('node', [SCRIPT, '--compare', path.join(d, 'a.jsonl'), path.join(d, 'b.jsonl')], { encoding: 'utf8', env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot } });
    const lines = r.stdout.trim().split('\n').map((l) => JSON.parse(l));
    return { code: r.status, rounds: lines.slice(0, -1), summary: lines.at(-1), stderr: r.stderr };
  } finally { fs.rmSync(d, { recursive: true, force: true }); }
}

test('all rounds raced at the push -> VERIFIED, with winner and skew per round', () => {
  const r = compare(...fixture([['A', 'push'], ['B', 'push'], ['A', 'push'], ['A', 'push'], ['B', 'push']]));
  assert.equal(r.summary.verdict, 'VERIFIED'); assert.equal(r.code, 0);
  assert.equal(r.summary.raced, 5);
  assert.deepEqual(r.rounds.map((x) => x.winner), ['alpha', 'beta', 'alpha', 'alpha', 'beta']);
  assert.ok(r.rounds.every((x) => x.skewMs === 120 && x.raced === true));
});

test('all losers lost at the precheck -> INCONCLUSIVE (one winner each round, no race proven), skew reported', () => {
  const r = compare(...fixture([['A', 'precheck'], ['A', 'precheck'], ['A', 'precheck'], ['B', 'precheck'], ['A', 'precheck']]));
  assert.equal(r.summary.verdict, 'INCONCLUSIVE'); assert.equal(r.code, 4);
  assert.equal(r.summary.raced, 0); assert.equal(r.summary.maxSkewMs, 120);
});

test('only two raced rounds is still INCONCLUSIVE (threshold is 3)', () => {
  const r = compare(...fixture([['A', 'push'], ['A', 'push'], ['A', 'precheck'], ['A', 'precheck'], ['A', 'precheck']]));
  assert.equal(r.summary.verdict, 'INCONCLUSIVE'); assert.equal(r.summary.raced, 2);
});

test('a round with two winners -> FAILED even when every other round raced', () => {
  const r = compare(...fixture([['A', 'push'], ['both'], ['A', 'push'], ['B', 'push'], ['A', 'push']]));
  assert.equal(r.summary.verdict, 'FAILED'); assert.equal(r.code, 1);
  assert.match(r.summary.reason, /round 2: two winners/);
});

test('identical hostnames in the two files is an error, not a verdict', () => {
  const r = compare(...fixture([['A', 'push'], ['A', 'push'], ['A', 'push']], 'alpha'));
  assert.equal(r.summary.verdict, 'ERROR'); assert.equal(r.code, 2);
  assert.match(r.summary.error, /same hostname/);
});
