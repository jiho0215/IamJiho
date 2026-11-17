import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { digest } = createRequire(import.meta.url)('../../../lib/digest.js');

const item = (id, title, state) => `### ${id} · ${title}\n- stage: A\n- kind: code\n- state: ${state}\n- area: acme-api\n\nBody.\n\n`;
const PLAN = '# Plan\n\n## Stage A\n\n' + item('P-1', 'One', 'ready') + item('P-2', 'Two', 'in-progress') + item('P-3', 'Three', 'done')
  + item('P-4', 'Four', 'blocked') + '### D-3 · Owner ruling\nLockout is 15 minutes.\n';
const LEASE = 'orchestrator: 0123456789abcdef · host-a · since 2026-11-17T10:00:00Z';
const START = `${LEASE}\n\n## Focus\nShip hooks.\nThen docs.\n\n## Other\nhidden\n`;
const base = { planText: PLAN, startHereText: START, sha: 'abcdef0123456789abcdef', branch: 'main', version: '6.0.0', stale: false };

test('lines in order; done items and decision entries absent', () => {
  assert.deepEqual(digest(base).split('\n'), [
    'dev-framework 6.0.0 · plan origin/main@abcdef012345', LEASE, '## Focus', 'Ship hooks.', 'Then docs.', 'open items:',
    'P-1 · One [ready]', 'P-2 · Two [in-progress]', 'P-4 · Four [blocked]',
  ]);
});

test('STALE prefix, and lease none when line 1 is not a lease', () => {
  const t = digest({ ...base, stale: true, startHereText: '## Focus\nx\n' });
  assert.match(t.split('\n')[0], /^STALE \(fetch failed\) · dev-framework 6\.0\.0 /);
  assert.equal(t.split('\n')[1], 'lease: none');
});

test('Focus capped at 2000 chars on a whole line', () => {
  const long = Array.from({ length: 100 }, (_, i) => `line-${i} ${'x'.repeat(40)}`).join('\n');
  const t = digest({ ...base, startHereText: `${LEASE}\n## Focus\n${long}\n` });
  const lines = t.split('\n');
  const body = lines.slice(3, lines.indexOf('open items:'));
  assert.ok(body.join('\n').length <= 2000 && body.length < 100);
  assert.ok(body.every((l) => /^line-\d+ x{40}$/.test(l)));
});

test('600 items: <= 10000 chars and an exact "… N more" line', () => {
  const plan = Array.from({ length: 600 }, (_, i) => item(`P-${i + 1}`, `Item number ${i + 1} title`, 'ready')).join('');
  const t = digest({ ...base, planText: plan });
  assert.ok(t.length <= 10000);
  const lines = t.split('\n');
  const shown = lines.filter((l) => /^P-\d+ · /.test(l)).length;
  const m = /^… (\d+) more open items; read the plan through the orchestrate skill$/.exec(lines.at(-1));
  assert.ok(m, 'last line is the more line');
  assert.equal(Number(m[1]), 600 - shown);
  assert.ok(shown > 100 && shown < 600);
  // maximal: with one more item line the result would exceed the cap
  const next = `P-${shown + 1} · Item number ${shown + 1} title [ready]`;
  const more = `… ${600 - shown - 1} more open items; read the plan through the orchestrate skill`;
  const without = lines.slice(0, -1).join('\n');
  assert.ok((without + '\n' + next + '\n' + more).length > 10000);
});

test('cap boundary: exactly 10000 chars is kept whole, 10001 is cut', () => {
  const mk = (n, lastTitle) => Array.from({ length: n }, (_, i) => item(`P-${i + 1}`, i === n - 1 ? lastTitle : `Item ${i + 1} title`, 'ready')).join('');
  const N = 200;
  const L0 = digest({ ...base, planText: mk(N - 1, `Item ${N - 1} title`) }).length;
  assert.ok(L0 < 10000);
  const lastLen = (title) => `P-${N} · ${title} [ready]`.length;
  const fit = (total) => 'y'.repeat(total - L0 - 1 - (lastLen('') ));
  const exact = digest({ ...base, planText: mk(N, fit(10000)) });
  assert.equal(exact.length, 10000);
  assert.ok(!/more open items/.test(exact));
  const over = digest({ ...base, planText: mk(N, fit(10001)) });
  assert.ok(over.length <= 10000);
  assert.match(over.split('\n').at(-1), /^… 1 more open items/);
});
