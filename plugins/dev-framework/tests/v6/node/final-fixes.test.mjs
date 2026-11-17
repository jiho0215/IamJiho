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

// ---------------------------------------------------------------- I5
const { ConfigError } = require('../../../lib/config.js');
const cfgFile = (cfg) => { const d = mkdtempSync(join(tmpdir(), 'devfw-ff-cfg-')); writeFileSync(join(d, 'orchestrator.json'), JSON.stringify(cfg)); return d; };
const tweak = (fn) => { const c = JSON.parse(JSON.stringify(CONFIG)); fn(c); return c; };

test('I5: a valid config loads (positive control)', () => {
  assert.equal(loadConfig({ coreDir: cfgFile(CONFIG), env: {} }).plan.repo, 'acme/core');
});

for (const [name, fn, re] of [
  ['repos.*.default missing', (c) => { delete c.repos['acme-api'].default; }, /repos\.acme-api\.default/],
  ['repos.*.default empty', (c) => { c.repos['acme-api'].default = ''; }, /repos\.acme-api\.default/],
  ['repos.*.default not a string', (c) => { c.repos['acme-api'].default = 7; }, /repos\.acme-api\.default/],
  ['plan.repo empty', (c) => { c.plan.repo = ''; }, /plan\.repo/],
  ['plan.repo not owner/name', (c) => { c.plan.repo = 'acme'; }, /plan\.repo/],
  ['plan.branch empty', (c) => { c.plan.branch = ''; }, /plan\.branch/],
  ['plan.branch not a string', (c) => { c.plan.branch = 3; }, /plan\.branch/],
  ['plan.path empty', (c) => { c.plan.path = ''; }, /plan\.path/],
  ['ci:none with no tests', (c) => { delete c.repos['acme-mobile'].tests; }, /repos\.acme-mobile\.tests/],
  ['ci:none with an empty tests array', (c) => { c.repos['acme-mobile'].tests = []; }, /repos\.acme-mobile\.tests/],
  ['ci:none with tests not an array', (c) => { c.repos['acme-mobile'].tests = 'npm test'; }, /repos\.acme-mobile\.tests/],
  ['ci:none with a blank test command', (c) => { c.repos['acme-mobile'].tests = ['  ']; }, /repos\.acme-mobile\.tests/],
]) {
  test(`I5: ConfigError when ${name}`, () => {
    assert.throws(() => loadConfig({ coreDir: cfgFile(tweak(fn)), env: {} }), (e) => e instanceof ConfigError && re.test(e.message));
  });
}

test('I5: no config file at all fails closed (plan.repo is required)', () => {
  assert.throws(() => loadConfig({ coreDir: join(tmpdir(), 'devfw-ff-no-such-dir'), env: {} }), ConfigError);
});

test('I5: a script given a bad config exits 2', () => {
  const dir = cfgFile(tweak((c) => { c.repos['acme-api'].default = ''; }));
  const r = reconcile.run({ argv: ['--core-dir', dir, '--ref', 'HEAD'], gh: fakeGh({}).gh, env: {} });
  assert.equal(r.exitCode, 2);
  assert.match(r.result.error, /default/);
});

// ---------------------------------------------------------------- I1
const gate = require('../../../lib/gate.js');
const REQ = CONFIG.repos['acme-api'];
const NONE = CONFIG.repos['acme-mobile'];
const run_ = (name, conclusion, status = 'completed') => ({ name, status, conclusion });

test('I1: ci:required with every run skipped or neutral refuses with "ci: no successful check"', () => {
  const runs = [run_('a', 'skipped'), run_('b', 'neutral')];
  assert.deepEqual(gate.checkCi({ repoConfig: REQ, runs, statuses: [], evidence: '' }), ['ci: no successful check']);
  assert.deepEqual(gate.checkCi({ repoConfig: REQ, runs: [run_('a', 'skipped')], statuses: [], evidence: '' }), ['ci: no successful check']);
});

test('I1: one success run, or one success status, satisfies it (positive controls)', () => {
  assert.deepEqual(gate.checkCi({ repoConfig: REQ, runs: [run_('a', 'skipped'), run_('b', 'neutral'), run_('c', 'success')], statuses: [], evidence: '' }), []);
  assert.deepEqual(gate.checkCi({ repoConfig: REQ, runs: [run_('a', 'skipped')], statuses: [{ context: 'legacy', state: 'success' }], evidence: '' }), []);
});

test('I1: a success conclusion on a run that is not completed does not count', () => {
  const r = gate.checkCi({ repoConfig: REQ, runs: [run_('a', 'success', 'in_progress')], statuses: [], evidence: '' });
  assert.ok(r.includes('ci: no successful check'), r.join(' | '));
});

test('I1: ci:none with only skipped runs falls back to the Evidence test-command rule', () => {
  const runs = [run_('a', 'skipped')];
  assert.deepEqual(gate.checkCi({ repoConfig: NONE, runs, statuses: [], evidence: 'npm test: 40 passed' }), []);
  assert.ok(gate.checkCi({ repoConfig: NONE, runs, statuses: [], evidence: 'looked fine' }).length > 0);
});

