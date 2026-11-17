// A5: a merge that bypassed merge-gate (a "web" merge) is caught after the fact by reconcile --post-merge:
// stale cites, and a PR from the wrong ticket branch (the I2 residual).
import test from 'node:test';
import assert from 'node:assert/strict';
import { openRun, closeRun, eventually, ghWrite } from './harness.mjs';
import { ghRead, syncTickets, claimCommitPr, mergePr, issueCites } from './ticket-flow.mjs';

test('A5: stale merge', async () => {
  const run = await openRun();
  try {
    const num = await syncTickets(run);
    const issue3 = num.get(`P-${run.runId}-3`);
    const issue1 = num.get(`P-${run.runId}-1`);
    const pm = (apply) => run.exec('reconcile', ['--core-dir', run.coreDir, '--post-merge', ...(apply ? ['--apply'] : [])]);
    const trackers = () => JSON.parse(`[${ghRead(['api', '--paginate', `repos/${run.coreRepo}/issues?state=all&labels=merged-stale&per_page=100`])
      .replace(/\]\s*\[/g, '],[')}]`).flat().filter((i) => !i.pull_request);

    // PR 1: the right branch, but every cited hash is one the plan never had. Merged directly, bypassing merge-gate.
    const real = await issueCites(run, issue3);
    const fake = real.replace(/@[0-9a-f]+/gi, (m) => `@${'0'.repeat(m.length - 1)}`);
    assert.notEqual(fake, real, 'the fake cites differ from the real ones');
    assert.match(fake, /@0+/, 'the issue cites at least one hash to corrupt');
    const first = await claimCommitPr(run, issue3, 'log', 'src/log.js', { cites: fake });
    mergePr(run, first.pr);
    const title1 = `merged-stale: ${run.codeRepo}#${first.pr}`;

    // Read-only until the merge is visible to the post-merge listing; the single write comes after.
    await eventually(() => {
      const r = pm(false);
      assert.equal(r.code, 9, `dry post-merge: ${r.stdout} ${r.stderr}`);
      assert.deepEqual(r.json.staleMerges.map((s) => s.pr), [first.pr]);
    });
    const a = pm(true);
    assert.equal(a.code, 9, `post-merge --apply: ${a.stdout} ${a.stderr}`);
    assert.deepEqual(a.json.created, [title1], 'exactly one tracking issue is opened');
    assert.ok(a.json.staleMerges[0].reasons.some((x) => x.startsWith('cites:') && x.includes('is stale')), `reasons: ${a.stdout}`);
    const tracker = await eventually(() => {
      const rows = trackers().filter((i) => i.title === title1);
      assert.equal(rows.length, 1, `tracking issues titled ${title1}: ${rows.length}`);
      return rows[0];
    });
    assert.equal(tracker.state, 'open');

    // A second run opens nothing: still exit 9 (nobody has resolved it), created empty.
    const b = pm(true);
    assert.equal(b.code, 9, `second post-merge: ${b.stdout} ${b.stderr}`);
    assert.deepEqual(b.json.created, []);
    assert.deepEqual(b.json.staleMerges.map((s) => s.pr), [first.pr]);
    assert.equal(trackers().filter((i) => i.title === title1).length, 1, 'still exactly one tracking issue');

    // A person closes it: the third run exits 0 with the PR under resolved.
    ghWrite(run, ['api', '-X', 'PATCH', `repos/${run.coreRepo}/issues/${tracker.number}`, '-f', 'state=closed']);
    const c = await eventually(() => {
      const r = pm(false);
      assert.equal(r.code, 0, `third post-merge: ${r.stdout} ${r.stderr}`);
      return r;
    });
    assert.deepEqual(c.json.staleMerges, []);
    assert.deepEqual(c.json.resolved.map((x) => [x.repo, x.pr, x.issue]), [[run.codeRepo, first.pr, tracker.number]]);

    // The I2 residual: PR 2 comes from the wrong claim branch (issue 1's), names this ticket, and its hashes are right.
    const second = await claimCommitPr(run, issue1, 'wrong', 'src/wrong.js', { fixes: issue3, cites: real });
    assert.ok(second.branch.startsWith(`t/${issue1}-`) && issue1 !== issue3);
    mergePr(run, second.pr);
    // Dry run only: no tracking issue is left behind for this one.
    const d = await eventually(() => {
      const r = pm(false);
      assert.equal(r.code, 9, `post-merge after PR 2: ${r.stdout} ${r.stderr}`);
      assert.deepEqual(r.json.staleMerges.map((s) => s.pr), [second.pr]);
      return r;
    });
    const why = d.json.staleMerges[0].reasons;
    assert.ok(why.length > 0 && why.every((x) => x.startsWith('ticket:')), `reasons: ${JSON.stringify(why)}`);
    assert.ok(why.some((x) => x.includes(`t/${issue3}-`)), 'names the claim branch it wanted');
    assert.deepEqual(d.json.resolved.map((x) => x.pr), [first.pr], 'PR 1 stays resolved');
    assert.equal(trackers().filter((i) => i.title === `merged-stale: ${run.codeRepo}#${second.pr}`).length, 0, 'the dry run opened nothing');
  } finally { await closeRun(run); }
});
