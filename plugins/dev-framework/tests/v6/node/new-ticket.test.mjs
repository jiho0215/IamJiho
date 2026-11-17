import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fakeGh } from './fake-gh.mjs';

const require = createRequire(import.meta.url);
const { run } = require('../../../lib/new-ticket.js');

const CONFIG = {
  plan: { repo: 'acme/core', path: 'docs/plan', branch: 'main' },
  repos: { 'acme-api': { github: 'acme/api', default: 'main', label: 'api', ci: 'required' } },
  ownerArea: 'owner',
  stages: { A: 'Stage A — Gates' },
  github: { writeDelayMs: 0 },
};
const TOKEN = '00000000000000aa';
const LEASE = `orchestrator: ${TOKEN} · box1 · since 2026-11-16T00:00:00Z`;
const item = (id, title, extra = '') => `### ${id} · ${title}\n- stage: A\n- kind: code\n- state: ready\n- area: acme-api — \`src/x.cs\`\n- depends: —\n- decisions: —\n- ticket: —\n\n${extra}Body of ${id}.\n`;
const PLAN = (eol) => ['# Plan', '', '## P-3 · Epic three', '', item('P-3-1', 'First'), item('P-3-2', 'Second', 'Unused on purpose: P-3-4 was dropped.\n\n'), '## P-4 · Epic four', '', item('P-4-1', 'Other'), ''].join('\n').replace(/\n/g, eol);

function core({ eol = '\n', lease = true } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'devfw-nt-'));
  const p = (f) => join(dir, 'docs/plan', f);
  mkdirSync(join(dir, 'docs/plan'), { recursive: true });
  writeFileSync(join(dir, 'orchestrator.json'), JSON.stringify(CONFIG));
  writeFileSync(p('PLAN.md'), PLAN(eol));
  writeFileSync(p('START-HERE.md'), LEASE + '\n\n# Start\n');
  writeFileSync(join(dir, '.gitignore'), '.orchestrator/\n');
  const g = (...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  g('init', '-q', '-b', 'main'); g('config', 'user.email', 'a@acme.test'); g('config', 'user.name', 'a');
  g('config', 'core.autocrlf', 'false');
  g('add', '-A'); g('commit', '-qm', 'base');
  const bare = mkdtempSync(join(tmpdir(), 'devfw-nt-origin-'));
  execFileSync('git', ['init', '-q', '--bare', '-b', 'main', bare]);
  g('remote', 'add', 'origin', bare); g('push', '-q', 'origin', 'main');
  mkdirSync(join(dir, '.orchestrator'), { recursive: true });
  writeFileSync(join(dir, '.orchestrator/lease'), lease ? TOKEN + '\n' : 'ffffffffffffffff\n');
  return { dir, bare, g, plan: p('PLAN.md') };
}
const bodyFile = () => { const f = join(mkdtempSync(join(tmpdir(), 'devfw-nt-body-')), 'b.md'); writeFileSync(f, 'Do the new thing.\n'); return f; };
const argv = (dir, ...extra) => ['--core-dir', dir, '--epic', '3', '--title', 'New thing', '--area', 'acme-api — `src/new.cs`', '--kind', 'code', '--stage', 'A', '--body-file', bodyFile(), ...extra];

