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
const { run } = require('../../../lib/impact.js');
const { parseLeaseLine } = require('../../../lib/lease.js');
const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(here, '../fixtures/PLAN-list.md'), 'utf8');

const CONFIG = {
  plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' },
  repos: {
    'acme-api': { github: 'acme/api', default: 'main', label: 'api', ci: 'required' },
    'acme-mobile': { github: 'acme/mobile', default: 'master', label: 'mobile', ci: 'none' },
  },
  ownerArea: 'owner',
  github: { writeDelayMs: 0 },
};
const LEASE = 'orchestrator: 00000000000000aa · box1 · since 2026-11-16T00:00:00Z';
const TOKEN = '00000000000000aa';
const DEC = '# D\n\n### D-1 · First\n- rule: a\n\n### D-8 · Eighth\n- rule: b\n\n### D-9 · Ninth\n- rule: z\n';

// Temp core repo: base commit, then edits to head. No remote (the fetch must tolerate that).
function coreRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'devfw-imp-'));
  const p = (f) => join(dir, 'docs/plan', f);
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify(CONFIG));
  writeFileSync(p('PLAN.md'), fixture);
  writeFileSync(p('DECISIONS.md'), DEC);
  writeFileSync(p('RULINGS.md'), '# R\n\n### RL-7 · Seventh\n- rule: c\n');
  writeFileSync(p('START-HERE.md'), LEASE + '\n\n# Start\n');
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 'a@acme.test'); g('config', 'user.name', 'a');
  g('add', '-A'); g('commit', '-qm', 'base');
  const base = g('rev-parse', 'HEAD').trim();
  const bare = mkdtempSync(join(tmpdir(), 'devfw-imp-origin-'));
  execFileSync('git', ['init', '-q', '--bare', bare]);
  g('remote', 'add', 'origin', bare); g('push', '-q', 'origin', 'main');
  g('checkout', '-q', '-b', 'pr');
  const edit = (file, from, to) => {
    const t = readFileSync(p(file), 'utf8');
    assert.ok(t.includes(from), `seed text missing: ${from}`);
    writeFileSync(p(file), t.replace(from, to));
  };
  const commit = () => { g('add', '-A'); g('commit', '-qm', 'head'); return g('rev-parse', 'HEAD').trim(); };
  // The plan branch moves on after the PR was opened (e.g. a handoff commit on main).
  const advanceMain = (file, from, to) => {
    g('checkout', '-q', 'main'); edit(file, from, to);
    g('add', '-A'); g('commit', '-qm', 'main moves'); g('push', '-q', 'origin', 'main'); g('checkout', '-q', 'pr');
  };
  return { dir, base, edit, commit, advanceMain };
}

const issue = (number, id, cites, state = 'open') => ({
  number, state, labels: [{ name: `plan:${id}` }, { name: 'repo:api' }],
  body: `- **Cites:** ${cites}\n`,
});
const H = (c) => c.repeat(12);

// A PR in acme/core #7 plus the standard open-issue world.
function world(core, head, { body = `lease: ${TOKEN}`, files = ['docs/plan/PLAN.md'], issues, comments = [], prs = [], refs = [] } = {}) {
  const issues_ = issues || [
    issue(11, 'P-0-3', `P-0-3@${H('a')}, D-1@${H('b')}`),
    issue(12, 'P-0-4', `P-0-4@${H('a')}, D-8@${H('b')}, RL-7@${H('c')}`),
    issue(13, 'P-0-5', `P-0-5@${H('a')}`),
  ];
  return {
    'GET repos/acme/core/pulls/7': { number: 7, body, base: { sha: core.base }, head: { sha: head } },
    'GET repos/acme/core/pulls/7/files': files.map((filename) => ({ filename })),
    'GET repos/acme/core/issues?state=all': issues_,
    'GET repos/acme/core/issues/7/comments': comments,
    'GET repos/acme/api/pulls?state=open': prs,
    'GET repos/acme/mobile/pulls?state=open': [],
    'GET repos/acme/api/git/matching-refs/heads/t/': refs,
    'GET repos/acme/mobile/git/matching-refs/heads/t/': [],
  };
}

const go = (core, routes, extra = []) => {
  const { gh, calls } = fakeGh(routes);
  const out = run({ argv: ['--core-dir', core.dir, '--pr', '7', ...extra], gh, env: {} });
  return { ...out, calls };
};
const writes = (calls) => calls.filter((c) => c.method !== 'GET');

test('parseLeaseLine: plan 1 format', () => {
  assert.deepEqual(parseLeaseLine(LEASE + '\r'), { token: TOKEN, machine: 'box1', since: '2026-11-16T00:00:00Z' });
  assert.equal(parseLeaseLine('orchestrator: nothex · box · since 2026-11-16T00:00:00Z'), null);
  assert.equal(parseLeaseLine('# Start'), null);
});

