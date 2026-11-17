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
const { run } = require('../../../lib/gate.js');
const { planHashes } = require('../../../lib/plan.js');
const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(here, '../fixtures/PLAN-list.md'), 'utf8');

const BASE = {
  plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' },
  repos: {
    'acme-api': { github: 'acme/api', default: 'main', label: 'api', ci: 'required', tests: ['dotnet test'] },
    'acme-mobile': { github: 'acme/mobile', default: 'master', label: 'mobile', ci: 'none', tests: ['npm test'] },
  },
  ownerArea: 'owner',
  github: { writeDelayMs: 0 },
};
const DEC = '# D\n\n### D-1 · First\n- rule: a\n\n### D-8 · Eighth\n- rule: b\n';
const RUL = '# R\n\n### RL-7 · Seventh\n- rule: c\n';

function core(config = BASE) {
  const dir = mkdtempSync(join(tmpdir(), 'devfw-gate-'));
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify(config));
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), fixture);
  writeFileSync(join(dir, 'docs/plan/DECISIONS.md'), DEC);
  writeFileSync(join(dir, 'docs/plan/RULINGS.md'), RUL);
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 'a@acme.test'); g('config', 'user.name', 'a');
  g('add', '-A'); g('commit', '-qm', 'base');
  const bare = mkdtempSync(join(tmpdir(), 'devfw-gate-origin-'));
  execFileSync('git', ['init', '-q', '--bare', bare]);
  g('remote', 'add', 'origin', bare); g('push', '-q', 'origin', 'main');
  const sha = g('rev-parse', 'HEAD').trim();
  const hashes = planHashes(dir, 'origin/main', config);
  return { dir, sha, hashes };
}

const GOOD_EVIDENCE = 'Evidence:\ndotnet test: 120 passed\ncoverage: 95%\n';
const body = (c, { cites, fixes = 'Fixes acme/core#12', evidence = GOOD_EVIDENCE } = {}) =>
  `${fixes}\nCites: ${cites ?? `P-0-4@${c.hashes.get('P-0-4')}, D-8@${c.hashes.get('D-8')}`}\n\n${evidence}`;

const logicFiles = (n) => [{ filename: 'src/a.cs', additions: n, deletions: 0, status: 'modified' }];

function routes({ repo = 'acme/api', prBody, runs = [{ name: 'build', status: 'completed', conclusion: 'success' }], statuses = [], files = logicFiles(10), comments = [] }) {
  return {
    [`GET repos/${repo}/pulls/50`]: { number: 50, body: prBody, head: { sha: 'abc123' } },
    [`GET repos/${repo}/commits/abc123/check-runs`]: { total_count: runs.length, check_runs: runs },
    [`GET repos/${repo}/commits/abc123/status`]: { state: statuses.length ? 'success' : 'pending', statuses },
    [`GET repos/${repo}/pulls/50/files`]: files,
    'GET repos/acme/core/issues/12/comments': comments,
  };
}

function go(c, r, { repo = 'acme/api' } = {}) {
  const { gh, calls } = fakeGh(r);
  const out = run({ argv: ['--core-dir', c.dir, '--repo', repo, '--pr', '50'], gh, env: {} });
  assert.deepEqual(calls.filter((x) => x.method !== 'GET'), [], 'merge-gate must never write');
  return out;
}

test('baseline: a fully good PR passes every check', () => {
  const c = core();
  const { exitCode, result } = go(c, routes({ prBody: body(c) }));
  assert.deepEqual(result.reasons, []);
  assert.equal(result.pass, true);
  assert.equal(exitCode, 0);
  assert.deepEqual(result.checks, { ci: true, cites: true, evidence: true, size: true, coverage: null });
});

test('Review Focus 4: zero check runs and no statuses on a ci:required repo refuses', () => {
  const c = core();
  const { exitCode, result } = go(c, routes({ prBody: body(c), runs: [] }));
  assert.equal(result.pass, false);
  assert.equal(exitCode, 6);
  assert.equal(result.checks.ci, false);
  assert.ok(result.reasons.includes('ci: no checks attached'), result.reasons.join(' | '));
});

test('ci positive control: the same PR with one success run passes (a)', () => {
  const c = core();
  const { result } = go(c, routes({ prBody: body(c) }));
  assert.equal(result.checks.ci, true);
});

