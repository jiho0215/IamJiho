// A2: six concurrent claims on one ticket, each from its own fresh clone, against real GitHub. Exactly one wins.
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { openRun, closeRun, execAsyncIn, eventually } from './harness.mjs';
import { ghRead, syncTickets } from './ticket-flow.mjs';

test('A2: claim race', async () => {
  const run = await openRun();
  try {
    const num = await syncTickets(run);
    const issue = num.get(`P-${run.runId}-1`);
    const base = run.config.repos.api.default;
    const clones = [];
    for (let k = 0; k < 6; k++) {
      const dir = path.join(run.tmp, `race-${k}`);
      ghRead(['repo', 'clone', run.codeRepo, dir, '--', '-q']);
      clones.push(dir);
    }
    // The six claims start together; each is one write against GitHub and runs exactly once.
    const results = await Promise.all(clones.map((dir) =>
      execAsyncIn(run, 'claim', [String(issue), 'race', '--repo-dir', dir, '--base', base])));
    const codes = results.map((r) => r.code).sort();
    assert.deepEqual(codes, [0, 3, 3, 3, 3, 3], `exit codes: ${results.map((r) => `${r.code} ${r.stderr.trim()}`).join(' | ')}`);
    const winner = results.find((r) => r.code === 0);
    assert.ok(winner.json && winner.json.result === 'claimed', `winner output: ${winner.stdout}`);
    for (const r of results.filter((x) => x.code === 3)) assert.equal(r.json && r.json.result, 'lost', `loser output: ${r.stdout}`);
    // Reported, not required: how many losers reached the create-only push (real GitHub timing varies run to run).
    const pushLosers = results.filter((x) => x.code === 3 && x.json && x.json.lostAt === 'push').length;
    console.log(`A2: ${pushLosers} of 5 losers lost at the create-only push (lostAt: push); the rest at the precheck`);

    // Read-only: the ref on GitHub sits at the winner's commit. (Retried: reads can lag a push.)
    const ref = `refs/heads/t/${issue}-race`;
    await eventually(() => {
      const out = execFileSync('git', ['ls-remote', `https://github.com/${run.codeRepo}.git`, `refs/heads/t/${issue}-*`], { encoding: 'utf8' });
      const rows = out.trim().split('\n').filter(Boolean).map((l) => l.split('\t'));
      assert.deepEqual(rows, [[winner.json.sha, ref]]);
    });
  } finally { await closeRun(run); }
});
