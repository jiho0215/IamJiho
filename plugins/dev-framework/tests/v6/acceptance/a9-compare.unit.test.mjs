// Network-free fence for `a9-two-machine.mjs --compare`. Run: node --test acceptance/a9-compare.unit.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'a9-two-machine.mjs');
// One race line, as race() prints it. heldBy = the loser's heldBy.machine (null for a winner).
const row = (machine, round, result, lostAt, startedAt, heldBy) =>
  JSON.stringify({ round, issue: 100 + round, machine, startedAt, result, lostAt, heldBy, branch: `t/${100 + round}-s${round}` });
// plan[i] = [winner 'A'|'B'|'both'|'none', how the loser lost, optional: the machine the loser saw holding the ref]
function fixture(plan, hostB = 'beta') {
  const A = [], B = [];
  plan.forEach(([winner, lostAt, held], i) => {
    const k = i + 1, t = 1000000 + k * 30000;
    const wa = winner === 'A' || winner === 'both', wb = winner === 'B' || winner === 'both';
    A.push(row('alpha', k, wa ? 'claimed' : 'lost', wa ? null : lostAt, t, wa ? null : (held || hostB)));
    B.push(row(hostB, k, wb ? 'claimed' : 'lost', wb ? null : lostAt, t + 120, wb ? null : (held || 'alpha')));
  });
  return [A.join('\n'), B.join('\n')];
}
// Rewrites the fields of one round in one side's lines.
const patch = (text, round, over) => text.split('\n')
  .map((l) => (JSON.parse(l).round === round ? JSON.stringify({ ...JSON.parse(l), ...over }) : l)).join('\n');
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

test('I2: the two files must be about the same attempt: a different issue in one round is ERROR', () => {
  const [a, b] = fixture([['A', 'push'], ['B', 'push'], ['A', 'push']]);
  const r = compare(a, patch(b, 2, { issue: 999 }));
  assert.equal(r.summary.verdict, 'ERROR'); assert.equal(r.code, 2);
  assert.match(r.summary.error, /round 2.*issue/);
});

test('I2: a different branch in one round is ERROR', () => {
  const [a, b] = fixture([['A', 'push'], ['B', 'push'], ['A', 'push']]);
  const r = compare(patch(a, 3, { branch: 't/103-other' }), b);
  assert.equal(r.summary.verdict, 'ERROR');
  assert.match(r.summary.error, /round 3.*branch/);
});

test('I2: a duplicate round in one file is ERROR', () => {
  const [a, b] = fixture([['A', 'push'], ['B', 'push'], ['A', 'push']]);
  const r = compare(`${a}\n${a.split('\n')[1]}`, b);
  assert.equal(r.summary.verdict, 'ERROR');
  assert.match(r.summary.error, /round 2.*more than once/);
});

test('I2: a push loss to a ref held by some OTHER machine is not a race with this winner', () => {
  // Rounds 1-3 lost at the push, but the loser saw a third machine holding the ref (a leftover of an earlier attempt).
  const r = compare(...fixture([['A', 'push', 'gamma'], ['B', 'push', 'gamma'], ['A', 'push', 'gamma'], ['A', 'push'], ['B', 'push']]));
  assert.deepEqual(r.rounds.map((x) => x.raced), [false, false, false, true, true]);
  assert.equal(r.summary.raced, 2);
  assert.equal(r.summary.verdict, 'INCONCLUSIVE');
});

test('I2: a round with zero winners is FAILED and says the issue range was probably reused', () => {
  const r = compare(...fixture([['A', 'push'], ['none', 'precheck', 'gamma'], ['A', 'push'], ['B', 'push'], ['A', 'push']]));
  assert.equal(r.summary.verdict, 'FAILED'); assert.equal(r.code, 1);
  assert.match(r.summary.reason, /round 2: no winner/);
  assert.match(r.summary.reason, /issue range was probably reused/);
});