test('ci: skipped and neutral are tolerated beside a success; alone they refuse; failure, pending and failing statuses refuse', () => {
  const c = core();
  const skipNeutral = [{ name: 'a', status: 'completed', conclusion: 'skipped' }, { name: 'b', status: 'completed', conclusion: 'neutral' }];
  const ok = [...skipNeutral, { name: 's', status: 'completed', conclusion: 'success' }];
  assert.equal(go(c, routes({ prBody: body(c), runs: ok })).result.checks.ci, true);
  const alone = go(c, routes({ prBody: body(c), runs: skipNeutral })).result;
  assert.equal(alone.checks.ci, false);
  assert.ok(alone.reasons.includes('ci: no successful check'), alone.reasons.join(' | '));
  const bad = go(c, routes({ prBody: body(c), runs: [...ok, { name: 'c', status: 'completed', conclusion: 'failure' }] })).result;
  assert.equal(bad.checks.ci, false);
  const pending = go(c, routes({ prBody: body(c), runs: [{ name: 'p', status: 'in_progress', conclusion: null }] })).result;
  assert.equal(pending.checks.ci, false);
  const st = go(c, routes({ prBody: body(c), statuses: [{ context: 'legacy', state: 'failure' }] })).result;
  assert.equal(st.checks.ci, false);
  // a repo with only a passing commit status has CI attached
  const onlyStatus = go(c, routes({ prBody: body(c), runs: [], statuses: [{ context: 'legacy', state: 'success' }] })).result;
  assert.equal(onlyStatus.checks.ci, true);
});

test('ci: none: zero runs pass only when Evidence carries every configured test command', () => {
  const c = core();
  const withCmd = routes({ repo: 'acme/mobile', runs: [], prBody: body(c, { evidence: 'Evidence:\nnpm test: 40 passed\n' }) });
  assert.equal(go(c, withCmd, { repo: 'acme/mobile' }).result.checks.ci, true);
  const without = routes({ repo: 'acme/mobile', runs: [], prBody: body(c, { evidence: 'Evidence:\nlooked fine to me\n' }) });
  const r = go(c, without, { repo: 'acme/mobile' }).result;
  assert.equal(r.checks.ci, false);
  assert.equal(r.pass, false);
});

test('cites: current hashes pass; a stale hash with no ack refuses', () => {
  const c = core();
  const stale = `P-0-4@${'f'.repeat(12)}, D-8@${c.hashes.get('D-8')}`;
  const { exitCode, result } = go(c, routes({ prBody: body(c, { cites: stale }) }));
  assert.equal(result.checks.cites, false);
  assert.equal(exitCode, 6);
  assert.ok(result.reasons.some((x) => x.startsWith('cites: P-0-4@')), result.reasons.join(' | '));
});

test('cites: stale plus an ack that resolves to the current hash passes', () => {
  const c = core();
  const stale = `P-0-4@${'f'.repeat(12)}, D-8@${c.hashes.get('D-8')}`;
  const comments = [{ body: `ack 12 ${c.sha}: wording only`, author_association: 'MEMBER' }];
  const { result } = go(c, routes({ prBody: body(c, { cites: stale }), comments }));
  assert.equal(result.checks.cites, true, result.reasons.join(' | '));
  // an ack for a different issue number does not cover it
  const other = go(c, routes({ prBody: body(c, { cites: stale }), comments: [{ body: `ack 99 ${c.sha}: x`, author_association: 'MEMBER' }] })).result;
  assert.equal(other.checks.cites, false);
});

test('cites: a missing Cites: line, or a missing Fixes line, refuses', () => {
  const c = core();
  const none = go(c, routes({ prBody: `Fixes acme/core#12\n\n${GOOD_EVIDENCE}` })).result;
  assert.equal(none.checks.cites, false);
  const nofix = go(c, routes({ prBody: body(c, { fixes: 'no link here' }) })).result;
  assert.equal(nofix.checks.cites, false);
});

test('evidence: "Evidence:" followed directly by a blank line refuses', () => {
  const c = core();
  const { result } = go(c, routes({ prBody: body(c, { evidence: 'Evidence:\n\nNotes below\ncoverage: 95%\n' }) }));
  assert.equal(result.checks.evidence, false);
  const heading = go(c, routes({ prBody: body(c, { evidence: 'Evidence:\n## Notes\n' }) })).result;
  assert.equal(heading.checks.evidence, false);
  assert.equal(go(c, routes({ prBody: `Fixes acme/core#12\nCites: P-0-4@${c.hashes.get('P-0-4')}\n` })).result.checks.evidence, false);
});

test('size: one logic file +250 lines (20 + 375 = 395s) refuses against the full 300s budget', () => {
  const c = core();
  const { exitCode, result } = go(c, routes({ prBody: body(c), files: logicFiles(250) }));
  assert.equal(result.checks.size, false);
  assert.equal(exitCode, 6);
  assert.ok(result.reasons.some((x) => x.startsWith('size:') && x.includes('395') && x.includes('300')), result.reasons.join(' | '));
  // +150 lines = 245s: over the 240s planned limit, within the 300s diff limit
  assert.equal(go(c, routes({ prBody: body(c), files: logicFiles(150) })).result.checks.size, true);
});

