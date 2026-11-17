// Plan 2 final review: one test block per finding (C1, C2, I1-I9).
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
const { createGh } = require('../../../lib/gh.js');
const reconcile = require('../../../lib/reconcile.js');
const impact = require('../../../lib/impact.js');
const { renderBody } = require('../../../lib/ticket-body.js');
const { parsePlan, planHashes } = require('../../../lib/plan.js');
const { loadConfig } = require('../../../lib/config.js');
const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(here, '../fixtures/PLAN-list.md'), 'utf8');

const CONFIG = {
  plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' },
  repos: {
    'acme-api': { github: 'acme/api', default: 'main', label: 'api', ci: 'required', tests: ['dotnet test'] },
    'acme-mobile': { github: 'acme/mobile', default: 'master', label: 'mobile', ci: 'none', tests: ['npm test'] },
  },
  ownerArea: 'owner',
  stages: { A: 'Stage A — Gates', later: 'Post-launch' },
  github: { writeDelayMs: 0 },
};
const DEC = '# D\n\n### D-1 · First\n- rule: a\n\n### D-8 · Eighth\n- rule: b\n';
const RUL = '# R\n\n### RL-7 · Seventh\n- rule: c\n';
const LEASE = 'orchestrator: 00000000000000aa · box1 · since 2026-11-16T00:00:00Z';

// Core repo with a bare origin; HEAD == origin/main.
function core({ config = CONFIG, plan = fixture, branch = 'main' } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'devfw-ff-'));
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify(config));
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), plan);
  writeFileSync(join(dir, 'docs/plan/DECISIONS.md'), DEC);
  writeFileSync(join(dir, 'docs/plan/RULINGS.md'), RUL);
  writeFileSync(join(dir, 'docs/plan/START-HERE.md'), LEASE + '\n\n# Start\n');
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  g('init', '-q', '-b', branch); g('config', 'user.email', 'a@acme.test'); g('config', 'user.name', 'a');
  g('config', 'core.autocrlf', 'false');
  g('add', '-A'); g('commit', '-qm', 'base');
  const bare = mkdtempSync(join(tmpdir(), 'devfw-ff-origin-'));
  execFileSync('git', ['init', '-q', '--bare', '-b', branch, bare]);
  g('remote', 'add', 'origin', bare); g('push', '-q', 'origin', branch);
  g('fetch', '-q', 'origin');
  return { dir, bare, g, sha: g('rev-parse', 'HEAD').trim() };
}

// Push an edit to origin from a second clone, leaving `dir` stale.
function upstreamEdit(c, file, from, to, branch = 'main') {
  const other = mkdtempSync(join(tmpdir(), 'devfw-ff-other-'));
  execFileSync('git', ['clone', '-q', '-b', branch, c.bare, other]);
  const p = join(other, 'docs/plan', file);
  const t = readFileSync(p, 'utf8');
  assert.ok(t.includes(from), `seed text missing: ${from}`);
  writeFileSync(p, t.replace(from, to));
  const o = (...a) => execFileSync('git', ['-C', other, '-c', 'user.name=a', '-c', 'user.email=a@acme.test', ...a], { encoding: 'utf8' });
  o('commit', '-qam', 'upstream edit'); o('push', '-q', 'origin', branch);
  return o('rev-parse', 'HEAD').trim();
}

function bodyOf(dir, id, ref = 'HEAD') {
  const config = loadConfig({ coreDir: dir, env: {} });
  const text = execFileSync('git', ['-C', dir, 'show', `${ref}:docs/plan/PLAN.md`], { encoding: 'utf8' });
  const items = parsePlan(text, config);
  return renderBody(items.find((i) => i.id === id), { hashes: planHashes(dir, ref, config), issueNumbers: new Map(), planSha: ref, config });
}
const issue = (n, id, body, state = 'open') => ({
  number: n, state, body, title: id, created_at: '2026-11-01T00:00:00Z', labels: [{ name: `plan:${id}` }],
});
const SINCE = 'GET repos/acme/core/issues/comments?since=2026-11-01T00:00:00Z';
const stateOf = (r, id) => r.result.items.find((i) => i.id === id);

// ---------------------------------------------------------------- C1
test('C1(b): paginate throws when a page repeats the previous page (an endpoint that ignores page=)', () => {
  let n = 0;
  const full = JSON.stringify(Array.from({ length: 150 }, (_, i) => ({ i })));
  const gh = createGh({ exec: () => { if (++n > 200) throw new Error('runaway: paginate never stopped'); return full; } });
  assert.throws(() => gh.paginate('repos/acme/api/git/matching-refs/heads/t/'), /same content as page 1/);
  assert.equal(n, 2, 'stops at the first repeated page');
});

test('C1(b): paginate throws after 50 pages even when every page differs', () => {
  let n = 0;
  const gh = createGh({ exec: () => { if (++n > 200) throw new Error('runaway: paginate never stopped'); return JSON.stringify(Array.from({ length: 100 }, (_, i) => ({ n, i }))); } });
  assert.throws(() => gh.paginate('repos/acme/core/issues'), /more than 50 pages/);
  assert.equal(n, 50);
});

