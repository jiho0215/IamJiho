import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { fakeGh } from './fake-gh.mjs';

const require = createRequire(import.meta.url);
const { run } = require('../../../lib/reconcile.js');
const { planHashes } = require('../../../lib/plan.js');
const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(here, '../fixtures/PLAN-list.md'), 'utf8');

const CONFIG = {
  plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' },
  repos: {
    'acme-api': { github: 'acme/api', default: 'main', label: 'api', ci: 'required', tests: ['dotnet test'] },
    'acme-mobile': { github: 'acme/mobile', default: 'master', label: 'mobile', ci: 'none', tests: ['npm test'] },
  },
  ownerArea: 'owner',
  github: { writeDelayMs: 0 },
  reconcile: { lookbackDays: 14 },
};

// Day-1 plan commit, then P-0-4 edited on "day 3" and pushed to origin.
function core() {
  const dir = mkdtempSync(join(tmpdir(), 'devfw-pm-'));
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify(CONFIG));
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), fixture);
  writeFileSync(join(dir, 'docs/plan/DECISIONS.md'), '# D\n\n### D-1 · First\n- rule: a\n\n### D-8 · Eighth\n- rule: b\n');
  writeFileSync(join(dir, 'docs/plan/RULINGS.md'), '# R\n\n### RL-7 · Seventh\n- rule: c\n');
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 'a@acme.test'); g('config', 'user.name', 'a');
  g('add', '-A'); g('commit', '-qm', 'day 1');
  const day1 = g('rev-parse', 'HEAD').trim();
  const bare = mkdtempSync(join(tmpdir(), 'devfw-pm-origin-'));
  execFileSync('git', ['init', '-q', '--bare', bare]);
  g('remote', 'add', 'origin', bare);
  const hashes1 = planHashes(dir, day1, CONFIG);
  const p = join(dir, 'docs/plan/PLAN.md');
  writeFileSync(p, readFileSync(p, 'utf8').replace('Disable Swagger in production builds.', 'Disable Swagger and the OpenAPI JSON in production builds.'));
  g('add', '-A'); g('commit', '-qm', 'day 3: edit P-0-4');
  g('push', '-q', 'origin', 'main');
  const day3 = g('rev-parse', 'HEAD').trim();
  const hashes3 = planHashes(dir, day3, CONFIG);
  assert.notEqual(hashes1.get('P-0-4'), hashes3.get('P-0-4'), 'seed must discriminate');
  return { dir, day1, day3, hashes1, hashes3 };
}

const DAY = 86400000;
const iso = (daysAgo) => new Date(Date.now() - daysAgo * DAY).toISOString();
const EVID = 'Evidence:\ndotnet test: 120 passed\n';
const prBody = (cite) => `Fixes acme/core#12\nCites: P-0-4@${cite}\n\n${EVID}`;
const pr = (n, mergedDaysAgo, cite, over = {}) => ({
  number: n, merged_at: iso(mergedDaysAgo), base: { ref: 'main' },
  head: { ref: 't/12-swagger', sha: `sha${n}` }, body: prBody(cite), ...over,
});

const issueBody = (...ids) => `## item\n\n- **Cites:** ${ids.join(', ')}\n`;

function routes(c, prs, { sha, issues = [], mobile = [], issue12 } = {}) {
  const r = {
    'GET repos/acme/api/pulls?state=closed': prs,
    'GET repos/acme/mobile/pulls?state=closed': mobile,
    'GET repos/acme/core/issues?state=all&labels=merged-stale': issues,
    'GET repos/acme/core/issues/12/comments': [],
    'GET repos/acme/core/issues/12': { number: 12, body: issue12 || issueBody(`P-0-4@${c.hashes1.get('P-0-4')}`) },
  };
  for (const p of prs) {
    r[`GET repos/acme/api/commits/${p.head.sha}/check-runs`] = { total_count: 1, check_runs: [{ name: 'build', status: 'completed', conclusion: 'success' }] };
    r[`GET repos/acme/api/commits/${p.head.sha}/status`] = { state: 'success', statuses: [] };
    r[`GET repos/acme/core/commits?sha=main&until=${p.merged_at}&per_page=1`] = sha === null ? [] : [{ sha: sha || c.day1 }];
  }
  return r;
}

const go = (c, r, extra = []) => {
  const { gh, calls } = fakeGh(r);
  const out = run({ argv: ['--core-dir', c.dir, '--post-merge', ...extra], gh, env: {} });
  return { ...out, calls };
};

test('Review Focus 5: a PR judged against the plan at merge time is NOT stale after a later edit', () => {
  const c = core();
  const { exitCode, result, calls } = go(c, routes(c, [pr(50, 12, c.hashes1.get('P-0-4'))]));
  assert.equal(exitCode, 0);
  assert.deepEqual(result.staleMerges, []);
  assert.deepEqual(result.unverifiable, []);
  assert.deepEqual(calls.filter((x) => x.method !== 'GET'), []);
});