test('I1: the post-merge check refuses an all-skipped merge the same way', () => {
  const c = core();
  const h = planHashes(c.dir, 'HEAD', CONFIG);
  const mergedAt = new Date(Date.now() - 2 * 86400000).toISOString();
  const p = { number: 50, merged_at: mergedAt, base: { ref: 'main' }, head: { ref: 't/12-swagger', sha: 'sha50' },
    body: `Fixes acme/core#12\nCites: P-0-4@${h.get('P-0-4')}, D-8@${h.get('D-8')}, RL-7@${h.get('RL-7')}\n\nEvidence:\ndotnet test: ok\n` };
  const routes = (runs) => ({
    'GET repos/acme/api/pulls?state=closed': [p], 'GET repos/acme/mobile/pulls?state=closed': [],
    'GET repos/acme/core/issues/12/comments': [],
    'GET repos/acme/core/issues/12': { number: 12, body: `- **Cites:** P-0-4@${h.get('P-0-4')}, D-8@${h.get('D-8')}, RL-7@${h.get('RL-7')}
` },
    'GET repos/acme/core/issues?state=all&labels=merged-stale': [],
    'GET repos/acme/api/commits/sha50/check-runs': { total_count: runs.length, check_runs: runs },
    'GET repos/acme/api/commits/sha50/status': { state: 'pending', statuses: [] },
    [`GET repos/acme/core/commits?sha=main&until=${mergedAt}&per_page=1`]: [{ sha: c.sha }],
  });
  const bad = reconcile.run({ argv: ['--core-dir', c.dir, '--post-merge'], gh: fakeGh(routes([run_('a', 'skipped')])).gh, env: {} });
  assert.equal(bad.exitCode, 9, JSON.stringify(bad.result));
  assert.ok(bad.result.staleMerges[0].reasons.includes('ci: no successful check'), JSON.stringify(bad.result));
  const ok = reconcile.run({ argv: ['--core-dir', c.dir, '--post-merge'], gh: fakeGh(routes([run_('a', 'success')])).gh, env: {} });
  assert.equal(ok.exitCode, 0, JSON.stringify(ok.result));
});

// ---------------------------------------------------------------- I3
const ticketSync = require('../../../lib/ticket-sync.js');
const { readdirSync } = await import('node:fs');
const TS_BASE = { 'GET repos/acme/core/labels': [], 'GET repos/acme/core/milestones?state=all': [] };

test('I3: resolvePlanRef: an explicit ref is used without fetching; no ref fetches; a failed fetch throws', () => {
  const { resolvePlanRef, PlanFetchError } = require('../../../lib/fetch-plan.js');
  const c = core();
  const config = loadConfig({ coreDir: c.dir, env: {} });
  upstreamEdit(c, 'PLAN.md', 'Expose a health endpoint.', 'Expose it upstream.');
  const before = c.g('rev-parse', 'origin/main').trim();
  assert.equal(resolvePlanRef({ coreDir: c.dir, config, ref: 'HEAD' }), 'HEAD');
  assert.equal(c.g('rev-parse', 'origin/main').trim(), before, 'an explicit ref must not fetch');
  assert.equal(resolvePlanRef({ coreDir: c.dir, config }), 'origin/main');
  assert.notEqual(c.g('rev-parse', 'origin/main').trim(), before, 'no ref: origin/main is fetched');
  c.g('remote', 'set-url', 'origin', join(tmpdir(), 'devfw-ff-no-such-origin'));
  assert.throws(() => resolvePlanRef({ coreDir: c.dir, config }), (e) => e instanceof PlanFetchError && /cannot fetch origin main/.test(e.message));
});