test('C1(c): the fake serves matching-refs whole for every page=, like the real endpoint', () => {
  const refs = Array.from({ length: 150 }, (_, i) => ({ ref: `refs/heads/t/${1000 + i}-x` }));
  const { gh } = fakeGh({ 'GET repos/acme/api/git/matching-refs/heads/t/': refs });
  assert.equal(gh.api('GET', 'repos/acme/api/git/matching-refs/heads/t/?per_page=100&page=2').length, 150);
  assert.throws(() => gh.paginate('repos/acme/api/git/matching-refs/heads/t/'), /same content as page 1/);
});

const refs150 = (last) => [...Array.from({ length: 149 }, (_, i) => ({ ref: `refs/heads/t/${1000 + i}-x` })), { ref: `refs/heads/${last}` }];

test('C1 fence: 150 claim refs; reconcile finishes and sees the 150th (one read, no pagination)', () => {
  const c = core();
  const { gh } = fakeGh({
    'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', bodyOf(c.dir, 'P-0-3'))],
    [SINCE]: [],
    'GET repos/acme/api/git/matching-refs/heads/t/': refs150('t/41-health'),
    'GET repos/acme/api/pulls?state=all': [],
  });
  const r = reconcile.run({ argv: ['--core-dir', c.dir, '--ref', 'HEAD'], gh, env: {} });
  assert.equal(r.exitCode, 0, JSON.stringify(r.result));
  assert.equal(stateOf(r, 'P-0-3').state, 'in-progress');
});

test('C1 fence: 150 claim refs; impact lists the claim branch that is 150th', () => {
  const c = core();
  c.g('checkout', '-q', '-b', 'pr');
  const p = join(c.dir, 'docs/plan/PLAN.md');
  writeFileSync(p, readFileSync(p, 'utf8').replace('Disable Swagger in production builds.', 'Disable Swagger everywhere.'));
  c.g('commit', '-qam', 'head');
  const head = c.g('rev-parse', 'HEAD').trim();
  const { gh } = fakeGh({
    'GET repos/acme/core/pulls/7': { number: 7, body: 'lease: 00000000000000aa', base: { sha: c.sha }, head: { sha: head } },
    'GET repos/acme/core/pulls/7/files': [{ filename: 'docs/plan/PLAN.md' }],
    'GET repos/acme/core/issues?state=all': [issue(12, 'P-0-4', `- **Cites:** P-0-4@${'a'.repeat(12)}\n`)],
    'GET repos/acme/core/issues/7/comments': [],
    'GET repos/acme/api/pulls?state=open': [], 'GET repos/acme/mobile/pulls?state=open': [],
    'GET repos/acme/api/git/matching-refs/heads/t/': refs150('t/12-swagger'),
    'GET repos/acme/mobile/git/matching-refs/heads/t/': [],
  });
  const r = impact.run({ argv: ['--core-dir', c.dir, '--pr', '7'], gh, env: {} });
  assert.deepEqual(r.result.affected.filter((a) => a.kind === 'branch').map((a) => a.branch), ['t/12-swagger']);
});

// ---------------------------------------------------------------- C2
const { PlanError } = require('../../../lib/plan.js');
const P_CFG = { ownerArea: 'owner', repos: CONFIG.repos };
const withP4 = (depends, decisions) => fixture
  .replace('- depends: P-0-3\n', depends === null ? '' : `- depends:${depends}\n`)
  .replace('- decisions: D-8, RL-7\n', `- decisions:${decisions}\n`);
const p4 = (text) => parsePlan(text, P_CFG).find((i) => i.id === 'P-0-4');

test('C2: a depends value that starts with — means none', () => {
  const it = p4(withP4(' — (after launch)', ' D-8'));
  assert.deepEqual(it.deps, []);
  assert.equal(it.fields.depends, '—');
});

test('C2: a decisions value that starts with — means none, and renders without throwing', () => {
  const c = core({ plan: withP4(' —', ' — (note)') });
  const config = loadConfig({ coreDir: c.dir, env: {} });
  const it = parsePlan(withP4(' —', ' — (note)'), config).find((i) => i.id === 'P-0-4');
  assert.deepEqual(it.decisions, []);
  assert.equal(it.fields.decisions, '—');
  const body = renderBody(it, { hashes: planHashes(c.dir, 'HEAD', config), planSha: c.sha, config });
  assert.match(body, /- \*\*Cites:\*\* P-0-4@[0-9a-f]{12}\n/);
});

test('C2: an empty depends: value is none', () => {
  for (const v of ['', ' ', '  \t']) {
    const it = p4(withP4(v, ' D-8'));
    assert.deepEqual(it.deps, [], JSON.stringify(v));
    assert.equal(it.fields.depends, '—', JSON.stringify(v));
  }
});

test('C2: a range such as O-1–O-11 still throws PlanError', () => {
  assert.throws(() => p4(withP4(' O-1–O-11', ' D-8')), (e) => e instanceof PlanError && /O-1–O-11/.test(e.message));
  assert.throws(() => p4(withP4(' P-0-3, O-1–O-11', ' D-8')), PlanError);
});
