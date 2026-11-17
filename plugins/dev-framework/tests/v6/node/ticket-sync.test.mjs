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
const { run } = require('../../../lib/ticket-sync.js');
const { renderBody, parseCites } = require('../../../lib/ticket-body.js');
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
  stages: { A: 'Stage A — Gates', later: 'Post-launch' },
  project: { owner: 'acme', number: 1, fields: { Stage: 'stage', 'Lands in': 'repo', Kind: 'kind' } },
  github: { writeDelayMs: 0 },
};

function coreRepo(planText = fixture) {
  const dir = mkdtempSync(join(tmpdir(), 'devfw-ts-'));
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify(CONFIG));
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), planText);
  writeFileSync(join(dir, 'docs/plan/DECISIONS.md'), '# D\n\n### D-1 · First\n- rule: a\n\n### D-8 · Eighth\n- rule: b\n');
  writeFileSync(join(dir, 'docs/plan/RULINGS.md'), '# R\n\n### RL-7 · Seventh\n- rule: c\n');
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 'a@acme.test'); g('config', 'user.name', 'a');
  g('add', '-A'); g('commit', '-qm', 'plan');
  return { dir, sha: g('rev-parse', 'HEAD').trim() };
}

function ctx(dir) {
  const config = loadConfig({ coreDir: dir, env: {} });
  const items = parsePlan(readFileSync(join(dir, 'docs/plan/PLAN.md'), 'utf8'), config);
  const hashes = planHashes(dir, 'HEAD', config);
  return { config, items, hashes };
}
const bodyOf = (dir, id, numbers = new Map(), sha = 'abcdef0123') => {
  const { config, items, hashes } = ctx(dir);
  return renderBody(items.find((i) => i.id === id), { hashes, issueNumbers: numbers, planSha: sha, config });
};
const issue = (n, id, body, labels = []) => ({
  number: n, node_id: `I_${n}`, state: 'open', body, title: id,
  labels: [{ name: `plan:${id}` }, ...labels.map((name) => ({ name }))],
});
const base = { 'GET repos/acme/core/labels': [], 'GET repos/acme/core/milestones?state=all': [] };
const PROJ = { user: { projectV2: { id: 'PVT_1', fields: { nodes: [
  { id: 'F_stage', name: 'Stage', options: [{ id: 'O_A', name: 'Stage A — Gates' }] },
  { id: 'F_repo', name: 'Lands in', options: [{ id: 'O_api', name: 'api' }, { id: 'O_mobile', name: 'mobile' }] },
  { id: 'F_kind', name: 'Kind', options: [{ id: 'O_code', name: 'code' }] },
] }, items: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } } };

const POSTG = { addProjectV2ItemById: { item: { id: 'PI_x' } } };

