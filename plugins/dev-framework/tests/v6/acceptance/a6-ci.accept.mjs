// A6: on a ci:required repo, merge-gate refuses a PR with no checks attached, passes once a success status is posted,
// and refuses again when the latest status is a failure. The ci:required config is a variant file in the run's temp dir.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { openRun, closeRun, eventually, ghWrite } from './harness.mjs';
import { ghRead, syncTickets, claimCommitPr, gate } from './ticket-flow.mjs';

test('A6: CI', async () => {
  const run = await openRun();
  try {
    const num = await syncTickets(run);
    const issue = num.get(`P-${run.runId}-2`);
    const { pr } = await claimCommitPr(run, issue, 'version', 'src/version.js');
    const sha = JSON.parse(ghRead(['api', `repos/${run.codeRepo}/pulls/${pr}`])).head.sha;

    const variant = JSON.parse(JSON.stringify(run.config));
    variant.repos.api.ci = 'required';
    delete variant.repos.api.tests;
    const variantFile = path.join(run.tmp, 'ci-required.json');
    fs.writeFileSync(variantFile, JSON.stringify(variant, null, 2) + '\n');
    const ciReq = { env: { DEVFW_CONFIG: variantFile } };

    // Control: under the run's own ci:none config the same PR passes (Evidence names the test command), so only ci differs.
    await eventually(() => {
      const r = gate(run, pr);
      assert.equal(r.json && r.json.pass, true, `control gate: ${r.stdout} ${r.stderr}`);
    });

    // (a) nothing attached.
    const none = await eventually(() => {
      const r = gate(run, pr, ciReq);
      assert.equal(r.json && r.json.pass, false, `gate with no checks: ${r.stdout} ${r.stderr}`);
      assert.ok(r.json.reasons.includes('ci: no checks attached'), `reasons: ${JSON.stringify(r.json.reasons)}`);
      return r;
    });
    assert.equal(none.code, 6);

    const post = (state) => ghWrite(run, ['api', '-X', 'POST', `repos/${run.codeRepo}/statuses/${sha}`,
      '-f', `state=${state}`, '-f', 'context=sandbox/ci', '-f', `description=acceptance ${run.runId}`]);

    // (b) a success status on the head: one write, then the gate passes.
    post('success');
    const ok = await eventually(() => {
      const r = gate(run, pr, ciReq);
      assert.equal(r.json && r.json.pass, true, `gate with success status: ${r.stdout} ${r.stderr}`);
      return r;
    });
    assert.equal(ok.code, 0);

    // (c) the latest status for that context is a failure: refused again.
    post('failure');
    const bad = await eventually(() => {
      const r = gate(run, pr, ciReq);
      assert.equal(r.json && r.json.pass, false, `gate with failure status: ${r.stdout} ${r.stderr}`);
      assert.ok(r.json.reasons.some((x) => x.startsWith('ci:') && x.includes('sandbox/ci') && x.includes('failure')), `reasons: ${JSON.stringify(r.json.reasons)}`);
      return r;
    });
    assert.equal(bad.code, 6);
  } finally { await closeRun(run); }
});
