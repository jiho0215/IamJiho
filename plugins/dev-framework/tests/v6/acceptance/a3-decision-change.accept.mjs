// A3: a cited decision changes -> needs-ack and merge refusal; a STALE-sha ack changes nothing; the right ack clears both.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { openRun, closeRun, eventually, gitWrite } from './harness.mjs';
import { gitRead, ghRead, syncTickets, claimCommitPr, gate, postAck } from './ticket-flow.mjs';

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
    gitRead(run.coreDir, ['checkout', '-q', `run/${run.runId}`]);
    const oldSha = gitRead(run.coreDir, ['rev-parse', 'HEAD']).trim();           // the plan before the change
    fs.writeFileSync(file, text.replace('The ping endpoint answers with the text ok.', 'The ping endpoint answers with JSON {"ok":true}.'));
    gitRead(run.coreDir, ['add', 'docs/plan/DECISIONS.md']);
    gitRead(run.coreDir, ['commit', '-q', '-m', `change D-1 ${run.runId}`]);
    gitWrite(run, run.coreDir, ['push', '-q', 'origin', `run/${run.runId}`]);
    const newSha = gitRead(run.coreDir, ['rev-parse', 'HEAD']).trim();
    assert.notEqual(oldSha, newSha);

    const row = () => {
      const r = run.exec('reconcile', ['--core-dir', run.coreDir]);
      const x = r.json && r.json.items && r.json.items.find((i) => i.id === id);
      assert.ok(x, `reconcile: ${r.stdout} ${r.stderr}`);
      return x;
    };
    const needsAck = () => {
      const x = row();
      assert.equal(x.state, 'needs-ack', `state: ${JSON.stringify(x)}`);
      assert.match(x.why, /D-1/, 'why names D-1');
    };
    const refused = () => {
      const g = gate(run, pr);
      assert.equal(g.json && g.json.pass, false, `gate: ${g.stdout}`);
      assert.equal(g.code, 6);
      assert.ok(g.json.reasons.some((x) => x.startsWith('cites:') && x.includes('D-1')), `reasons: ${g.json.reasons}`);
    };
    await eventually(needsAck);
    refused();

    // A stale ack (the plan sha from BEFORE the change hashes D-1 to the old value) must not clear anything.
    // One write, outside eventually(). Then a read-only stable window: both must stay refused.
    postAck(run, issue, oldSha, 'stale');
    // Non-vacuity: the window below only means something once the stale ack is readable, so wait (read-only) until a
    // direct comments read shows it.
    const staleBody = `ack ${issue} ${oldSha}: stale`;
    await eventually(() => {
      const comments = JSON.parse(ghRead(['api', `repos/${run.coreRepo}/issues/${issue}/comments?per_page=100`]));
      assert.ok(comments.some((c) => String(c.body || '').trim() === staleBody), `stale ack not visible yet (${comments.length} comments)`);
    });
    for (let i = 0; i < 4; i++) {
      await new Promise((r) => setTimeout(r, 2500));
      needsAck();
      refused();
    }

    // The right ack (the new plan sha), also one write.
    postAck(run, issue, newSha, 'no impact');
    await eventually(() => {
      const x = row();
      assert.notEqual(x.state, 'needs-ack', `still needs-ack: ${JSON.stringify(x)}`);
      assert.equal(x.state, 'in-review');
    });
    const g2 = await eventually(() => {
      const r = gate(run, pr);
      assert.equal(r.json && r.json.pass, true, `gate after ack: ${r.stdout} ${r.stderr}`);
      return r;
    });
    assert.equal(g2.code, 0);
  } finally { await closeRun(run); }
});