test('positive control: citing a hash the plan never had is stale', () => {
  const c = core();
  const { result } = go(c, routes(c, [pr(50, 12, 'cccccccccccc')]));
  assert.equal(result.staleMerges.length, 1);
  assert.equal(result.staleMerges[0].repo, 'acme/api');
  assert.equal(result.staleMerges[0].pr, 50);
  assert.ok(result.staleMerges[0].reasons.some((x) => x.includes('P-0-4@cccccccccccc is stale')), result.staleMerges[0].reasons.join('|'));
});

test('citing the day-3 hash on a day-1 merge is stale (the plan did not have it yet)', () => {
  const c = core();
  const { result } = go(c, routes(c, [pr(50, 12, c.hashes3.get('P-0-4'))]));
  assert.equal(result.staleMerges.length, 1);
});

test('missing Evidence and a failing CI check on a ci:required repo are both reported', () => {
  const c = core();
  const p = pr(50, 12, c.hashes1.get('P-0-4'), { body: `Fixes acme/core#12\nCites: P-0-4@${c.hashes1.get('P-0-4')}\n` });
  const r = routes(c, [p]);
  r['GET repos/acme/api/commits/sha50/check-runs'] = { total_count: 1, check_runs: [{ name: 'build', status: 'completed', conclusion: 'failure' }] };
  const { result } = go(c, r);
  const reasons = result.staleMerges[0].reasons.join('|');
  assert.match(reasons, /evidence:/);
  assert.match(reasons, /ci: check "build" concluded failure/);
});

test('a ci:none repo is not CI-checked post-merge', () => {
  const c = core();
  const m = { number: 7, merged_at: iso(3), base: { ref: 'master' }, head: { ref: 't/12-x', sha: 'm7' }, body: prBody(c.hashes1.get('P-0-4')) };
  const r = routes(c, [], { mobile: [m] });
  r[`GET repos/acme/core/commits?sha=main&until=${m.merged_at}&per_page=1`] = [{ sha: c.day1 }];
  const { result } = go(c, r); // no check-run routes for acme/mobile: any CI read would throw
  assert.deepEqual(result.staleMerges, []);
});

test('filters: outside lookback, wrong base, non-t/ branch, unmerged are skipped (no commit lookup)', () => {
  const c = core();
  const cite = 'cccccccccccc';
  const prs = [
    pr(1, 20, cite), // too old
    pr(2, 3, cite, { base: { ref: 'dev' } }), // not the default branch
    pr(3, 3, cite, { head: { ref: 'feature/x', sha: 's3' } }), // not t/*
    pr(4, 3, cite, { merged_at: null }), // closed unmerged
  ];
  const { result } = go(c, { 'GET repos/acme/api/pulls?state=closed': prs, 'GET repos/acme/mobile/pulls?state=closed': [], 'GET repos/acme/core/issues?state=all&labels=merged-stale': [] });
  assert.deepEqual(result.staleMerges, []);
});

test('fail closed: an unresolvable plan commit is reported unverifiable, never fine', () => {
  const c = core();
  const none = go(c, routes(c, [pr(50, 12, 'cccccccccccc')], { sha: null }));
  assert.deepEqual(none.result.staleMerges, []);
  assert.equal(none.result.unverifiable.length, 1);
  assert.equal(none.result.unverifiable[0].pr, 50);
  const missing = go(c, routes(c, [pr(50, 12, 'cccccccccccc')], { sha: '0123456789abcdef0123456789abcdef01234567' }));
  assert.equal(missing.result.unverifiable.length, 1, 'a sha absent from the clone is unverifiable');
});

test('--apply twice: one issue created, the second run creates none', () => {
  const c = core();
  const prs = [pr(50, 12, 'cccccccccccc')];
  const first = go(c, routes(c, prs), ['--apply']);
  const posts = first.calls.filter((x) => x.method === 'POST');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].path, 'repos/acme/core/issues');
  assert.equal(posts[0].body.title, 'merged-stale: acme/api#50');
  assert.deepEqual(posts[0].body.labels, ['merged-stale']);
  const existing = [{ number: 99, title: 'merged-stale: acme/api#50', state: 'open', labels: [{ name: 'merged-stale' }] }];
  const second = go(c, routes(c, prs, { issues: existing }), ['--apply']);
  assert.equal(second.calls.filter((x) => x.method === 'POST').length, 0);
  assert.equal(second.result.staleMerges.length, 1, 'still reported');
});

test('dry run (no --apply) never writes', () => {
  const c = core();
  const { calls, result } = go(c, routes(c, [pr(50, 12, 'cccccccccccc')]));
  assert.equal(result.staleMerges.length, 1);
  assert.deepEqual(calls.filter((x) => x.method !== 'GET'), []);
});

