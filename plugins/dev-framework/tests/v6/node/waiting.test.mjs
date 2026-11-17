import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fakeGh } from './fake-gh.mjs';

const require = createRequire(import.meta.url);
const { run } = require('../../../lib/waiting.js');
const { parseCommand } = require('../../../lib/comments.js');

const CONFIG = { plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' }, repos: {}, ownerArea: 'owner' };
const coreDir = () => {
  const d = mkdtempSync(join(tmpdir(), 'devfw-wait-'));
  writeFileSync(join(d, 'orchestrator.json'), JSON.stringify(CONFIG));
  return d;
};
let nextId = 1;
const c = (body, at) => ({ id: nextId++, body, created_at: at, html_url: `https://github.test/acme/core/issues/1#c${nextId}`, author_association: 'OWNER' });

// The since= value depends on the clock, so route by prefix.
function routes(comments, seenPaths) {
  const key = 'GET repos/acme/core/issues/comments';
  return new Proxy({}, {
    has: (_, k) => { const hit = String(k).startsWith(key + '?since='); if (hit) seenPaths.push(String(k)); return hit; },
    get: (_, k) => (String(k).startsWith(key + '?since=') ? comments : undefined),
  });
}
const waiting = (comments) => {
  const seen = [];
  const { gh } = fakeGh(routes(comments, seen));
  const out = run({ argv: ['--core-dir', coreDir()], gh, env: {} });
  return { ...out, seen };
};

test('parseCommand reads only line 1 and knows the seven kinds', () => {
  assert.deepEqual(parseCommand('owner-ask 41: which one?\nowner-said 41: no'), { kind: 'owner-ask', issue: 41, rest: 'which one?' });
  assert.deepEqual(parseCommand('plan-ready 42 PR acme/core#9'), { kind: 'plan-ready', issue: 42, rest: 'PR acme/core#9' });
  assert.equal(parseCommand('hello\nowner-said 41: ok'), null);
  assert.equal(parseCommand('owner-said: no number'), null);
  for (const k of ['ack', 'owner-said', 'stopped', 'plan-request', 'plan-applied']) assert.equal(parseCommand(`${k} 7: x`).kind, k);
});

test('owner-ask then a later owner-said clears it', () => {
  const { exitCode, result } = waiting([c('owner-ask 41: pick', '2026-11-10T10:00:00Z'), c('owner-said 41: ok', '2026-11-10T11:00:00Z')]);
  assert.equal(exitCode, 0);
  assert.deepEqual(result.owner, []);
});

test('plan-ready alone is listed with issue, kind, since, url; read once with a 30 day since', () => {
  const { result, seen } = waiting([c('plan-ready 42 acme/core#9', '2026-11-10T10:00:00Z')]);
  assert.equal(result.owner.length, 1);
  assert.equal(result.owner[0].issue, 42);
  assert.equal(result.owner[0].kind, 'plan-ready');
  assert.equal(result.owner[0].since, '2026-11-10T10:00:00Z');
  assert.match(result.owner[0].url, /^https:/);
  const since = Date.parse(/since=([^&]+)/.exec(seen[0])[1]);
  const days = (Date.now() - since) / 86400000;
  assert.ok(days > 29.9 && days < 30.1, `since is ${days} days ago`);
});

test('an owner-said BEFORE the ask does not clear it (order matters)', () => {
  const { result } = waiting([c('owner-said 41: early', '2026-11-10T09:00:00Z'), c('owner-ask 41: late', '2026-11-10T10:00:00Z')]);
  assert.deepEqual(result.owner.map((x) => [x.issue, x.kind]), [[41, 'owner-ask']]);
});

test('owner-said on a different issue does not clear; stopped is listed', () => {
  const { result } = waiting([c('stopped 5: halted', '2026-11-10T10:00:00Z'), c('owner-said 6: ok', '2026-11-10T11:00:00Z')]);
  assert.deepEqual(result.owner.map((x) => [x.issue, x.kind]), [[5, 'stopped']]);
});

test('plan-request is waiting for the orchestrator until a later plan-applied', () => {
  const open = waiting([c('plan-request 8: add item', '2026-11-10T10:00:00Z'), c('plan-applied 9: other', '2026-11-10T12:00:00Z')]);
  assert.deepEqual(open.result.orchestrator.map((x) => x.issue), [8]);
  const done = waiting([c('plan-request 8: add item', '2026-11-10T10:00:00Z'), c('plan-applied 8: done', '2026-11-10T12:00:00Z')]);
  assert.deepEqual(done.result.orchestrator, []);
  const early = waiting([c('plan-applied 8: early', '2026-11-10T09:00:00Z'), c('plan-request 8: add', '2026-11-10T10:00:00Z')]);
  assert.deepEqual(early.result.orchestrator.map((x) => x.issue), [8]);
});

test('comments are ordered by created_at, not by arrival order', () => {
  const { result } = waiting([c('owner-said 41: ok', '2026-11-10T11:00:00Z'), c('owner-ask 41: pick', '2026-11-10T10:00:00Z')]);
  assert.deepEqual(result.owner, []);
});
