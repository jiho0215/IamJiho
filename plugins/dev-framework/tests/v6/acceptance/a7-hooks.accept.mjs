// A7: the PreToolUse hook contract Plan 3 must satisfy (see HOOK-CONTRACT.md). Written first, so it is red
// until plan-edit-guard.sh and merge-gate-hook.sh exist; the first assertion names the missing script.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { openRun, closeRun, eventually } from './harness.mjs';
import { syncTickets, claimCommitPr, issueCites, gate } from './ticket-flow.mjs';

const SCRIPTS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'hooks', 'scripts');
const EDIT_GUARD = path.join(SCRIPTS, 'plan-edit-guard.sh');
const MERGE_HOOK = path.join(SCRIPTS, 'merge-gate-hook.sh');

function hook(run, script, toolName, toolInput) {
  const payload = JSON.stringify({ tool_name: toolName, tool_input: toolInput, cwd: run.coreDir, session_id: `accept-${run.runId}` });
  const r = spawnSync('bash', [script], {
    input: payload, encoding: 'utf8',
    env: { ...run.env, DEVFW_CORE_DIR: run.coreDir, DEVFW_CONFIG: path.join(run.coreDir, 'orchestrator.json') },
  });
  return { code: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

test('A7: plan-edit and merge hooks', async () => {
  for (const [rel, file] of [['hooks/scripts/plan-edit-guard.sh', EDIT_GUARD], ['hooks/scripts/merge-gate-hook.sh', MERGE_HOOK]]) {
    assert.ok(fs.existsSync(file), `hook script not found: ${rel}`);
  }
  const run = await openRun();
  try {
    // plan-edit-guard: the local lease token must equal the run branch's lease line.
    const planFile = path.join(run.coreDir, 'docs', 'plan', 'PLAN.md');
    const leaseFile = path.join(run.coreDir, '.orchestrator', 'lease');
    const edit = (file) => hook(run, EDIT_GUARD, 'Edit', { file_path: file });
    const owned = fs.readFileSync(leaseFile, 'utf8');
    assert.equal(edit(planFile).code, 0, 'equal tokens allow the edit');
    fs.writeFileSync(leaseFile, 'ffffffffffffffff\n');
    const blocked = edit(planFile);
    assert.equal(blocked.code, 2, `lease mismatch blocks: ${blocked.stdout} ${blocked.stderr}`);
    assert.match(blocked.stderr, /lease/i, 'stderr names the lease');
    const outside = edit(path.join(run.coreDir, 'README.md'));
    assert.equal(outside.code, 0, `a file outside docs/plan is allowed: ${outside.stderr}`);
    fs.writeFileSync(leaseFile, owned);

    // merge-gate-hook: a PR the gate refuses, a PR it passes, and a command that is not a merge.
    const num = await syncTickets(run);
    const bad = await claimCommitPr(run, num.get(`P-${run.runId}-3`), 'refused', 'src/refused.js', {
      cites: (await issueCites(run, num.get(`P-${run.runId}-3`))).replace(/@[0-9a-f]+/gi, (m) => `@${'0'.repeat(m.length - 1)}`),
    });
    const good = await claimCommitPr(run, num.get(`P-${run.runId}-2`), 'passing', 'src/passing.js');
    const merge = (pr) => hook(run, MERGE_HOOK, 'Bash', { command: `gh pr merge ${pr} --repo ${run.codeRepo} --squash` });

    const refusal = await eventually(() => {
      const g = gate(run, bad.pr);
      assert.equal(g.json && g.json.pass, false, `gate: ${g.stdout} ${g.stderr}`);
      return g.json.reasons[0];
    });
    const refused = merge(bad.pr);
    assert.equal(refused.code, 2, `refused PR blocks: ${refused.stdout} ${refused.stderr}`);
    assert.ok(refused.stderr.includes(refusal), `stderr carries the gate's first reason (${refusal}): ${refused.stderr}`);

    await eventually(() => { assert.equal(gate(run, good.pr).json && gate(run, good.pr).json.pass, true, 'gate passes the good PR'); });
    const passed = merge(good.pr);
    assert.equal(passed.code, 0, `passing PR allowed: ${passed.stderr}`);

    const view = hook(run, MERGE_HOOK, 'Bash', { command: `gh pr view ${good.pr} --repo ${run.codeRepo}` });
    assert.equal(view.code, 0, `a non-merge command is allowed: ${view.stderr}`);
  } finally { await closeRun(run); }
});
