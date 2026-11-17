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
const { parsePlan, planHashes, PlanError } = require('../../../lib/plan.js');
const { loadConfig, ConfigError } = require('../../../lib/config.js');
const { createGh } = require('../../../lib/gh.js');
const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(here, '../fixtures/PLAN-list.md'), 'utf8');
const config = {
  plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' },
  ownerArea: 'owner',
  repos: {
    'acme-api': { github: 'acme/api', default: 'main', ci: 'required' },
    'acme-mobile': { github: 'acme/mobile', default: 'master', ci: 'none', tests: ['npm test'] },
  },
};

test('parses PLAN-list.md into 3 items with fields and dep arrays', () => {
  const items = parsePlan(fixture, config);
  assert.equal(items.length, 3);
  assert.equal(items[1].id, 'P-0-4');
  assert.equal(items[1].title, 'Serve Swagger only outside production');
  assert.equal(items[1].fields.stage, 'A');
  assert.equal(items[1].repo, 'acme-api');
  assert.deepEqual(items[1].deps, ['P-0-3']);
  assert.deepEqual(items[1].decisions, ['D-8', 'RL-7']);
  assert.deepEqual(items[0].deps, []);
  assert.equal(items[2].repo, 'acme-mobile');
  assert.match(items[0].body, /Expose a health endpoint/);
});

test('duplicate ID throws PlanError naming the ID', () => {
  const dup = fixture + '\n### P-0-3 · Again\n- stage: A\n- kind: code\n- state: ready\n- area: acme-api\n- depends: —\n- decisions: —\n- ticket: —\n';
  assert.throws(() => parsePlan(dup, config), (e) => e instanceof PlanError && /P-0-3/.test(e.message));
});

test('unknown repo and unknown depends ID throw PlanError', () => {
  assert.throws(() => parsePlan(fixture.replace('acme-mobile', 'acme-ghost'), config),
    (e) => e instanceof PlanError && /acme-ghost/.test(e.message));
  assert.throws(() => parsePlan(fixture.replace('depends: P-0-4', 'depends: P-9-9'), config),
    (e) => e instanceof PlanError && /P-9-9/.test(e.message));
});

test('missing required field throws PlanError', () => {
  assert.throws(() => parsePlan(fixture.replace('- kind: code\n', ''), config), PlanError);
});

test('planHashes: only the edited item changes; D- IDs included; missing RULINGS tolerated', () => {
  const dir = mkdtempSync(join(tmpdir(), 'acme-core-'));
  const git = (...a) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@acme.test', ...a], { encoding: 'utf8' });
  git('init', '-q');
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), fixture);
  writeFileSync(join(dir, 'docs/plan/DECISIONS.md'), '# D\n\n### D-1 · First\n- rule: a\n');
  git('add', '-A'); git('commit', '-qm', 'one');
  writeFileSync(join(dir, 'docs/plan/PLAN.md'), fixture.replace('Render the build number.', 'Render the build number and date.'));
  git('commit', '-qam', 'two');
  const cfg = { plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' } };
  const a = planHashes(dir, 'HEAD~1', cfg);
  const b = planHashes(dir, 'HEAD', cfg);
  assert.ok(a.has('D-1'));
  assert.equal(a.get('D-1'), b.get('D-1'));
  assert.equal(a.get('P-0-3'), b.get('P-0-3'));
  assert.equal(a.get('P-0-4'), b.get('P-0-4'));
  assert.notEqual(a.get('P-0-5'), b.get('P-0-5'));
  assert.match(a.get('P-0-5'), /^[0-9a-f]{12}$/);
});

test('fakeGh paginates 150 issues as pages of 100 and 50', () => {
  const issues = Array.from({ length: 150 }, (_, i) => ({ number: i + 1 }));
  const { gh } = fakeGh({ 'GET repos/acme/core/issues?labels=x': { pages: [issues.slice(0, 100), issues.slice(100)] } });
  assert.equal(gh.paginate('repos/acme/core/issues?labels=x').length, 150);
});

test('fakeGh records writes and throws on unrouted GET', () => {
  const { gh, calls } = fakeGh({});
  assert.deepEqual(gh.api('POST', 'repos/acme/core/issues', { title: 't' }), {});
  assert.deepEqual(calls, [{ method: 'POST', path: 'repos/acme/core/issues', body: { title: 't' } }]);
  assert.throws(() => gh.api('GET', 'repos/acme/core/issues'), /unrouted/);
});

test('search path is forbidden', () => {
  const gh = createGh({ exec: () => '[]' });
  assert.throws(() => gh.api('GET', 'search/issues?q=x'), /search API forbidden/);
  assert.throws(() => gh.paginate('search/issues?q=x'), /search API forbidden/);
});

test('loadConfig rejects bad ci and bad github; honours DEVFW_CONFIG', () => {
  const dir = mkdtempSync(join(tmpdir(), 'acme-cfg-'));
  const file = join(dir, 'orchestrator.json');
  const plan = { repo: 'acme/core' };
  writeFileSync(file, JSON.stringify({ plan, repos: { 'acme-api': { github: 'acme/api', default: 'main', ci: 'sometimes' } } }));
  assert.throws(() => loadConfig({ coreDir: dir, env: {} }), (e) => e instanceof ConfigError && /ci/.test(e.message));
  writeFileSync(file, JSON.stringify({ plan, repos: { 'acme-api': { github: 'nonsense', default: 'main', ci: 'required' } } }));
  assert.throws(() => loadConfig({ coreDir: dir, env: {} }), (e) => e instanceof ConfigError && /github/.test(e.message));
  const good = join(dir, 'other.json');
  writeFileSync(good, JSON.stringify({ plan, repos: { x: { github: 'acme/x', default: 'main', ci: 'none', tests: ['npm test'] } }, github: { writeDelayMs: 5 } }));
  const c = loadConfig({ coreDir: dir, env: { DEVFW_CONFIG: good } });
  assert.equal(c.github.writeDelayMs, 5);
  assert.equal(c.plan.path, 'docs/plan');
  assert.equal(c.plan.branch, 'main');
  assert.equal(c.ownerArea, 'owner');
});
