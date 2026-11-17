// A8: one ticket through the whole scripted cycle: claim, commit, PR, gate, merge, reconcile -> done.
import test from 'node:test';
import assert from 'node:assert/strict';
import { openRun, closeRun, eventually } from './harness.mjs';
import { gh, syncTickets, claimCommitPr, gate } from './ticket-flow.mjs';

test('A8: cycle', async () => {
  const run = await openRun();
  try {
    const num = await syncTickets(run);
    const id = `P-${run.runId}-2`;
    const issue = num.get(id);
    const { pr } = await claimCommitPr(run, issue, 'version', 'src/version.js');

    const g = await eventually(() => {
      const r = gate(run, pr);
      assert.equal(r.json && r.json.pass, true, `gate: ${r.stdout} ${r.stderr}`);
      return r;
    });
    assert.equal(g.code, 0);

    // Sandbox code repo only (openRun verified it). Never --auto, never --delete-branch.
    gh(['pr', 'merge', String(pr), '--repo', run.codeRepo, '--squash']);

    // Wait (read-only dry run) until reconcile derives done, then apply once.
    await eventually(() => {
      const r = run.exec('reconcile', ['--core-dir', run.coreDir]);
      const row = r.json && r.json.items && r.json.items.find((i) => i.id === id);
      assert.ok(row, `reconcile: ${r.stdout} ${r.stderr}`);
      assert.equal(row.state, 'done', `derived: ${JSON.stringify(row)}`);
    });
    const rec = run.exec('reconcile', ['--core-dir', run.coreDir, '--apply']);
    assert.equal(rec.code, 0, `reconcile --apply: ${rec.stdout} ${rec.stderr}`);
    await eventually(() => {
      const iss = JSON.parse(gh(['api', `repos/${run.coreRepo}/issues/${issue}`]));
      assert.equal(iss.state, 'closed');
      assert.deepEqual(iss.labels.map((l) => l.name).filter((l) => l.startsWith('state:')), ['state:done']);
    });

    // Dry run (no --apply). Earlier runs' merged PRs sit in the same sandbox repo and belong to other plans, so judge
    // THIS PR: it is in neither list; the exit is 0 unless some other run's PR is listed.
    const pm = run.exec('reconcile', ['--core-dir', run.coreDir, '--post-merge']);
    assert.ok(pm.json && Array.isArray(pm.json.staleMerges), `post-merge: ${pm.stdout} ${pm.stderr}`);
    const mine = (x) => x.repo === run.codeRepo && x.pr === pr;
    assert.deepEqual(pm.json.staleMerges.filter(mine), []);
    assert.deepEqual(pm.json.unverifiable.filter(mine), []);
    assert.equal(pm.code, pm.json.staleMerges.length + pm.json.unverifiable.length ? 9 : 0);
  } finally { await closeRun(run); }
});