test('coverage: enforce true, min 90: 89% refuses, 91% passes', () => {
  const c = core({ ...BASE, coverage: { enforce: true, min: 90 } });
  const at = (n) => go(c, routes({ prBody: body(c, { evidence: `Evidence:\ndotnet test: ok\ncoverage: ${n}%\n` }) })).result;
  assert.equal(at(89).checks.coverage, false);
  assert.equal(at(89).pass, false);
  assert.equal(at(91).checks.coverage, true);
  assert.equal(at(91).pass, true);
  const missing = go(c, routes({ prBody: body(c, { evidence: 'Evidence:\ndotnet test: ok\n' }) })).result;
  assert.equal(missing.checks.coverage, false);
});

test('coverage: enforce false is not checked even when the number is low', () => {
  const c = core();
  const { result } = go(c, routes({ prBody: body(c, { evidence: 'Evidence:\ndotnet test: ok\ncoverage: 10%\n' }) }));
  assert.equal(result.checks.coverage, null);
  assert.equal(result.pass, true);
});

test('config errors exit 2: unknown repo, missing arguments', () => {
  const c = core();
  const { gh } = fakeGh({});
  assert.equal(run({ argv: ['--core-dir', c.dir, '--repo', 'acme/other', '--pr', '50'], gh, env: {} }).exitCode, 2);
  assert.equal(run({ argv: ['--core-dir', c.dir], gh, env: {} }).exitCode, 2);
});

test('the plan branch is read fresh: a hash that changed on origin/main after the clone is judged current', () => {
  const c = core();
  const g = (...a) => execFileSync('git', ['-C', c.dir, ...a], { encoding: 'utf8' });
  const other = mkdtempSync(join(tmpdir(), 'devfw-gate-other-'));
  execFileSync('git', ['clone', '-q', '-b', 'main', g('remote', 'get-url', 'origin').trim(), other]);
  const edited = readFileSync(join(other, 'docs/plan/PLAN.md'), 'utf8').replace('Disable Swagger in production builds.', 'Disable Swagger everywhere.');
  writeFileSync(join(other, 'docs/plan/PLAN.md'), edited);
  const o = (...a) => execFileSync('git', ['-C', other, '-c', 'user.name=a', '-c', 'user.email=a@acme.test', ...a], { encoding: 'utf8' });
  o('commit', '-qam', 'edit'); o('push', '-q', 'origin', 'main');
  // the PR cites the OLD hash; the freshly fetched plan has a new one, so it is stale
  const { result } = go(c, routes({ prBody: body(c) }));
  assert.equal(result.checks.cites, false);
});

// ---- fix round 1: the gate fails closed ----
test('fix1: a failed plan fetch refuses, even though the cites match the cached ref', () => {
  const c = core();
  const g = (...a) => execFileSync('git', ['-C', c.dir, ...a], { encoding: 'utf8' });
  g('remote', 'set-url', 'origin', join(tmpdir(), 'devfw-no-such-origin-xyz'));
  const { exitCode, result } = go(c, routes({ prBody: body(c) }));
  assert.equal(result.pass, false);
  assert.equal(exitCode, 6);
  assert.equal(result.checks.cites, false);
  assert.ok(result.reasons.includes('cites: plan fetch failed'), result.reasons.join(' | '));
});

test('fix2: a ci:none repo with an empty or missing tests list is a config error (exit 2), never a pass', () => {
  for (const tests of [[], undefined]) {
    const repos = { ...BASE.repos, 'acme-mobile': { github: 'acme/mobile', default: 'master', label: 'mobile', ci: 'none', ...(tests ? { tests } : {}) } };
    const c = core({ ...BASE, repos });
    const r = routes({ repo: 'acme/mobile', runs: [], prBody: body(c, { evidence: 'Evidence:\nnpm test: 40 passed\n' }) });
    const { exitCode, result } = go(c, r, { repo: 'acme/mobile' });
    assert.equal(exitCode, 2);
    assert.match(result.error, /repos\.acme-mobile\.tests/);
  }
  // The gate's own check stays as defense in depth for a config built in code.
  const { checkCi } = require('../../../lib/gate.js');
  assert.deepEqual(checkCi({ repoConfig: { ci: 'none', tests: [] }, runs: [], statuses: [], evidence: 'npm test' }), ['ci: no test commands configured for ci:none repo']);
});

test('fix3: a malformed cite entry refuses and is named; parseCites keeps its lenient behaviour', () => {
  const c = core();
  for (const bad of ['P-0-4@abc', 'P-0-4@' + 'G'.repeat(12), 'P-0-4']) {
    const { result } = go(c, routes({ prBody: body(c, { cites: `${bad}, D-8@${c.hashes.get('D-8')}` }) }));
    assert.equal(result.checks.cites, false, bad);
    assert.ok(result.reasons.includes(`cites: malformed entry ${bad}`), result.reasons.join(' | '));
  }
  const { parseCites } = require('../../../lib/ticket-body.js');
  assert.deepEqual([...parseCites(`Cites: P-0-4@abc, D-8@${'a'.repeat(12)}`)], [['D-8', 'a'.repeat(12)]]);
});
