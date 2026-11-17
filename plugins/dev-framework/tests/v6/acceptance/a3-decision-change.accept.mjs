// A3: a cited decision changes -> needs-ack and merge refusal; an owner ack clears both.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { openRun, closeRun, eventually } from './harness.mjs';
import { gh, git, syncTickets, claimCommitPr, gate } from './ticket-flow.mjs';

test('A3: decision change', async () => {
  const run = await openRun();
  try {
    const num = await syncTickets(run);
    const id = `P-${run.runId}-1`;
    const issue = num.get(id);
    const { pr, cites } = await claimCommitPr(run, issue, 'ping', 'src/ping.js');
    assert.match(cites, /D-1@/, 'the issue cites D-1');

    const g0 = await eventually(() => {
      const r = gate(run, pr);
      assert.equal(r.json && r.json.pass, true, `gate before change: ${r.stdout} ${r.stderr}`);
      return r;
    });
    assert.equal(g0.code, 0);

    // The decision changes on the plan branch (a direct commit stands in for a merged plan PR).
    const file = path.join(run.coreDir, 'docs', 'plan', 'DECISIONS.md');
    const text = fs.readFileSync(file, 'utf8');
    assert.ok(text.includes('The ping endpoint answers with the text ok.'));
    git(run.coreDir, ['checkout', '-q', `run/${run.runId}`]);
    fs.writeFileSync(file, text.replace('The ping endpoint answers with the text ok.', 'The ping endpoint answers with JSON {"ok":true}.'));
    git(run.coreDir, ['add', 'docs/plan/DECISIONS.md']);
    git(run.coreDir, ['commit', '-q', '-m', `change D-1 ${run.runId}`]);
    git(run.coreDir, ['push', '-q', 'origin', `run/${run.runId}`]);
    const newSha = git(run.coreDir, ['rev-parse', 'HEAD']).trim();

    const rec = await eventually(() => {
      const r = run.exec('reconcile', ['--core-dir', run.coreDir]);
      const row = r.json && r.json.items && r.json.items.find((i) => i.id === id);
      assert.ok(row, `reconcile: ${r.stdout} ${r.stderr}`);
      assert.equal(row.state, 'needs-ack', `state after the change: ${JSON.stringify(row)}`);
      return row;
    });
    assert.match(rec.why, /D-1/, 'why names D-1');
    const g1 = gate(run, pr);
    assert.equal(g1.json && g1.json.pass, false, `gate after change: ${g1.stdout}`);
    assert.equal(g1.code, 6);
    assert.ok(g1.json.reasons.some((x) => x.startsWith('cites:') && x.includes('D-1')), `reasons: ${g1.json.reasons}`);

    // The owner's ack (a write: once), posted as the authenticated user, who owns the sandbox repo.
    gh(['api', '-X', 'POST', `repos/${run.coreRepo}/issues/${issue}/comments`, '-f', `body=ack ${issue} ${newSha}: no impact`]);

    await eventually(() => {
      const r = run.exec('reconcile', ['--core-dir', run.coreDir]);
      const row = r.json && r.json.items && r.json.items.find((i) => i.id === id);
      assert.ok(row, `reconcile: ${r.stdout} ${r.stderr}`);
      assert.notEqual(row.state, 'needs-ack', `still needs-ack: ${JSON.stringify(row)}`);
      assert.equal(row.state, 'in-review');
    });
    const g2 = await eventually(() => {
      const r = gate(run, pr);
      assert.equal(r.json && r.json.pass, true, `gate after ack: ${r.stdout} ${r.stderr}`);
      return r;
    });
    assert.equal(g2.code, 0);
  } finally { await closeRun(run); }
});