test('exit codes: clean run 0; one stale PR 9 (dry run and apply alike)', () => {
  const c = core();
  assert.equal(go(c, routes(c, [pr(50, 12, c.hashes1.get('P-0-4'))])).exitCode, 0);
  assert.equal(go(c, routes(c, [pr(50, 12, 'cccccccccccc')])).exitCode, 9);
  assert.equal(go(c, routes(c, [pr(50, 12, 'cccccccccccc')]), ['--apply']).exitCode, 9);
});

test('unverifiable (origin unreachable): --apply opens one merged-unverifiable issue per PR, exit 9, idempotent', () => {
  const c = core();
  execFileSync('git', ['-C', c.dir, 'remote', 'set-url', 'origin', join(tmpdir(), 'devfw-no-such-origin')]);
  const prs = [pr(50, 12, c.hashes1.get('P-0-4')), pr(51, 5, c.hashes1.get('P-0-4'))];
  const dry = go(c, routes(c, prs));
  assert.equal(dry.exitCode, 9);
  assert.equal(dry.result.unverifiable.length, 2);
  assert.deepEqual(dry.calls.filter((x) => x.method !== 'GET'), []);
  const first = go(c, routes(c, prs), ['--apply']);
  assert.equal(first.exitCode, 9);
  const posts = first.calls.filter((x) => x.method === 'POST');
  assert.deepEqual(posts.map((p) => p.body.title).sort(), ['merged-unverifiable: acme/api#50', 'merged-unverifiable: acme/api#51']);
  for (const p of posts) { assert.deepEqual(p.body.labels, ['merged-stale']); assert.match(p.body.body, /cannot fetch origin main/); }
  const existing = posts.map((p, i) => ({ number: 90 + i, title: p.body.title, state: 'open', labels: [{ name: 'merged-stale' }] }));
  const second = go(c, routes(c, prs, { issues: existing }), ['--apply']);
  assert.equal(second.calls.filter((x) => x.method === 'POST').length, 0);
  assert.equal(second.exitCode, 9);
});

test('ack cutoff: an ack dated before merged_at clears a stale cite; the same ack dated after does not', () => {
  const c = core();
  // The plan at merge time is day 3; the PR cites the day-1 hash, so it is stale unless acked.
  const p = pr(50, 12, c.hashes1.get('P-0-4'));
  const ack = (when) => [{ body: `ack 12 ${c.day3}: P-0-4 text only`, created_at: when, issue_url: 'https://api.github.com/repos/acme/core/issues/12', author_association: 'OWNER' }];
  const mk = (when) => { const r = routes(c, [p], { sha: c.day3 }); r['GET repos/acme/core/issues/12/comments'] = ack(when); return r; };
  const before = go(c, mk(iso(13)));
  assert.deepEqual(before.result.staleMerges, [], 'ack predating the merge covers it');
  const after = go(c, mk(iso(2)));
  assert.equal(after.result.staleMerges.length, 1, 'ack added after the merge must not count');
  assert.match(after.result.staleMerges[0].reasons.join('|'), /no covering ack/);
});

test('ticket tie (a): a merged PR from t/42-x that fixes #41 is stale with a ticket: reason', () => {
  const c = core();
  const h = c.hashes1.get('P-0-4');
  const p = pr(50, 12, h, { head: { ref: 't/42-x', sha: 'sha50' }, body: `Fixes acme/core#41\nCites: P-0-4@${h}\n\n${EVID}` });
  const r = routes(c, [p]);
  r['GET repos/acme/core/issues/41'] = { number: 41, body: issueBody(`P-0-4@${h}`) };
  r['GET repos/acme/core/issues/41/comments'] = [];
  const { result, exitCode } = go(c, r);
  assert.equal(exitCode, 9);
  assert.equal(result.staleMerges.length, 1);
  assert.ok(result.staleMerges[0].reasons.some((x) => x.startsWith('ticket:')), result.staleMerges[0].reasons.join('|'));
});

test('ticket tie (b): the right branch but a cite the issue lists is missing is stale', () => {
  const c = core();
  const h = c.hashes1.get('P-0-4');
  const r = routes(c, [pr(50, 12, h)], { issue12: issueBody(`P-0-4@${h}`, `D-1@${c.hashes1.get('D-1')}`) });
  const { result } = go(c, r);
  assert.equal(result.staleMerges.length, 1);
  assert.deepEqual(result.staleMerges[0].reasons.filter((x) => !x.startsWith('ticket:')), []);
  assert.match(result.staleMerges[0].reasons.join('|'), /ticket: PR does not cite D-1/);
});

test('ticket tie (c) positive control: the right branch with every cite is not stale', () => {
  const c = core();
  const h = c.hashes1.get('P-0-4');
  const d = c.hashes1.get('D-1');
  const p = pr(50, 12, h, { body: `Fixes acme/core#12\nCites: P-0-4@${h}, D-1@${d}\n\n${EVID}` });
  const { result, exitCode } = go(c, routes(c, [p], { issue12: issueBody(`P-0-4@${h}`, `D-1@${d}`) }));
  assert.deepEqual(result.staleMerges, []);
  assert.equal(exitCode, 0);
});