// A tiny stateful GitHub for apply / idempotence tests.
function sim(seed = {}) {
  const st = { labels: [...(seed.labels || [])], milestones: [...(seed.milestones || [])], issues: [...(seed.issues || [])], items: [], calls: [], n: 100 };
  const w = (method, path, body) => st.calls.push({ method, path, body });
  const api = (method, path, body) => {
    if (method === 'POST' && path === 'repos/acme/core/labels') { w(method, path, body); st.labels.push({ name: body.name }); return {}; }
    if (method === 'POST' && path === 'repos/acme/core/milestones') { w(method, path, body); const m = { number: st.milestones.length + 1, title: body.title }; st.milestones.push(m); return m; }
    if (method === 'POST' && path === 'repos/acme/core/issues') {
      w(method, path, body);
      const i = { number: ++st.n, node_id: `I_${st.n}`, state: 'open', title: body.title, body: body.body, milestone: body.milestone, labels: body.labels.map((name) => ({ name })) };
      st.issues.push(i); return i;
    }
    const pm = /^repos\/acme\/core\/issues\/(\d+)$/.exec(path);
    if (method === 'PATCH' && pm) { w(method, path, body); Object.assign(st.issues.find((i) => i.number === Number(pm[1])), body); return {}; }
    throw new Error(`sim: ${method} ${path}`);
  };
  const paginate = (path) => {
    if (path === 'repos/acme/core/labels') return st.labels;
    if (path === 'repos/acme/core/milestones?state=all') return st.milestones;
    if (path === 'repos/acme/core/issues?state=all') return st.lagList ? [] : st.issues;
    const pl = /^repos\/acme\/core\/issues\?labels=(plan:[^&]+)&state=all$/.exec(path);
    if (pl) { st.perItemReads = (st.perItemReads || 0) + 1; return st.issues.filter((i) => i.labels.some((l) => l.name === pl[1])); }
    throw new Error(`sim: paginate ${path}`);
  };
  const graphql = (q, vars) => {
    if (/addProjectV2ItemById/.test(q)) {
      w('POST', 'graphql', { q, vars });
      const num = Number(vars.contentId.slice(2));
      const it = { id: `PI_${num}`, content: { number: num, repository: { nameWithOwner: 'acme/core' } }, fieldValues: { nodes: [] } };
      st.items.push(it); return { addProjectV2ItemById: { item: { id: it.id } } };
    }
    if (/updateProjectV2ItemFieldValue/.test(q)) {
      w('POST', 'graphql', { q, vars });
      const it = st.items.find((x) => x.id === vars.itemId);
      const f = PROJ.user.projectV2.fields.nodes.find((x) => x.id === vars.fieldId);
      const o = f.options.find((x) => x.id === vars.optionId);
      it.fieldValues.nodes = it.fieldValues.nodes.filter((v) => v.field.name !== f.name).concat([{ name: o.name, field: { name: f.name } }]);
      return {};
    }
    return { user: { projectV2: { ...PROJ.user.projectV2, items: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: st.items } } } };
  };
  return { gh: { api, paginate, graphql, raw: () => '' }, st };
}
const argv = (dir, ...more) => ['--core-dir', dir, '--ref', 'HEAD', ...more];

test('dry run against 0 issues: all 3 missing, exit 7, no writes', () => {
  const { dir } = coreRepo();
  const { gh, calls } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': [] });
  const r = run({ argv: argv(dir), gh, env: {} });
  assert.deepEqual(r.result.missing, ['P-0-3', 'P-0-4', 'P-0-5']);
  assert.equal(r.exitCode, 7);
  assert.deepEqual(calls.filter((c) => c.method !== 'GET'), []);
  assert.ok(r.result.labelsMissing.includes('plan:P-0-3') && r.result.labelsMissing.includes('repo:api'));
});

test('pagination: 103 existing plan issues over 2 pages; nothing missing, --apply creates 0 issues', () => {
  const { dir } = coreRepo();
  const ids = ['P-0-3', 'P-0-4', 'P-0-5'];
  const all = [];
  for (let k = 0; k < 100; k++) all.push(issue(1000 + k, `P-8-${k + 1}`, 'x'));
  ids.forEach((id, i) => all.push(issue(1 + i, id, bodyOf(dir, id, new Map(ids.map((d, j) => [d, 1 + j]))))));
  const { gh, calls } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': { pages: [all.slice(0, 100), all.slice(100)] }, 'GRAPHQL ProjectInfo': PROJ, 'POST graphql': POSTG });
  const dry = run({ argv: argv(dir), gh, env: {} });
  assert.deepEqual(dry.result.missing, []);
  assert.equal(dry.result.extra.length, 100);
  const ap = run({ argv: argv(dir, '--apply'), gh, env: {} });
  assert.equal(calls.filter((c) => c.method === 'POST' && c.path === 'repos/acme/core/issues').length, 0);
  assert.deepEqual(ap.result.created, []);
});

