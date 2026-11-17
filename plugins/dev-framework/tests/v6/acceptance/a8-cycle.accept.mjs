// A8: one ticket through the whole scripted cycle: claim, commit, PR, gate, merge, reconcile -> done.
import test from 'node:test';
import assert from 'node:assert/strict';
import { openRun, closeRun, eventually } from './harness.mjs';
import { ghRead, syncTickets, claimCommitPr, gate, mergePr } from './ticket-flow.mjs';

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
    mergePr(run, pr);

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
      const iss = JSON.parse(ghRead(['api', `repos/${run.coreRepo}/issues/${issue}`]));
      assert.equal(iss.state, 'closed');
      assert.deepEqual(iss.labels.map((l) => l.name).filter((l) => l.startsWith('state:')), ['state:done']);
    });

    // Dry run (no --apply). Merges went into this run's own base branch, so only this run's PR is judged: clean, exit 0.
    // Non-vacuity: the merged PR really is a merged t/* PR whose base is the run branch, so the script had it to judge.
    const merged = JSON.parse(ghRead(['api', `repos/${run.codeRepo}/pulls/${pr}`]));
    assert.ok(merged.merged_at && merged.base.ref === run.config.repos.api.default && merged.head.ref.startsWith('t/'), 'PR merged into the run base');
    const pm = run.exec('reconcile', ['--core-dir', run.coreDir, '--post-merge']);
    assert.equal(pm.code, 0, `post-merge: ${pm.stdout} ${pm.stderr}`);
    assert.deepEqual(pm.json.staleMerges, []);
    assert.deepEqual(pm.json.unverifiable, []);
  } finally { await closeRun(run); }
});
