// A4: a typo-only plan edit leaves the other tickets alone. Needs DEVFW_SANDBOX_CORE / DEVFW_SANDBOX_CODE.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync, execFileSync } from 'node:child_process';
import { openRun, closeRun, eventually } from './harness.mjs';

const gh = (args) => {
  const r = spawnSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`gh ${args.slice(0, 2).join(' ')} failed: ${r.stderr || r.stdout}`);
  return r.stdout;
};
const ID = ['-c', 'user.name=devfw-harness', '-c', 'user.email=devfw-harness@users.noreply.github.com'];
const git = (dir, args) => execFileSync('git', ['-C', dir, ...ID, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

test('A4: typo', async () => {
  const run = await openRun();
  try {
    const core = process.env.DEVFW_SANDBOX_CORE;
    const id = (n) => `P-${run.runId}-${n}`;
    const sync = run.exec('ticket-sync', ['--core-dir', run.coreDir, '--apply']);
    assert.equal(sync.code, 0, `ticket-sync: ${sync.stdout} ${sync.stderr}`);
    const num = new Map(sync.json.created.map((c) => [c.id, c.issue]));
    assert.equal(num.size, 3);

    // The scripts list issues right away; wait (read-only dry run) until the listing shows all three, or reconcile skips the lagging ones.
    await eventually(() => {
      const r = run.exec('ticket-sync', ['--core-dir', run.coreDir]);
      assert.deepEqual(r.json && r.json.missing, [], `listing not settled: ${r.stdout}`);
    });
    const rec = run.exec('reconcile', ['--core-dir', run.coreDir, '--apply']);
    assert.equal(rec.code, 0, `reconcile: ${rec.stdout} ${rec.stderr}`);
    const stateLabels = (n) => JSON.parse(gh(['api', `repos/${core}/issues/${n}`])).labels.map((l) => l.name).filter((l) => l.startsWith('state:')).sort();
    // Wait until GitHub shows exactly the states reconcile derived (reads lag writes), then record them.
    const want = new Map(rec.json.items.map((i) => [i.id, [`state:${i.state}`]]));
    const before = await eventually(() => {
      const s = new Map([1, 2, 3].map((k) => [k, stateLabels(num.get(id(k)))]));
      for (const k of [1, 2, 3]) assert.deepEqual(s.get(k), want.get(id(k)), `${id(k)} settled state`);
      return s;
    });

    // The typo edit, on its own branch, as a PR into the run branch carrying the lease.
    const typo = `run/${run.runId}-typo`;
    git(run.coreDir, ['checkout', '-q', '-b', typo]);
    const file = path.join(run.coreDir, 'docs', 'plan', 'PLAN.md');
    const text = fs.readFileSync(file, 'utf8');
    assert.ok(text.includes('Expose a version endpoint.'));
    fs.writeFileSync(file, text.replace('Expose a version endpoint.', 'Expose a versoin endpoint.'));
    git(run.coreDir, ['add', 'docs/plan/PLAN.md']);
    git(run.coreDir, ['commit', '-q', '-m', `typo ${run.runId}`]);
    git(run.coreDir, ['push', '-q', '-u', 'origin', typo]);
    const token = fs.readFileSync(path.join(run.coreDir, '.orchestrator', 'lease'), 'utf8').trim();
    const prUrl = gh(['pr', 'create', '--repo', core, '--base', `run/${run.runId}`, '--head', typo,
      '--title', `typo fix ${run.runId}`, '--body', `Typo only.\n\nlease: ${token}\n`]).trim();
    const prNo = Number(prUrl.split('/').pop());
    assert.ok(prNo > 0, `pr url: ${prUrl}`);

    const imp = run.exec('impact', ['--core-dir', run.coreDir, '--pr', String(prNo), '--apply']);
    assert.ok(imp.json && imp.json.changed, `impact: ${imp.stdout} ${imp.stderr}`);
    assert.deepEqual(imp.json.changed, [id(2)]);
    assert.deepEqual(imp.json.affected.map((a) => [a.kind, a.issue]), [['issue', num.get(id(2))]]);
    assert.deepEqual(imp.json.violations, []);
    assert.equal(imp.code, 8, 'one unticked box');

    const head = JSON.parse(gh(['api', `repos/${core}/pulls/${prNo}`])).head.sha;
    await eventually(() => {
      const st = JSON.parse(gh(['api', `repos/${core}/commits/${head}/status`])).statuses.find((s) => s.context === 'devfw/plan-impact');
      assert.ok(st, 'devfw/plan-impact status exists');
      assert.equal(st.state, 'failure');
    });

    const rec2 = run.exec('reconcile', ['--core-dir', run.coreDir, '--apply']);
    assert.equal(rec2.code, 0, `reconcile 2: ${rec2.stdout} ${rec2.stderr}`);
    await eventually(() => {
      for (const k of [1, 3]) assert.deepEqual(stateLabels(num.get(id(k))), before.get(k), `${id(k)} state unchanged`);
    });
  } finally { await closeRun(run); }
});
