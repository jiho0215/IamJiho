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
const { deriveState } = require('../../../lib/state.js');
const { renderBody } = require('../../../lib/ticket-body.js');
const { parsePlan, planHashes } = require('../../../lib/plan.js');
const { loadConfig } = require('../../../lib/config.js');
const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(here, '../fixtures/PLAN-list.md'), 'utf8');

const CONFIG = {
  plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' },
  repos: {
    'acme-api': { github: 'acme/api', default: 'main', label: 'api', ci: 'required' },
    'acme-mobile': { github: 'acme/mobile', default: 'master', label: 'mobile', ci: 'none', tests: ['npm test'] },
  },
  ownerArea: 'owner',
  stages: { A: 'Stage A — Gates', later: 'Post-launch' },
  github: { writeDelayMs: 0 },
};

function coreRepo(planText = fixture) {
  const dir = mkdtempSync(join(tmpdir(), 'devfw-rc-'));
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify(CONFIG));
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), planText);
  writeFileSync(join(dir, 'docs/plan/DECISIONS.md'), '# D\n\n### D-1 · First\n- rule: a\n\n### D-8 · Eighth\n- rule: b\n');
  writeFileSync(join(dir, 'docs/plan/RULINGS.md'), '# R\n\n### RL-7 · Seventh\n- rule: c\n');
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 'a@acme.test'); g('config', 'user.name', 'a');
  g('add', '-A'); g('commit', '-qm', 'plan');
  const commit = (text, msg) => {
    writeFileSync(join(dir, 'docs/plan/PLAN.md'), text); g('add', '-A'); g('commit', '-qm', msg);
    return g('rev-parse', 'HEAD').trim();
  };
  const edit = (file, from, to, msg = 'edit') => {
    const p = join(dir, 'docs/plan', file);
    const t = readFileSync(p, 'utf8');
    assert.ok(t.includes(from), `seed text missing: ${from}`);
    writeFileSync(p, t.replace(from, to)); g('add', '-A'); g('commit', '-qm', msg);
    return g('rev-parse', 'HEAD').trim();
  };
  return { dir, sha: g('rev-parse', 'HEAD').trim(), commit, edit };
}

// Body of the issue as ticket-sync wrote it at the plan's HEAD.
function bodyOf(dir, id, ref = 'HEAD') {
  const config = loadConfig({ coreDir: dir, env: {} });
  const text = execFileSync('git', ['-C', dir, 'show', `${ref}:docs/plan/PLAN.md`], { encoding: 'utf8' });
  const items = parsePlan(text, config);
  return renderBody(items.find((i) => i.id === id), { hashes: planHashes(dir, ref, config), issueNumbers: new Map(), planSha: ref, config });
}
const issue = (n, id, body, labels = [], state = 'open') => ({
  number: n, state, body, title: id, created_at: '2026-11-01T00:00:00Z',
  labels: [{ name: `plan:${id}` }, ...labels.map((name) => ({ name }))],
});
const comment = (n, body) => ({ issue_url: `https://api.github.com/repos/acme/core/issues/${n}`, body, author_association: 'OWNER' });
const SINCE = 'GET repos/acme/core/issues/comments?since=2026-11-01T00:00:00Z';
const argv = (dir, ...more) => ['--core-dir', dir, '--ref', 'HEAD', ...more];
const pr = (head, over = {}) => ({ number: 7, state: 'open', merged_at: null, head: { ref: head }, base: { ref: 'main' }, ...over });
const stateOf = (r, id) => r.result.items.find((i) => i.id === id).state;
const quiet = { 'GET repos/acme/api/git/matching-refs/heads/t/': [], 'GET repos/acme/api/pulls?state=all': [] };

// ---- deriveState: one row each, with seeds where only that row applies ----
const item = (deps = [], state = 'ready') => ({ id: 'P-0-4', deps, fields: { state } });
const stale = { cites: new Map([['P-0-4', 'aaaaaaaaaaaa']]), current: new Map([['P-0-4', 'bbbbbbbbbbbb']]), acked: new Set() };

test('deriveState: each row alone', () => {
  assert.equal(deriveState(item(), { mergedPr: { number: 1 } }).state, 'done');
  assert.equal(deriveState(item(), stale).state, 'needs-ack');
  assert.equal(deriveState(item(), { openPr: { number: 2 } }).state, 'in-review');
  assert.equal(deriveState(item(), { branch: 't/41-x' }).state, 'in-progress');
  assert.equal(deriveState(item(['P-0-3']), { depStates: new Map([['P-0-3', 'ready']]) }).state, 'blocked');
  assert.equal(deriveState(item(['P-0-3']), { depStates: new Map([['P-0-3', 'done']]) }).state, 'ready');
  assert.equal(deriveState(item([], 'later'), {}).state, 'later');
  assert.equal(deriveState(item([], 'owner'), {}).state, 'owner');
});