test('drift: extra line shows as "-" in diff; --apply sends exactly one PATCH equal to renderBody', () => {
  const { dir, sha } = coreRepo();
  const nums = new Map([['P-0-3', 1], ['P-0-4', 2], ['P-0-5', 3]]);
  const bodies = Object.fromEntries([...nums.keys()].map((id) => [id, bodyOf(dir, id, nums, sha)]));
  const edited = bodies['P-0-4'].replace('## Ack log', 'hand edit on github\n\n## Ack log');
  const issues = [issue(1, 'P-0-3', bodies['P-0-3']), issue(2, 'P-0-4', edited), issue(3, 'P-0-5', bodies['P-0-5'])];
  const { gh, calls } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': issues, 'GRAPHQL ProjectInfo': PROJ, 'POST graphql': POSTG });
  const dry = run({ argv: argv(dir), gh, env: {} });
  assert.equal(dry.exitCode, 7);
  assert.equal(dry.result.drift.length, 1);
  assert.equal(dry.result.drift[0].issue, 2);
  assert.ok(dry.result.drift[0].diff.split('\n').includes('-hand edit on github'));
  run({ argv: argv(dir, '--apply'), gh, env: {} });
  const patches = calls.filter((c) => c.method === 'PATCH');
  assert.equal(patches.length, 1);
  assert.equal(patches[0].path, 'repos/acme/core/issues/2');
  assert.equal(patches[0].body.body, bodies['P-0-4']);
});

test('extra: plan:P-9-9 reported, never closed', () => {
  const { dir } = coreRepo();
  const s = sim({ issues: [issue(9, 'P-9-9', 'old')] });
  const r = run({ argv: argv(dir, '--apply'), gh: s.gh, env: {} });
  assert.deepEqual(r.result.extra, [9]);
  assert.ok(!s.st.calls.some((c) => c.path === 'repos/acme/core/issues/9'));
  assert.equal(s.st.issues.find((i) => i.number === 9).state, 'open');
});

test('renderBody: banner exact, Cites has own + decision hashes, Depends has issue numbers', () => {
  const { dir } = coreRepo();
  const { config, items, hashes } = ctx(dir);
  const it = items.find((i) => i.id === 'P-0-4');
  const body = renderBody(it, { hashes, issueNumbers: new Map([['P-0-3', 41]]), planSha: 'abcdef0123456', config });
  const lines = body.split('\n');
  assert.equal(lines[0], '> Mirror of `docs/plan/PLAN.md` item **P-0-4**, plan at `abcdef0`. The repo is the source of truth; an edit made here is not the plan.');
  assert.equal(lines[2], '## P-0-4 · Serve Swagger only outside production');
  const cites = lines.find((l) => l.startsWith('- **Cites:**'));
  assert.equal(cites, `- **Cites:** P-0-4@${hashes.get('P-0-4')}, D-8@${hashes.get('D-8')}, RL-7@${hashes.get('RL-7')}`);
  assert.match(cites, /P-0-4@[0-9a-f]{12}/);
  assert.ok(lines.includes('- **Area:** acme-api — `src/Program.cs`'));
  assert.ok(lines.includes('- **Depends:** P-0-3 (#41)'));
  assert.ok(lines.includes('## Ack log'));
  assert.equal(parseCites(body).get('RL-7'), hashes.get('RL-7'));
  assert.equal(parseCites('Closes #3\n- **Cites:** P-0-4@aaaaaaaaaaaa, D-8@bbbbbbbbbbbb\n').size, 2);
});

test('writeback: CRLF kept on every line, ticket line rewritten', () => {
  const { dir } = coreRepo();
  const crlf = fixture.replace(/\r/g, '').replace(/\n/g, '\r\n');
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), crlf);
  const nums = new Map([['P-0-3', 41], ['P-0-4', 42], ['P-0-5', 43]]);
  const issues = [...nums].map(([id, n]) => issue(n, id, bodyOf(dir, id, nums)));
  const { gh } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': issues, 'GRAPHQL ProjectInfo': PROJ });
  run({ argv: argv(dir, '--writeback'), gh, env: {} });
  const out = readFileSync(join(dir, 'docs/plan/PLAN.md'), 'utf8');
  assert.match(out, /- ticket: acme\/core#41\r\n/);
  assert.match(out, /- ticket: acme\/core#43\r\n/);
  assert.ok(!/- ticket: —/.test(out));
  assert.equal(out.split('\n').length - 1, (out.match(/\r\n/g) || []).length);
});