test('typo-free edit: only the edited item is changed, siblings are not affected', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger in every production build.');
  const head = core.commit();
  const { exitCode, result } = go(core, world(core, head));
  assert.deepEqual(result.changed, ['P-0-4']);
  assert.deepEqual(result.affected.map((a) => [a.issue, a.kind]), [[12, 'issue']]);
  assert.deepEqual(result.violations, []);
  assert.equal(result.pending, 1);
  assert.equal(exitCode, 8);
});

test('decision edit: every open issue citing it is affected, closed ones are not', () => {
  const core = coreRepo();
  core.edit('DECISIONS.md', 'rule: b', 'rule: b2');
  const head = core.commit();
  const issues = [
    issue(11, 'P-0-3', `P-0-3@${H('a')}, D-1@${H('b')}`),
    issue(12, 'P-0-4', `P-0-4@${H('a')}, D-8@${H('b')}`),
    issue(14, 'P-0-9', `P-0-9@${H('a')}, D-8@${H('b')}`),
    issue(15, 'P-0-8', `P-0-8@${H('a')}, D-8@${H('b')}`, 'closed'),
  ];
  const { result } = go(core, world(core, head, { issues }));
  assert.ok(result.changed.includes('D-8'));
  assert.deepEqual(result.affected.filter((a) => a.kind === 'issue').map((a) => a.issue), [12, 14]);
  assert.deepEqual(result.affected[0].ids, ['D-8']);
  // A decision rewrite is also an append-only violation.
  assert.deepEqual(result.violations, ['decision-edited:D-8']);
});

test('open PRs and claim branches of affected issues are listed', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger in every production build.');
  const head = core.commit();
  const prs = [
    { number: 40, body: `Cites: P-0-4@${H('a')}`, head: { ref: 't/12-swagger' } },
    { number: 41, body: `Cites: P-0-3@${H('a')}`, head: { ref: 't/11-health' } },
  ];
  const refs = [{ ref: 'refs/heads/t/12-swagger' }, { ref: 'refs/heads/t/11-health' }];
  const { result } = go(core, world(core, head, { prs, refs }));
  const by = (k) => result.affected.filter((a) => a.kind === k);
  assert.deepEqual(by('pr').map((a) => a.issue), [40]);
  assert.deepEqual(by('branch').map((a) => a.issue), [12]);
});

test('append-only: rewording an old decision is a violation, superseded-by alone is not', () => {
  const a = coreRepo();
  a.edit('DECISIONS.md', 'rule: b', 'rule: b reworded');
  const r1 = go(a, world(a, a.commit())).result;
  assert.deepEqual(r1.violations, ['decision-edited:D-8']);

  const b = coreRepo();
  b.edit('DECISIONS.md', 'rule: b\n', 'rule: b\n- superseded-by: D-12\n');
  const r2 = go(b, world(b, b.commit())).result;
  assert.deepEqual(r2.violations, []);

  // Changing an already-present superseded-by line is an edit.
  const c = coreRepo();
  c.edit('DECISIONS.md', 'rule: b\n', 'rule: b\n- superseded-by: D-12\n');
  const mid = c.commit();
  c.edit('DECISIONS.md', 'D-12', 'D-13');
  const head = c.commit();
  const core = { ...c, base: mid };
  assert.deepEqual(go(core, world(core, head)).result.violations, ['decision-edited:D-8']);
});

test('lease: missing or wrong lease is a violation; a START-HERE handoff is exempt', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger everywhere.');
  const head = core.commit();
  assert.deepEqual(go(core, world(core, head, { body: 'no token here' })).result.violations, ['lease-missing']);
  assert.deepEqual(go(core, world(core, head, { body: 'lease: 00000000000000bb' })).result.violations, ['lease-mismatch']);
  assert.deepEqual(go(core, world(core, head)).result.violations, []);

  const h = coreRepo();
  h.edit('START-HERE.md', LEASE, 'orchestrator: 00000000000000cc · box2 · since 2026-11-17T00:00:00Z');
  const hh = h.commit();
  const r = go(h, world(h, hh, { body: 'handoff', files: ['docs/plan/START-HERE.md'] })).result;
  assert.deepEqual(r.violations, []);
});