test('deriveState: precedence', () => {
  assert.equal(deriveState(item(), { ...stale, mergedPr: { number: 1 }, openPr: { number: 2 } }).state, 'done');
  assert.equal(deriveState(item(), { ...stale, openPr: { number: 2 }, branch: 't/41-x' }).state, 'needs-ack');
  assert.equal(deriveState(item(), { openPr: { number: 2 }, branch: 't/41-x' }).state, 'in-review');
  assert.equal(deriveState(item(['P-0-3']), { branch: 't/41-x', depStates: new Map() }).state, 'in-progress');
});

test('deriveState: a cited hash is stale only while its ID is unacked; every cited ID counts', () => {
  assert.equal(deriveState(item(), { ...stale, acked: new Set(['P-0-4']) }).state, 'ready');
  assert.equal(deriveState(item(), { cites: new Map([['P-0-4', 'bbbbbbbbbbbb']]), current: new Map([['P-0-4', 'bbbbbbbbbbbb']]) }).state, 'ready');
  const dec = { cites: new Map([['P-0-4', 'a1'], ['D-8', 'd1']]), current: new Map([['P-0-4', 'a1'], ['D-8', 'd2']]), acked: new Set() };
  const r = deriveState(item(), dec);
  assert.equal(r.state, 'needs-ack');
  assert.match(r.why, /D-8/);
  assert.equal(deriveState(item(), { ...dec, acked: new Set(['D-8']) }).state, 'ready');
});

// ---- reconcile end to end ----
test('needs-ack: stale cite; ack at the new plan clears; an ack resolving to the OLD hash does not', () => {
  const c = coreRepo();
  const oldBody = bodyOf(c.dir, 'P-0-3');
  const newSha = c.commit(fixture.replace('Expose a health endpoint.', 'Expose a health endpoint and a readiness one.'), 'plan edit');
  const go = (comments) => run({
    argv: argv(c.dir),
    gh: fakeGh({ 'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', oldBody, ['state:ready'])], [SINCE]: comments, ...quiet }).gh,
    env: {},
  });
  assert.equal(stateOf(go([]), 'P-0-3'), 'needs-ack');
  // Discriminating: the ack's sha resolves to the hash the issue ALREADY cites.
  assert.equal(stateOf(go([comment(41, `ack 41 ${c.sha}: no impact`)]), 'P-0-3'), 'needs-ack');
  // Ack line naming another issue number, ack posted on another issue, ack not on the first line.
  assert.equal(stateOf(go([comment(41, `ack 99 ${newSha}: no impact`)]), 'P-0-3'), 'needs-ack');
  assert.equal(stateOf(go([comment(77, `ack 41 ${newSha}: no impact`)]), 'P-0-3'), 'needs-ack');
  assert.equal(stateOf(go([comment(41, `hmm\nack 41 ${newSha}: no impact`)]), 'P-0-3'), 'needs-ack');
  const ok = go([comment(41, `ack 41 ${newSha}: no impact`)]);
  assert.equal(stateOf(ok, 'P-0-3'), 'ready');
  assert.equal(ok.exitCode, 0);
});

test('--apply: state:ready -> state:in-progress is one DELETE + one POST; a done item with an open issue is closed', () => {
  const c = coreRepo();
  const b = (id) => bodyOf(c.dir, id);
  const { gh, calls } = fakeGh({
    'GET repos/acme/core/issues?state=all': [
      issue(41, 'P-0-3', b('P-0-3'), ['state:ready']),
      issue(42, 'P-0-4', b('P-0-4'), ['state:ready']),
      issue(43, 'P-0-5', b('P-0-5'), ['state:ready']),
    ],
    [SINCE]: [],
    'GET repos/acme/api/git/matching-refs/heads/t/': [{ ref: 'refs/heads/t/41-health' }, { ref: 'refs/heads/t/42-swagger' }],
    'GET repos/acme/api/pulls?state=all': [pr('t/42-swagger', { number: 9, merged_at: '2026-11-02T00:00:00Z', state: 'closed' })],
    'GET repos/acme/mobile/git/matching-refs/heads/t/': [], 'GET repos/acme/mobile/pulls?state=all': [],
  });
  const dry = run({ argv: argv(c.dir), gh, env: {} });
  assert.deepEqual(calls.filter((x) => x.method !== 'GET'), []);
  assert.deepEqual(dry.result.changes, [
    { issue: 41, from: 'ready', to: 'in-progress' },
    { issue: 42, from: 'ready', to: 'done' },
  ]);
  run({ argv: argv(c.dir, '--apply'), gh, env: {} });
  const w = calls.filter((x) => x.method !== 'GET');
  assert.deepEqual(w.filter((x) => x.path.startsWith('repos/acme/core/issues/41')).map((x) => [x.method, x.path, x.body]), [
    ['DELETE', 'repos/acme/core/issues/41/labels/state%3Aready', undefined],
    ['POST', 'repos/acme/core/issues/41/labels', { labels: ['state:in-progress'] }],
  ]);
  assert.deepEqual(w.filter((x) => x.method === 'PATCH').map((x) => [x.path, x.body]), [['repos/acme/core/issues/42', { state: 'closed' }]]);
});