test('I3: ticket-sync with no --ref fetches: a stale clone sees the upstream edit as drift', () => {
  const c = core();
  const nums = [['P-0-3', 1], ['P-0-4', 2], ['P-0-5', 3]];
  const issues = nums.map(([id, n]) => issue(n, id, renderBody(parsePlan(fixture, loadConfig({ coreDir: c.dir, env: {} })).find((i) => i.id === id),
    { hashes: planHashes(c.dir, 'HEAD', CONFIG), issueNumbers: new Map(nums), planSha: c.sha, config: CONFIG })));
  const go = () => ticketSync.run({ argv: ['--core-dir', c.dir], gh: fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': issues }).gh, env: {} });
  const fresh = go();
  assert.equal(fresh.exitCode, 0, JSON.stringify(fresh.result));
  upstreamEdit(c, 'PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger, edited upstream.');
  const r = go();
  assert.equal(r.exitCode, 7, JSON.stringify(r.result));
  assert.deepEqual(r.result.drift.map((d) => d.id), ['P-0-4']);
  assert.ok(r.result.drift[0].diff.includes('+Disable Swagger, edited upstream.'));
});

test('I3: a plan branch other than main is honoured (no main exists on origin)', () => {
  const cfg = { ...CONFIG, plan: { ...CONFIG.plan, branch: 'trunk' } };
  const c = core({ config: cfg, branch: 'trunk' });
  const r = ticketSync.run({ argv: ['--core-dir', c.dir], gh: fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': [] }).gh, env: {} });
  assert.equal(r.exitCode, 7, JSON.stringify(r.result));
  assert.deepEqual(r.result.missing, ['P-0-3', 'P-0-4', 'P-0-5']);
  const rc = reconcile.run({ argv: ['--core-dir', c.dir], gh: fakeGh({ 'GET repos/acme/core/issues?state=all': [] }).gh, env: {} });
  assert.equal(rc.exitCode, 0, JSON.stringify(rc.result));
});

test('I3: ticket-sync maps a failed fetch to exit 2', () => {
  const c = core();
  c.g('remote', 'set-url', 'origin', join(tmpdir(), 'devfw-ff-no-such-origin'));
  const r = ticketSync.run({ argv: ['--core-dir', c.dir], gh: fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': [] }).gh, env: {} });
  assert.equal(r.exitCode, 2);
  assert.match(r.result.error, /cannot fetch origin main/);
});

test('I3: the five readers resolve the plan through lib/fetch-plan.js and carry no fetch of their own', () => {
  const lib = join(here, '../../../lib');
  for (const f of ['ticket-sync.js', 'reconcile.js', 'gate.js', 'impact.js', 'new-ticket.js']) {
    const src = readFileSync(join(lib, f), 'utf8');
    assert.match(src, /require\('\.\/fetch-plan'\)/, `${f} must use fetch-plan`);
    assert.match(src, /resolvePlanRef\(/, `${f} must call resolvePlanRef`);
  }
  const fetching = readdirSync(lib).filter((f) => f.endsWith('.js') && /'fetch'/.test(readFileSync(join(lib, f), 'utf8'))).sort();
  // impact.js keeps one fetch: the PR's own base/head shas (not the plan branch).
  assert.deepEqual(fetching, ['fetch-plan.js', 'impact.js']);
  const impactFetches = readFileSync(join(lib, 'impact.js'), 'utf8').split('\n').filter((l) => /'fetch'/.test(l));
  assert.ok(impactFetches.every((l) => !/refs\/heads|plan\.branch|origin\/\$\{/.test(l)), impactFetches.join('\n'));
});

// ---------------------------------------------------------------- I6
const waitingLib = require('../../../lib/waiting.js');
const by = (assoc, extra = {}) => ({ author_association: assoc, user: { login: 'someone' }, ...extra });

test('I6: an ack from author_association NONE does not clear needs-ack; the same ack from OWNER does', () => {
  const c = core();
  const oldBody = bodyOf(c.dir, 'P-0-3');
  const newSha = upstreamEdit(c, 'PLAN.md', 'Expose a health endpoint.', 'Expose a health endpoint, v2.');
  c.g('fetch', '-q', 'origin'); c.g('merge', '-q', '--ff-only', 'origin/main');
  const go = (who) => reconcile.run({
    argv: ['--core-dir', c.dir, '--ref', 'HEAD'],
    gh: fakeGh({
      'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', oldBody)],
      [SINCE]: [{ issue_url: 'https://api.github.com/repos/acme/core/issues/41', body: `ack 41 ${newSha}: fine`, ...who }],
      'GET repos/acme/api/git/matching-refs/heads/t/': [], 'GET repos/acme/api/pulls?state=all': [],
    }).gh,
    env: {},
  });
  assert.equal(stateOf(go(by('NONE')), 'P-0-3').state, 'needs-ack');
  assert.equal(stateOf(go(by('CONTRIBUTOR')), 'P-0-3').state, 'needs-ack');
  assert.equal(stateOf(go({}), 'P-0-3').state, 'needs-ack', 'no author_association at all is not trusted');
  for (const a of ['OWNER', 'MEMBER', 'COLLABORATOR']) assert.equal(stateOf(go(by(a)), 'P-0-3').state, 'ready', a);
});

test('I6: github.trustedAuthors extends the set by login (case-insensitive)', () => {
  const { isTrustedAuthor } = require('../../../lib/acks.js');
  const cfg = { github: { trustedAuthors: ['Release-Bot'] } };
  assert.equal(isTrustedAuthor({ author_association: 'NONE', user: { login: 'release-bot' } }, cfg), true);
  assert.equal(isTrustedAuthor({ author_association: 'NONE', user: { login: 'stranger' } }, cfg), false);
  assert.equal(isTrustedAuthor({ author_association: 'NONE', user: { login: 'release-bot' } }, {}), false);
  assert.equal(isTrustedAuthor({ author_association: 'owner' }, {}), false, 'exact upper-case values only');
});

test('I6: waiting - an owner-said from NONE does not clear the ask; from OWNER it does', () => {
  const ask = { id: 1, body: 'owner-ask 41: pick', created_at: '2026-11-10T10:00:00Z', ...by('OWNER') };
  const said = (assoc) => ({ id: 2, body: 'owner-said 41: ok', created_at: '2026-11-10T11:00:00Z', ...by(assoc) });
  assert.deepEqual(waitingLib.waiting([ask, said('NONE')], CONFIG).owner.map((x) => x.issue), [41]);
  assert.deepEqual(waitingLib.waiting([ask, said('OWNER')], CONFIG).owner, []);
});

test('I6: impact - a marker comment from NONE is ignored (its ticks do not count, a new one is posted)', () => {
  const c = core();
  c.g('checkout', '-q', '-b', 'pr');
  const p = join(c.dir, 'docs/plan/PLAN.md');
  writeFileSync(p, readFileSync(p, 'utf8').replace('Disable Swagger in production builds.', 'Disable Swagger everywhere.'));
  c.g('commit', '-qam', 'head');
  const head = c.g('rev-parse', 'HEAD').trim();
  const world = (comments) => fakeGh({
    'GET repos/acme/core/pulls/7': { number: 7, body: 'lease: 00000000000000aa', base: { sha: c.sha }, head: { sha: head } },
    'GET repos/acme/core/pulls/7/files': [{ filename: 'docs/plan/PLAN.md' }],
    'GET repos/acme/core/issues?state=all': [issue(12, 'P-0-4', `- **Cites:** P-0-4@${'a'.repeat(12)}\n`)],
    'GET repos/acme/core/issues/7/comments': comments,
    'GET repos/acme/api/pulls?state=open': [], 'GET repos/acme/mobile/pulls?state=open': [],
    'GET repos/acme/api/git/matching-refs/heads/t/': [], 'GET repos/acme/mobile/git/matching-refs/heads/t/': [],
  });
  const first = world([]);
  impact.run({ argv: ['--core-dir', c.dir, '--pr', '7', '--apply'], gh: first.gh, env: {} });
  const ticked = first.calls.find((x) => x.method === 'POST' && x.path.endsWith('/comments')).body.body.replace('- [ ]', '- [x]');
  const forged = world([{ id: 901, body: ticked, ...by('NONE') }]);
  const r1 = impact.run({ argv: ['--core-dir', c.dir, '--pr', '7', '--apply'], gh: forged.gh, env: {} });
  assert.equal(r1.result.pending, 1);
  assert.equal(r1.exitCode, 8);
  assert.equal(forged.calls.filter((x) => x.method === 'PATCH').length, 0);
  const real = world([{ id: 901, body: ticked, ...by('OWNER') }]);
  const r2 = impact.run({ argv: ['--core-dir', c.dir, '--pr', '7', '--apply'], gh: real.gh, env: {} });
  assert.equal(r2.result.pending, 0);
  assert.equal(real.calls.filter((x) => x.method === 'PATCH').length, 1);
});

// ---------------------------------------------------------------- I4
function pmWorld(c, { issues = [], unreachable = false } = {}) {
  const mergedAt = new Date(Date.now() - 2 * 86400000).toISOString();
  const p = { number: 50, merged_at: mergedAt, base: { ref: 'main' }, head: { ref: 't/12-swagger', sha: 'sha50' },
    body: `Fixes acme/core#12\nCites: P-0-4@${'c'.repeat(12)}\n\nEvidence:\ndotnet test: ok\n` };
  if (unreachable) c.g('remote', 'set-url', 'origin', join(tmpdir(), 'devfw-ff-no-such-origin'));
  return {
    'GET repos/acme/api/pulls?state=closed': [p], 'GET repos/acme/mobile/pulls?state=closed': [],
    'GET repos/acme/core/issues/12/comments': [],
    'GET repos/acme/core/issues/12': { number: 12, body: `- **Cites:** P-0-4@${'c'.repeat(12)}
` },
    'GET repos/acme/core/issues?state=all&labels=merged-stale': issues,
    'GET repos/acme/api/commits/sha50/check-runs': { total_count: 1, check_runs: [run_('b', 'success')] },
    'GET repos/acme/api/commits/sha50/status': { state: 'pending', statuses: [] },
    [`GET repos/acme/core/commits?sha=main&until=${mergedAt}&per_page=1`]: [{ sha: c.sha }],
  };
}
const msIssue = (title, state) => ({ number: 90, title, state, labels: [{ name: 'merged-stale' }] });

for (const [kind, unreachable] of [['merged-stale', false], ['merged-unverifiable', true]]) {
  test(`I4: a CLOSED ${kind} issue resolves the PR: no new issue, reported under resolved, exit 0`, () => {
    const c = core();
    for (const extra of [[], ['--apply']]) {
      const f = fakeGh(pmWorld(c, { issues: [msIssue(`${kind}: acme/api#50`, 'closed')], unreachable }));
      const r = reconcile.run({ argv: ['--core-dir', c.dir, '--post-merge', ...extra], gh: f.gh, env: {} });
      assert.equal(r.exitCode, 0, JSON.stringify(r.result));
      assert.deepEqual(r.result.staleMerges, []);
      assert.deepEqual(r.result.unverifiable, []);
      assert.deepEqual(r.result.resolved.map((x) => [x.repo, x.pr, x.issue]), [['acme/api', 50, 90]]);
      assert.equal(f.calls.filter((x) => x.method === 'POST').length, 0);
    }
  });
}

test('I4: an OPEN merged-stale issue is still reported (exit 9) and not duplicated; none at all creates one', () => {
  const c = core();
  const open = fakeGh(pmWorld(c, { issues: [msIssue('merged-stale: acme/api#50', 'open')] }));
  const r = reconcile.run({ argv: ['--core-dir', c.dir, '--post-merge', '--apply'], gh: open.gh, env: {} });
  assert.equal(r.exitCode, 9);
  assert.equal(r.result.staleMerges.length, 1);
  assert.equal(open.calls.filter((x) => x.method === 'POST').length, 0);
  const none = fakeGh(pmWorld(c));
  const r2 = reconcile.run({ argv: ['--core-dir', c.dir, '--post-merge', '--apply'], gh: none.gh, env: {} });
  assert.equal(r2.exitCode, 9);
  assert.deepEqual(none.calls.filter((x) => x.method === 'POST').map((x) => x.body.title), ['merged-stale: acme/api#50']);
});

test('I3: the fetch names its refspec, so origin/<branch> advances even with no remote.origin.fetch configured', () => {
  const { resolvePlanRef } = require('../../../lib/fetch-plan.js');
  const c = core();
  const config = loadConfig({ coreDir: c.dir, env: {} });
  c.g('config', '--unset-all', 'remote.origin.fetch');
  const up = upstreamEdit(c, 'PLAN.md', 'Expose a health endpoint.', 'Expose it upstream.');
  assert.equal(resolvePlanRef({ coreDir: c.dir, config }), 'origin/main');
  assert.equal(c.g('rev-parse', 'origin/main').trim(), up);
});

// ---------------------------------------------------------------- I2
function gateWorld(c, { n = 41, headRef = `t/${n}-swagger`, cites, issueCites, issueBody, noIssue = false } = {}) {
  const h = planHashes(c.dir, 'HEAD', CONFIG);
  const cur = (id) => `${id}@${h.get(id)}`;
  const prCites = cites ?? [cur('P-0-4'), cur('D-8'), cur('RL-7')].join(', ');
  const iss = issueBody ?? `- **Cites:** ${issueCites ?? [cur('P-0-4'), cur('D-8'), cur('RL-7')].join(', ')}\n`;
  const r = {
    'GET repos/acme/api/pulls/50': { number: 50, body: `Fixes acme/core#${n}\nCites: ${prCites}\n\nEvidence:\ndotnet test: 120 passed\n`, head: { sha: 'abc123', ref: headRef } },
    'GET repos/acme/api/commits/abc123/check-runs': { total_count: 1, check_runs: [run_('build', 'success')] },
    'GET repos/acme/api/commits/abc123/status': { state: 'pending', statuses: [] },
    'GET repos/acme/api/pulls/50/files': [{ filename: 'src/a.cs', additions: 10, deletions: 0, status: 'modified' }],
    [`GET repos/acme/core/issues/${n}/comments`]: [],
  };
  if (!noIssue) r[`GET repos/acme/core/issues/${n}`] = { number: n, state: 'open', body: iss };
  return { r, h };
}
const gateRun = (c, r) => gate.run({ argv: ['--core-dir', c.dir, '--repo', 'acme/api', '--pr', '50'], gh: fakeGh(r).gh, env: {} });

test('I2: positive control - head t/41-…, Fixes acme/core#41, cites cover the issue: pass', () => {
  const c = core();
  const out = gateRun(c, gateWorld(c).r);
  assert.equal(out.exitCode, 0, JSON.stringify(out.result));
});

test('I2: Fixes acme/core#41 on head t/42-x refuses', () => {
  const c = core();
  const out = gateRun(c, gateWorld(c, { headRef: 't/42-x' }).r);
  assert.equal(out.exitCode, 6);
  assert.ok(out.result.reasons.some((x) => /head branch "t\/42-x"/.test(x) && /#41/.test(x)), out.result.reasons.join(' | '));
  assert.equal(gateRun(c, gateWorld(c, { headRef: 't/410-x' }).r).exitCode, 6, 't/410- is not t/41-');
  assert.equal(gateRun(c, gateWorld(c, { headRef: 'feature/t/41-x' }).r).exitCode, 6);
});

test('I2: the PR cites only D-8 while issue #41 cites P-0-4 and D-8: refuse, naming P-0-4', () => {
  const c = core();
  const { h } = gateWorld(c);
  const out = gateRun(c, gateWorld(c, { cites: `D-8@${h.get('D-8')}`, issueCites: `P-0-4@${h.get('P-0-4')}, D-8@${h.get('D-8')}` }).r);
  assert.equal(out.exitCode, 6);
  assert.ok(out.result.reasons.some((x) => /does not cite P-0-4/.test(x) && !/D-8/.test(x)), out.result.reasons.join(' | '));
});

test('I2: the linked issue unreadable, or without a Cites line, refuses (fail closed)', () => {
  const c = core();
  const gone = gateRun(c, gateWorld(c, { noIssue: true }).r);
  assert.equal(gone.exitCode, 6);
  assert.ok(gone.result.reasons.some((x) => /cannot read issue acme\/core#41/.test(x)), gone.result.reasons.join(' | '));
  const bare = gateRun(c, gateWorld(c, { issueBody: 'someone deleted the Cites line\n' }).r);
  assert.equal(bare.exitCode, 6);
  assert.ok(bare.result.reasons.some((x) => /issue #41 has no Cites/.test(x)), bare.result.reasons.join(' | '));
});

test('I2: duplicate IDs carrying different hashes refuse (P-0-4@stale, P-0-4@current)', () => {
  const c = core();
  const { h } = gateWorld(c);
  const dup = `P-0-4@${'f'.repeat(12)}, P-0-4@${h.get('P-0-4')}, D-8@${h.get('D-8')}, RL-7@${h.get('RL-7')}`;
  const out = gateRun(c, gateWorld(c, { cites: dup }).r);
  assert.equal(out.exitCode, 6);
  assert.ok(out.result.reasons.some((x) => /P-0-4 is cited with different hashes/.test(x)), out.result.reasons.join(' | '));
  // the same order reversed: the last one no longer silently wins
  const rev = `P-0-4@${h.get('P-0-4')}, P-0-4@${'f'.repeat(12)}, D-8@${h.get('D-8')}, RL-7@${h.get('RL-7')}`;
  assert.equal(gateRun(c, gateWorld(c, { cites: rev }).r).exitCode, 6);
  const { parseCitesStrict } = require('../../../lib/ticket-body.js');
  const same = parseCitesStrict(`Cites: P-0-4@${'a'.repeat(12)}, P-0-4@${'a'.repeat(12)}`);
  assert.deepEqual(same.conflicts, [], 'a repeated identical entry is not a conflict');
});

// ---------------------------------------------------------------- I8
test('I8: a cited ID removed from the plan is needs-ack in reconcile and a refusal in the gate (same input)', () => {
  const c = core();
  const h0 = planHashes(c.dir, 'HEAD', CONFIG);
  const issueBody = bodyOf(c.dir, 'P-0-4'); // cites P-0-4, D-8, RL-7 at their current hashes
  // RL-7 is removed from RULINGS.md; PLAN.md is untouched, so P-0-4 and D-8 keep their hashes.
  writeFileSync(join(c.dir, 'docs/plan/RULINGS.md'), '# R\n');
  c.g('commit', '-qam', 'remove RL-7'); c.g('push', '-q', 'origin', 'main');
  const removedAt = c.g('rev-parse', 'HEAD').trim();
  const h1 = planHashes(c.dir, 'HEAD', CONFIG);
  assert.equal(h1.get('P-0-4'), h0.get('P-0-4'), 'seed: P-0-4 unchanged');
  assert.equal(h1.has('RL-7'), false, 'seed: RL-7 gone');

  const rc = (comments) => reconcile.run({
    argv: ['--core-dir', c.dir, '--ref', 'HEAD'],
    gh: fakeGh({
      'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-4', issueBody)],
      [SINCE]: comments,
      'GET repos/acme/api/git/matching-refs/heads/t/': [], 'GET repos/acme/api/pulls?state=all': [],
    }).gh,
    env: {},
  });
  const r = stateOf(rc([]), 'P-0-4');
  assert.equal(r.state, 'needs-ack');
  assert.match(r.why, /RL-7 removed from plan/);
  // An ack at the plan where RL-7 no longer exists cannot cover it.
  const acked = stateOf(rc([{ issue_url: 'https://api.github.com/repos/acme/core/issues/41', body: `ack 41 ${removedAt}: fine`, author_association: 'OWNER' }]), 'P-0-4');
  assert.equal(acked.state, 'needs-ack');

  const cites = `P-0-4@${h0.get('P-0-4')}, D-8@${h0.get('D-8')}, RL-7@${h0.get('RL-7')}`;
  const g = gateRun(c, gateWorld(c, { cites, issueCites: cites }).r);
  assert.equal(g.exitCode, 6);
  assert.ok(g.result.reasons.includes('cites: RL-7 is not in the plan'), g.result.reasons.join(' | '));
});

// ---------------------------------------------------------------- I9
function tsWorld(c, p4Body) {
  const nums = new Map([['P-0-3', 1], ['P-0-4', 2], ['P-0-5', 3]]);
  const config = loadConfig({ coreDir: c.dir, env: {} });
  const items = parsePlan(fixture, config);
  const hashes = planHashes(c.dir, 'HEAD', config);
  const body = (id) => renderBody(items.find((i) => i.id === id), { hashes, issueNumbers: nums, planSha: c.sha, config });
  const bodies = { 'P-0-3': body('P-0-3'), 'P-0-4': p4Body(body('P-0-4'), hashes), 'P-0-5': body('P-0-5') };
  return { hashes, issues: [...nums].map(([id, n]) => issue(n, id, bodies[id])) };
}
const dropCitesLine = (b) => b.split('\n').filter((l) => !l.startsWith('- **Cites:**')).join('\n');
const dropD8 = (b, h) => b.replace(`, D-8@${h.get('D-8')}`, '');

test('I9: an existing issue whose Cites line was deleted: --check reports citesMissing; --apply writes no current hash', () => {
  const c = core();
  const w = tsWorld(c, dropCitesLine);
  const dry = ticketSync.run({ argv: ['--core-dir', c.dir, '--ref', 'HEAD'], gh: fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': w.issues }).gh, env: {} });
  assert.equal(dry.exitCode, 7);
  assert.deepEqual(dry.result.citesMissing, [{ issue: 2, ids: ['P-0-4', 'D-8', 'RL-7'] }]);
  const f = fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': w.issues });
  ticketSync.run({ argv: ['--core-dir', c.dir, '--ref', 'HEAD', '--apply'], gh: f.gh, env: {} });
  for (const p of f.calls.filter((x) => x.method === 'PATCH')) {
    for (const id of ['P-0-4', 'D-8', 'RL-7']) assert.ok(!p.body.body.includes(`${id}@${w.hashes.get(id)}`), `${id} got the current hash silently`);
  }
});

test('I9: one ID deleted from the Cites line: the rewrite keeps the line without it; only --refresh-cites restores it', () => {
  const c = core();
  const w = tsWorld(c, dropD8);
  const dry = ticketSync.run({ argv: ['--core-dir', c.dir, '--ref', 'HEAD'], gh: fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': w.issues }).gh, env: {} });
  assert.deepEqual(dry.result.citesMissing, [{ issue: 2, ids: ['D-8'] }]);
  assert.deepEqual(dry.result.drift, [], 'the line without D-8 is what the rewrite keeps');
  assert.equal(dry.exitCode, 7);
  const f = fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': w.issues });
  ticketSync.run({ argv: ['--core-dir', c.dir, '--ref', 'HEAD', '--apply'], gh: f.gh, env: {} });
  assert.equal(f.calls.filter((x) => x.method === 'PATCH').length, 0);
  const g = fakeGh({ ...TS_BASE, 'GET repos/acme/core/issues?state=all': w.issues });
  ticketSync.run({ argv: ['--core-dir', c.dir, '--ref', 'HEAD', '--apply', '--refresh-cites', 'P-0-4'], gh: g.gh, env: {} });
  const patch = g.calls.find((x) => x.method === 'PATCH');
  assert.ok(patch && patch.body.body.includes(`D-8@${w.hashes.get('D-8')}`));
});

test('I9: reconcile shows needs-ack for an issue whose Cites line lacks an ID', () => {
  const c = core();
  for (const [fn, re] of [[dropCitesLine, /P-0-4 missing from Cites/], [dropD8, /D-8 missing from Cites/]]) {
    const w = tsWorld(c, fn);
    const r = reconcile.run({
      argv: ['--core-dir', c.dir, '--ref', 'HEAD'],
      gh: fakeGh({ 'GET repos/acme/core/issues?state=all': w.issues.map((x) => ({ ...x, created_at: '2026-11-01T00:00:00Z' })), [SINCE]: [],
        'GET repos/acme/api/git/matching-refs/heads/t/': [], 'GET repos/acme/api/pulls?state=all': [],
        'GET repos/acme/mobile/git/matching-refs/heads/t/': [], 'GET repos/acme/mobile/pulls?state=all': [] }).gh,
      env: {},
    });
    const s = stateOf(r, 'P-0-4');
    assert.equal(s.state, 'needs-ack', fn.name);
    assert.match(s.why, re);
    assert.notEqual(stateOf(r, 'P-0-3').state, 'needs-ack', 'a complete Cites line is not affected');
  }
});

// ---------------------------------------------------------------- I7
const newTicket = require('../../../lib/new-ticket.js');
const NT_CFG = { ...CONFIG, repos: { 'acme-api': CONFIG.repos['acme-api'] }, stages: { A: 'Stage A — Gates' } };
const NT_TOKEN = '00000000000000aa';
const ntItem = (id, title) => `### ${id} · ${title}\n- stage: A\n- kind: code\n- state: ready\n- area: acme-api — \`src/x.cs\`\n- depends: —\n- decisions: —\n- ticket: —\n\nBody of ${id}.\n`;
const NT_PLAN = ['# Plan', '', '## P-3 · Epic three', '', ntItem('P-3-1', 'First'), ntItem('P-3-2', 'Second'), '## P-4 · Epic four', '', ntItem('P-4-1', 'Other'), ''].join('\n');

function ntCore() {
  const c = core({ config: NT_CFG, plan: NT_PLAN });
  writeFileSync(join(c.dir, '.gitignore'), '.orchestrator/\n');
  c.g('add', '-A'); c.g('commit', '-qm', 'ignore'); c.g('push', '-q', 'origin', 'main');
  mkdirSync(join(c.dir, '.orchestrator'), { recursive: true });
  writeFileSync(join(c.dir, '.orchestrator/lease'), NT_TOKEN + '\n');
  const bf = join(mkdtempSync(join(tmpdir(), 'devfw-ff-body-')), 'b.md');
  writeFileSync(bf, 'Do the new thing.\n');
  const argv = ['--core-dir', c.dir, '--epic', '3', '--title', 'New thing', '--area', 'acme-api — `src/new.cs`', '--kind', 'code', '--stage', 'A', '--body-file', bf, '--apply'];
  return { ...c, argv, bf };
}

// A GitHub that merges the plan PR by moving origin/main to the pushed branch.
function ntGh(c, branch) {
  const { gh, calls } = fakeGh({
    'POST repos/acme/core/pulls': { number: 7 },
    'GET repos/acme/core/pulls/7/files': [{ filename: 'docs/plan/PLAN.md' }],
    'GET repos/acme/core/issues?state=all': [],
    ...Object.fromEntries([1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => [`GET repos/acme/core/issues?labels=plan:P-3-${n}&state=all`, []])),
    'GET repos/acme/api/pulls?state=open': [],
    'GET repos/acme/core/issues/7/comments': [],
    'GET repos/acme/core/labels': [], 'GET repos/acme/core/milestones?state=all': [],
    'POST repos/acme/core/issues': { number: 99 }, 'POST repos/acme/core/milestones': { number: 1 },
    get 'GET repos/acme/core/pulls/7'() {
      const base = execFileSync('git', ['-C', c.bare, 'rev-parse', 'refs/heads/main'], { encoding: 'utf8' }).trim();
      const head = execFileSync('git', ['-C', c.bare, 'rev-parse', `refs/heads/${branch}`], { encoding: 'utf8' }).trim();
      return { number: 7, body: `lease: ${NT_TOKEN}`, base: { sha: base }, head: { sha: head } };
    },
  });
  const wrapped = { ...gh, raw: (args, input) => {
    if (args[0] === 'pr' && args[1] === 'merge') {
      const sha = execFileSync('git', ['-C', c.bare, 'rev-parse', `refs/heads/${branch}`], { encoding: 'utf8' }).trim();
      execFileSync('git', ['-C', c.bare, 'update-ref', 'refs/heads/main', sha]);
    }
    return gh.raw(args, input);
  } };
  return { gh: wrapped, calls };
}

test('I7: a dirty PLAN.md refuses before anything: exit 2, no branch, no gh call', () => {
  const c = ntCore();
  const p = join(c.dir, 'docs/plan/PLAN.md');
  writeFileSync(p, readFileSync(p, 'utf8') + '\nlocal scribble\n');
  const { gh, calls } = fakeGh({});
  const out = newTicket.run({ argv: c.argv, gh, env: {} });
  assert.equal(out.exitCode, 2, JSON.stringify(out.result));
  assert.match(out.result.error, /dirty/);
  assert.equal(c.g('branch', '--list', 'plan/new-*').trim(), '');
  assert.equal(calls.length, 0);
  assert.match(readFileSync(p, 'utf8'), /local scribble/, 'the local edit is untouched');
});

test('I7: the committed PLAN.md is exactly the validated text (insertItem over the fetched tip), not the stale local file', () => {
  const c = ntCore();
  // origin moves on (another item P-3-5 lands upstream); the local clone is clean but behind.
  const other = mkdtempSync(join(tmpdir(), 'devfw-ff-nt-other-'));
  execFileSync('git', ['clone', '-q', '-c', 'core.autocrlf=false', '-b', 'main', c.bare, other]);
  const op = join(other, 'docs/plan/PLAN.md');
  writeFileSync(op, readFileSync(op, 'utf8').replace(ntItem('P-3-2', 'Second'), ntItem('P-3-2', 'Second') + '\n' + ntItem('P-3-5', 'Upstream')));
  execFileSync('git', ['-C', other, '-c', 'user.name=a', '-c', 'user.email=a@acme.test', 'commit', '-qam', 'upstream item']);
  execFileSync('git', ['-C', other, 'push', '-q', 'origin', 'main']);
  const tip = execFileSync('git', ['-C', other, 'show', 'HEAD:docs/plan/PLAN.md'], { encoding: 'utf8' });
  const expected = newTicket.insertItem(tip, { epic: '3', title: 'New thing', stage: 'A', kind: 'code', area: 'acme-api — `src/new.cs`', depends: '—', decisions: '—' }, 'P-3-6', 'Do the new thing.\n');
  const { gh } = ntGh(c, 'plan/new-P-3-6');
  const out = newTicket.run({ argv: c.argv, gh, env: {} });
  assert.equal(out.exitCode, 0, JSON.stringify(out.result));
  assert.equal(out.result.id, 'P-3-6');
  const committed = execFileSync('git', ['-C', c.bare, 'show', 'refs/heads/plan/new-P-3-6:docs/plan/PLAN.md'], { encoding: 'utf8' });
  assert.equal(committed, expected);
  assert.match(committed, /### P-3-5 · Upstream/);
});

test('I7: run from a detached HEAD, new-ticket returns to the same sha (still detached)', () => {
  const c = ntCore();
  c.g('checkout', '-q', '--detach', 'HEAD');
  const sha = c.g('rev-parse', 'HEAD').trim();
  const { gh } = ntGh(c, 'plan/new-P-3-3');
  const out = newTicket.run({ argv: c.argv, gh, env: {} });
  assert.equal(out.exitCode, 0, JSON.stringify(out.result));
  assert.equal(c.g('rev-parse', 'HEAD').trim(), sha);
  assert.throws(() => c.g('symbolic-ref', '-q', 'HEAD'), 'HEAD is still detached');
});

test('I7: run from a branch, new-ticket returns to that branch', () => {
  const c = ntCore();
  c.g('checkout', '-q', '-b', 'work');
  const { gh } = ntGh(c, 'plan/new-P-3-3');
  const out = newTicket.run({ argv: c.argv, gh, env: {} });
  assert.equal(out.exitCode, 0, JSON.stringify(out.result));
  assert.equal(c.g('symbolic-ref', '--short', 'HEAD').trim(), 'work');
});