test('--apply twice: one POST then one PATCH, ticked box survives, status follows the boxes', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Expose a health endpoint.', 'Expose a health endpoint and a ping.');
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger everywhere.');
  const head = core.commit();
  const first = go(core, world(core, head), ['--apply']);
  const posts = writes(first.calls).filter((c) => c.method === 'POST' && c.path === 'repos/acme/core/issues/7/comments');
  assert.equal(posts.length, 1);
  const text = posts[0].body.body;
  assert.equal(text.split('\n')[0], '<!-- devfw:impact -->');
  assert.match(text, /- \[ \] #11 \(P-0-3@[0-9a-f]{12}\)/);
  assert.match(text, /- \[ \] #12 \(P-0-4@[0-9a-f]{12}\)/);
  const st = writes(first.calls).find((c) => c.path === `repos/acme/core/statuses/${head}`);
  assert.equal(st.body.state, 'failure');
  assert.equal(st.body.context, 'devfw/plan-impact');
  assert.ok(st.body.description);

  // Second run: the comment exists with #11 ticked.
  const ticked = text.replace('- [ ] #11', '- [x] #11');
  const existing = [{ id: 900, body: 'unrelated' }, { id: 901, body: ticked }];
  const second = go(core, world(core, head, { comments: existing }), ['--apply']);
  const w2 = writes(second.calls);
  assert.equal(w2.filter((c) => c.method === 'POST' && c.path.endsWith('/comments')).length, 0);
  const patch = w2.filter((c) => c.method === 'PATCH');
  assert.equal(patch.length, 1);
  assert.equal(patch[0].path, 'repos/acme/core/issues/comments/901');
  assert.match(patch[0].body.body, /- \[x\] #11/);
  assert.match(patch[0].body.body, /- \[ \] #12 \(P-0-4@/);
  assert.equal(second.result.pending, 1);
  assert.equal(w2.find((c) => c.path.includes('/statuses/')).body.state, 'failure');
});

test('commit status: success when every box is ticked and nothing violates', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger everywhere.');
  const head = core.commit();
  const first = go(core, world(core, head), ['--apply']);
  const body = writes(first.calls).find((c) => c.path.endsWith('/comments')).body.body;
  const existing = [{ id: 901, body: body.replace('- [ ]', '- [x]') }];
  const { exitCode, result, calls } = go(core, world(core, head, { comments: existing }), ['--apply']);
  assert.equal(result.pending, 0);
  assert.equal(exitCode, 0);
  assert.equal(writes(calls).find((c) => c.path.includes('/statuses/')).body.state, 'success');
});

test('dry run writes nothing', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger everywhere.');
  const head = core.commit();
  assert.deepEqual(writes(go(core, world(core, head)).calls), []);
});

test('fix1: lease is checked against the LIVE tip of the plan branch, not the PR base', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger everywhere.');
  const head = core.commit();
  core.advanceMain('START-HERE.md', LEASE, 'orchestrator: 00000000000000bb · box2 · since 2026-11-17T00:00:00Z');
  assert.deepEqual(go(core, world(core, head, { body: `lease: ${TOKEN}` })).result.violations, ['lease-mismatch']);
  assert.deepEqual(go(core, world(core, head, { body: 'lease: 00000000000000bb' })).result.violations, []);
});

test('fix2: a tick holds only for the exact (ID, hash) set it was made for', () => {
  const core = coreRepo();
  core.edit('PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger everywhere.');
  const head1 = core.commit();
  const first = go(core, world(core, head1), ['--apply']);
  const text = writes(first.calls).find((c) => c.path.endsWith('/comments')).body.body;
  const ticked = text.replace('- [ ]', '- [x]');
  const same = go(core, world(core, head1, { comments: [{ id: 901, body: ticked }] }));
  assert.equal(same.result.pending, 0);

  core.edit('DECISIONS.md', 'rule: b\n', 'rule: b\n- superseded-by: D-12\n');
  const head2 = core.commit();
  const second = go(core, world(core, head2, { comments: [{ id: 901, body: ticked }] }), ['--apply']);
  assert.deepEqual(second.result.violations, []);
  assert.deepEqual(second.result.affected[0].ids, ['D-8', 'P-0-4']);
  assert.equal(second.result.pending, 1);
  const w = writes(second.calls);
  assert.match(w.find((c) => c.method === 'PATCH').body.body, /- \[ \] #12 \(D-8@[0-9a-f]{12}, P-0-4@[0-9a-f]{12}\)/);
  assert.equal(w.find((c) => c.path.includes('/statuses/')).body.state, 'failure');
});

test('fix3: a handoff must leave a valid lease line with a new token', () => {
  const core = coreRepo();
  core.edit('START-HERE.md', LEASE, 'orchestrator: whatever');
  const head = core.commit();
  const r = go(core, world(core, head, { body: 'no lease', files: ['docs/plan/START-HERE.md'] })).result;
  assert.deepEqual(r.violations, ['lease-line-invalid']);
  // A valid line carrying the SAME token as live is not a handoff either.
  const same = coreRepo();
  same.edit('START-HERE.md', 'box1', 'box9');
  const hs = same.commit();
  assert.deepEqual(go(same, world(same, hs, { body: 'no lease', files: ['docs/plan/START-HERE.md'] })).result.violations, ['lease-missing']);
});