test('--apply leaves non-state labels alone and writes nothing when already right', () => {
  const c = coreRepo();
  const { gh, calls } = fakeGh({
    'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', bodyOf(c.dir, 'P-0-3'), ['state:ready', 'repo:api', 'stage:A'])],
    [SINCE]: [], ...quiet,
  });
  const r = run({ argv: argv(c.dir, '--apply'), gh, env: {} });
  assert.deepEqual(r.result.changes, []);
  assert.deepEqual(calls.filter((x) => x.method !== 'GET'), []);
});

test('open PR beats branch; a merge into a non-default base is not done; non-t/ PRs are ignored', () => {
  const c = coreRepo();
  const { gh } = fakeGh({
    'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', bodyOf(c.dir, 'P-0-3')), issue(42, 'P-0-4', bodyOf(c.dir, 'P-0-4'))],
    [SINCE]: [],
    'GET repos/acme/api/git/matching-refs/heads/t/': [{ ref: 'refs/heads/t/41-health' }],
    'GET repos/acme/api/pulls?state=all': [
      pr('t/41-health'),
      pr('t/42-swagger', { number: 8, state: 'closed', merged_at: '2026-11-02T00:00:00Z', base: { ref: 't/41-health' } }),
      pr('feature/other', { number: 3, merged_at: '2026-11-02T00:00:00Z', state: 'closed' }),
    ],
  });
  const r = run({ argv: argv(c.dir), gh, env: {} });
  assert.equal(stateOf(r, 'P-0-3'), 'in-review');
  assert.equal(stateOf(r, 'P-0-4'), 'blocked');
});

test('facts are read once per repo, not once per item', () => {
  const c = coreRepo(fixture.replace(/acme-mobile/g, 'acme-api'));
  const b = (id) => bodyOf(c.dir, id);
  const fake = fakeGh({
    'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', b('P-0-3')), issue(42, 'P-0-4', b('P-0-4')), issue(43, 'P-0-5', b('P-0-5'))],
    [SINCE]: [], ...quiet,
  });
  // fakeGh records writes only, so count the reads at the paginate and api seams (matching-refs is one api read).
  const reads = [];
  const gh = {
    ...fake.gh,
    paginate: (p, o) => { reads.push(p); return fake.gh.paginate(p, o); },
    api: (m, p, b) => { if (m === 'GET') reads.push(p); return fake.gh.api(m, p, b); },
  };
  run({ argv: argv(c.dir), gh, env: {} });
  const n = (frag) => reads.filter((p) => p.includes(frag)).length;
  assert.equal(n('matching-refs'), 1);
  assert.equal(n('/pulls'), 1);
  assert.equal(n('issues/comments'), 1);
});

test('owner-area item: plan field, or done when its issue is closed; no repo facts read', () => {
  const plan = `${fixture}\n### P-0-6 · Rotate the signing key\n- stage: A\n- kind: owner\n- state: owner\n- area: owner — vault\n- depends: —\n- decisions: —\n- ticket: —\n\nDo it by hand.\n`;
  const c = coreRepo(plan);
  const mk = (st) => fakeGh({
    'GET repos/acme/core/issues?state=all': [issue(44, 'P-0-6', bodyOf(c.dir, 'P-0-6'), ['state:owner'], st)],
    [SINCE]: [],
  });
  const open = mk('open'); const closed = mk('closed');
  assert.equal(stateOf(run({ argv: argv(c.dir), gh: open.gh, env: {} }), 'P-0-6'), 'owner');
  assert.equal(stateOf(run({ argv: argv(c.dir), gh: closed.gh, env: {} }), 'P-0-6'), 'done');
  assert.ok(!open.calls.some((x) => x.path.includes('matching-refs')));
});