test('dry run: allocates P-3-5 (a text mention of P-3-4 is skipped), inside the P-3 section, writes nothing', () => {
  const k = core();
  const before = readFileSync(k.plan, 'utf8');
  const { gh, calls } = fakeGh({});
  const out = run({ argv: argv(k.dir), gh, env: {} });
  assert.equal(out.exitCode, 0);
  assert.equal(out.result.id, 'P-3-5');
  assert.match(out.result.text, /^### P-3-5 · New thing\n- stage: A\n- kind: code\n- state: ready\n- area: acme-api/);
  assert.equal(readFileSync(k.plan, 'utf8'), before);
  assert.equal(calls.length, 0);
  // where it would land: after P-3-2's body, before the P-4 heading
  const lines = out.result.planText.split('\n');
  const at = lines.indexOf('### P-3-5 · New thing');
  assert.ok(at > lines.indexOf('### P-3-2 · Second') && at < lines.indexOf('## P-4 · Epic four'));
});

test('no lease: exit 4 and no file is changed, no gh call, no branch', () => {
  const k = core({ lease: false });
  const before = readFileSync(k.plan, 'utf8');
  const { gh, calls } = fakeGh({});
  const out = run({ argv: argv(k.dir, '--apply'), gh, env: {} });
  assert.equal(out.exitCode, 4);
  assert.equal(readFileSync(k.plan, 'utf8'), before);
  assert.equal(calls.length, 0);
  assert.equal(k.g('branch', '--list', 'plan/new-*').trim(), '');
});

test('CRLF plan stays CRLF', () => {
  const k = core({ eol: '\r\n' });
  const { gh } = fakeGh({});
  const out = run({ argv: argv(k.dir), gh, env: {} });
  assert.ok(out.result.planText.includes('### P-3-5 · New thing\r\n'));
  assert.equal(out.result.planText.replace(/\r\n/g, '').includes('\n'), false, 'no bare LF');
});

test('--apply: branch, push, PR with lease, impact, squash merge (no --auto/--delete-branch), ticket-sync', () => {
  const k = core();
  const base = () => k.g('rev-parse', 'origin/main').trim();
  const routes = {
    'POST repos/acme/core/pulls': { number: 7 },
    'GET repos/acme/core/pulls/7/files': [{ filename: 'docs/plan/PLAN.md' }],
    'GET repos/acme/core/issues?state=all': [],
    'GET repos/acme/api/pulls?state=open': [],
    'GET repos/acme/core/issues/7/comments': [],
    'GET repos/acme/core/labels': [],
    'GET repos/acme/core/milestones?state=all': [],
    'POST repos/acme/core/issues': { number: 99 },
    'POST repos/acme/core/milestones': { number: 1 },
    get 'GET repos/acme/core/pulls/7'() {
      return { number: 7, body: `lease: ${TOKEN}`, base: { sha: base() }, head: { sha: k.g('rev-parse', 'plan/new-P-3-5').trim() } };
    },
  };
  const { gh, calls } = fakeGh(routes);
  // Simulate GitHub's squash merge: advance origin/main to the pushed branch.
  const seen = [];
  const wrapped = { ...gh, raw: (args, input) => {
    seen.push(args);
    if (args[0] === 'pr' && args[1] === 'merge') {
      const sha = execFileSync('git', ['-C', k.bare, 'rev-parse', 'refs/heads/plan/new-P-3-5'], { encoding: 'utf8' }).trim();
      execFileSync('git', ['-C', k.bare, 'update-ref', 'refs/heads/main', sha]);
    }
    return gh.raw(args, input);
  } };
  const onMain = k.g('rev-parse', '--abbrev-ref', 'HEAD').trim();
  const out = run({ argv: argv(k.dir, '--apply'), gh: wrapped, env: {} });
  assert.equal(out.exitCode, 0, JSON.stringify(out.result));
  assert.deepEqual(out.result, { id: 'P-3-5', issue: 99, planPr: 7 });

  const mergeArgs = seen.find((a) => a[0] === 'pr' && a[1] === 'merge');
  assert.deepEqual(mergeArgs, ['pr', 'merge', '7', '--repo', 'acme/core', '--squash']);
  for (const a of seen) assert.ok(!a.includes('--auto') && !a.includes('--delete-branch'));

  const seq = calls.map((c) => (c.method === 'RAW' ? 'RAW ' + c.path.split(' ').slice(0, 2).join(' ') : `${c.method} ${c.path}`));
  const iPr = seq.indexOf('POST repos/acme/core/pulls');
  const iStatus = seq.findIndex((s) => /^POST repos\/acme\/core\/statuses\//.test(s));
  const iMerge = seq.indexOf('RAW pr merge');
  const iIssue = seq.indexOf('POST repos/acme/core/issues');
  assert.ok(iPr >= 0 && iPr < iStatus && iStatus < iMerge && iMerge < iIssue, seq.join(' | '));
  assert.equal(calls[iPr].body.base, 'main');
  assert.equal(calls[iPr].body.head, 'plan/new-P-3-5');
  assert.match(calls[iPr].body.body, new RegExp(`lease: ${TOKEN}`));
  assert.equal(calls[iStatus].body.state, 'success');

  // the branch really reached origin with the new item, and the clone is back where it was
  assert.match(execFileSync('git', ['-C', k.bare, 'show', 'refs/heads/plan/new-P-3-5:docs/plan/PLAN.md'], { encoding: 'utf8' }), /### P-3-5 · New thing/);
  assert.equal(k.g('rev-parse', '--abbrev-ref', 'HEAD').trim(), onMain);
});