test('idempotence + state label preserved + project fields set once', () => {
  const { dir } = coreRepo();
  const s = sim();
  const first = run({ argv: argv(dir, '--apply'), gh: s.gh, env: {} });
  assert.equal(first.result.created.length, 3);
  assert.ok(s.st.labels.some((l) => l.name === 'state:needs-ack') && s.st.labels.some((l) => l.name === 'merged-stale'));
  assert.equal(s.st.milestones.length, 2);
  const created = s.st.issues.find((i) => i.title.startsWith('P-0-3'));
  assert.deepEqual(created.labels.map((l) => l.name).sort(), ['epic:0', 'kind:code', 'plan:P-0-3', 'repo:api', 'stage:A', 'state:ready']);
  assert.equal(created.milestone, 1);
  assert.equal(s.st.items.length, 3);
  // forward dependency numbers are settled in the same apply
  assert.match(s.st.issues.find((i) => i.title.startsWith('P-0-4')).body, /Depends:\*\* P-0-3 \(#\d+\)/);
  s.st.calls.length = 0;
  const second = run({ argv: argv(dir, '--apply'), gh: s.gh, env: {} });
  assert.equal(second.exitCode, 0);
  assert.deepEqual(s.st.calls, []);
  // reconcile owns state:*: an in-review issue keeps it
  const t = s.st.issues[0];
  t.labels = t.labels.filter((l) => !l.name.startsWith('state:')).concat([{ name: 'state:in-review' }]);
  run({ argv: argv(dir, '--apply'), gh: s.gh, env: {} });
  assert.deepEqual(t.labels.map((l) => l.name).filter((n) => n.startsWith('state:')), ['state:in-review']);
  assert.deepEqual(s.st.calls, []);
});

test('unknown stage is a config error: exit 2', () => {
  const { dir } = coreRepo();
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify({ ...CONFIG, stages: { later: 'x' } }));
  const { gh } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': [] });
  const r = run({ argv: argv(dir), gh, env: {} });
  assert.equal(r.exitCode, 2);
  assert.match(r.result.error, /stage/);
});

// ---- review round 1, item B: a rewrite keeps the issue's existing Cites hashes ----
function seedThree(dir) {
  const nums = new Map([['P-0-3', 1], ['P-0-4', 2], ['P-0-5', 3]]);
  const bodies = Object.fromEntries([...nums.keys()].map((id) => [id, bodyOf(dir, id, nums)]));
  return { nums, bodies, issues: () => [...nums].map(([id, n]) => issue(n, id, bodies[id])) };
}
function edit(dir, file, from, to) {
  const p = join(dir, 'docs/plan', file);
  const t = readFileSync(p, 'utf8');
  assert.ok(t.includes(from), `seed text missing: ${from}`);
  writeFileSync(p, t.replace(from, to));
  execFileSync('git', ['-C', dir, 'commit', '-qam', 'edit']);
}
const citesLine = (b) => b.split('\n').find((l) => l.startsWith('- **Cites:**'));

test('B1: a decision hash change alone is not drift, and --apply writes nothing', () => {
  const { dir } = coreRepo();
  const s = seedThree(dir);
  edit(dir, 'DECISIONS.md', '- rule: b', '- rule: b changed');
  const { gh, calls } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': s.issues(), 'GRAPHQL ProjectInfo': PROJ, 'POST graphql': POSTG });
  const dry = run({ argv: argv(dir), gh, env: {} });
  assert.deepEqual(dry.result.drift, []);
  assert.equal(dry.exitCode, 0);
  run({ argv: argv(dir, '--apply'), gh, env: {} });
  assert.deepEqual(calls.filter((c) => c.method === 'PATCH'), []);
});

test('B2: a real body edit is rewritten but keeps the OLD Cites hashes', () => {
  const { dir } = coreRepo();
  const s = seedThree(dir);
  const oldCites = citesLine(s.bodies['P-0-4']);
  edit(dir, 'PLAN.md', 'Disable Swagger in production builds.', 'Disable Swagger in production builds, always.');
  edit(dir, 'DECISIONS.md', '- rule: b', '- rule: b changed');
  assert.notEqual(citesLine(bodyOf(dir, 'P-0-4', s.nums)), oldCites); // the current render WOULD move them
  const { gh, calls } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': s.issues(), 'GRAPHQL ProjectInfo': PROJ, 'POST graphql': POSTG });
  run({ argv: argv(dir, '--apply'), gh, env: {} });
  const patches = calls.filter((c) => c.method === 'PATCH');
  assert.equal(patches.length, 1);
  assert.equal(patches[0].path, 'repos/acme/core/issues/2');
  assert.match(patches[0].body.body, /always\./);
  assert.equal(citesLine(patches[0].body.body), oldCites);
});

test('B3: --refresh-cites <ID> --apply re-renders Cites with current hashes for exactly that ID', () => {
  const { dir } = coreRepo();
  const s = seedThree(dir);
  edit(dir, 'DECISIONS.md', '- rule: b', '- rule: b changed');
  edit(dir, 'DECISIONS.md', '- rule: a', '- rule: a changed');
  const cur = bodyOf(dir, 'P-0-4', s.nums);
  const { gh, calls } = fakeGh({ ...base, 'GET repos/acme/core/issues?state=all': s.issues(), 'GRAPHQL ProjectInfo': PROJ, 'POST graphql': POSTG });
  const dry = run({ argv: argv(dir, '--refresh-cites', 'P-0-4'), gh, env: {} });
  assert.deepEqual(dry.result.drift.map((d) => d.id), ['P-0-4']);
  run({ argv: argv(dir, '--apply', '--refresh-cites', 'P-0-4'), gh, env: {} });
  const patches = calls.filter((c) => c.method === 'PATCH');
  assert.equal(patches.length, 1);
  assert.equal(patches[0].path, 'repos/acme/core/issues/2');
  assert.equal(citesLine(patches[0].body.body), citesLine(cur));
  assert.notEqual(citesLine(patches[0].body.body), citesLine(s.bodies['P-0-4']));
});

test('lag: the full listing misses an existing issue but the per-item read finds it; --apply creates nothing for it', () => {
  const { dir } = coreRepo();
  const { items } = ctx(dir);
  const id = items[0].id;
  const s = sim({ issues: [issue(9, id, 'old')] });
  s.st.lagList = true;
  const r = run({ argv: argv(dir, '--apply', '--only', id), gh: s.gh, env: {} });
  assert.equal(r.exitCode, 0);
  assert.deepEqual(r.result.created, []);
  assert.equal(s.st.calls.filter((c) => c.method === 'POST' && c.path === 'repos/acme/core/issues').length, 0);
  assert.equal(s.st.issues.filter((i) => i.labels.some((l) => l.name === 'plan:' + id)).length, 1);
});

// The real shape of a failed `gh api` call (measured): execFileSync's message carries only stderr ("gh: Validation
// Failed (HTTP 422)"); the response body, with the error code, is on stdout.
const ghFail422 = (code, field) => Object.assign(
  new Error('Command failed: gh api -X POST repos/acme/core/labels --input -\ngh: Validation Failed (HTTP 422)\n'),
  { status: 1, stdout: JSON.stringify({ message: 'Validation Failed', errors: [{ resource: 'Label', code, field }], status: '422' }), stderr: 'gh: Validation Failed (HTTP 422)\n' },
);
const failLabels = (s, err) => {
  const orig = s.gh.api;
  s.gh.api = (method, path, body) => {
    if (method === 'POST' && path === 'repos/acme/core/labels') throw err;
    return orig(method, path, body);
  };
};

test('label create answering 422 already_exists (a parallel run made it) is success', () => {
  const { dir } = coreRepo();
  const s = sim();
  failLabels(s, ghFail422('already_exists', 'name'));
  const r = run({ argv: argv(dir, '--apply'), gh: s.gh, env: {} });
  assert.equal(r.exitCode, 0);
  assert.ok(r.result.created.length > 0);
});

test('M10: label create answering 422 for anything but already_exists (an invalid colour) still fails', () => {
  const { dir } = coreRepo();
  const s = sim();
  failLabels(s, ghFail422('invalid', 'color'));
  assert.throws(() => run({ argv: argv(dir, '--apply'), gh: s.gh, env: {} }), /HTTP 422/);
  assert.equal(s.st.calls.filter((c) => c.method === 'POST' && c.path === 'repos/acme/core/issues').length, 0, 'nothing created after the failure');
});