test('comments paginate: an ack on page 2 (after 100 other comments) still clears needs-ack', () => {
  const c = coreRepo();
  const oldBody = bodyOf(c.dir, 'P-0-3');
  const newSha = c.commit(fixture.replace('Expose a health endpoint.', 'Expose it differently.'), 'plan edit');
  const filler = Array.from({ length: 100 }, (_, i) => comment(900 + i, 'chatter'));
  const { gh } = fakeGh({
    'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', oldBody, ['state:ready'])],
    [SINCE]: { pages: [filler, [comment(41, `ack 41 ${newSha}: fine`)]] }, ...quiet,
  });
  assert.equal(stateOf(run({ argv: argv(c.dir), gh, env: {} }), 'P-0-3'), 'ready');
});

test('C: only decision D-8 edited on the plan: the issue citing D-8@old is needs-ack; an ack that resolves D-8 to current clears it', () => {
  const c = coreRepo();
  const oldBody = bodyOf(c.dir, 'P-0-4');
  const body3 = bodyOf(c.dir, 'P-0-3');
  const newSha = c.edit('DECISIONS.md', '- rule: b', '- rule: b changed', 'decision edit');
  const go = (comments) => run({
    argv: argv(c.dir),
    gh: fakeGh({ 'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', body3, ['state:ready']), issue(42, 'P-0-4', oldBody, ['state:ready'])], [SINCE]: comments, ...quiet }).gh,
    env: {},
  });
  const r = go([]);
  assert.equal(stateOf(r, 'P-0-4'), 'needs-ack');
  assert.match(r.result.items.find((i) => i.id === 'P-0-4').why, /D-8/);
  assert.equal(stateOf(r, 'P-0-3'), 'ready'); // cites D-1 only, untouched
  assert.equal(stateOf(go([comment(42, `ack 42 ${c.sha}: old`)]), 'P-0-4'), 'needs-ack');
  assert.equal(stateOf(go([comment(42, `ack 42 ${newSha}: no impact`)]), 'P-0-4'), 'blocked'); // falls to the next row: P-0-3 is not done
});

test('D: an ack whose sha resolves to an INTERMEDIATE hash (cited aaaa, ack bbbb, current cccc) does not clear needs-ack', () => {
  const c = coreRepo();
  const oldBody = bodyOf(c.dir, 'P-0-3'); // cites the first hash
  const midSha = c.commit(fixture.replace('Expose a health endpoint.', 'Expose a health endpoint, v2.'), 'second');
  const curSha = c.commit(fixture.replace('Expose a health endpoint.', 'Expose a health endpoint, v3.'), 'third');
  const go = (comments) => run({
    argv: argv(c.dir),
    gh: fakeGh({ 'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', oldBody, ['state:ready'])], [SINCE]: comments, ...quiet }).gh,
    env: {},
  });
  assert.equal(stateOf(go([comment(41, `ack 41 ${midSha}: v2 ok`)]), 'P-0-3'), 'needs-ack');
  assert.equal(stateOf(go([comment(41, 'ack 41 deadbee: unknown sha')]), 'P-0-3'), 'needs-ack');
  assert.equal(stateOf(go([comment(41, `ack 41 ${curSha}: ok`)]), 'P-0-3'), 'ready');
});

test('A: reconcile fetches origin before reading the plan, so a plan edit pushed after the clone is seen', () => {
  const c = coreRepo();
  const oldBody = bodyOf(c.dir, 'P-0-3');
  const sh = (cwd, ...a) => execFileSync('git', ['-C', cwd, ...a], { encoding: 'utf8' });
  const root = mkdtempSync(join(tmpdir(), 'devfw-fetch-'));
  const bare = join(root, 'origin.git'); const clone = join(root, 'core'); const other = join(root, 'other');
  execFileSync('git', ['clone', '-q', '--bare', c.dir, bare]);
  execFileSync('git', ['clone', '-q', bare, clone]);
  execFileSync('git', ['clone', '-q', bare, other]);
  sh(other, 'config', 'user.email', 'a@acme.test'); sh(other, 'config', 'user.name', 'a');
  const pf = join(other, 'docs/plan/PLAN.md');
  writeFileSync(pf, readFileSync(pf, 'utf8').replace('Expose a health endpoint.', 'Expose a health endpoint, edited upstream.'));
  sh(other, 'commit', '-qam', 'upstream edit'); sh(other, 'push', '-q', 'origin', 'main');
  const { gh } = fakeGh({ 'GET repos/acme/core/issues?state=all': [issue(41, 'P-0-3', oldBody, ['state:ready'])], [SINCE]: [], ...quiet });
  const r = run({ argv: ['--core-dir', clone], gh, env: {} }); // no --ref: default origin/<plan.branch>
  assert.equal(stateOf(r, 'P-0-3'), 'needs-ack');
});
