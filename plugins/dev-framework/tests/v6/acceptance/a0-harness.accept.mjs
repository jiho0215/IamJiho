// A0: the harness itself. Needs DEVFW_SANDBOX_CORE / DEVFW_SANDBOX_CODE (see README.md).
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { openRun, closeRun, SandboxError, listBranches, execIn } from './harness.mjs';

const ids = (run) => [1, 2, 3].map((n) => `P-${run.runId}-${n}`);

test('A0: harness', async (t) => {
  await t.test('a repo without the DEVFW_SANDBOX marker is refused and nothing is written', async () => {
    const notSandbox = process.env.DEVFW_SANDBOX_CODE; // the code repo deliberately carries no marker
    const before = listBranches(notSandbox);
    await assert.rejects(() => openRun({ coreRepo: notSandbox, codeRepo: process.env.DEVFW_SANDBOX_CORE }), SandboxError);
    assert.deepEqual(listBranches(notSandbox), before, 'no new branch may appear in the refused repo');
  });

  await t.test('a code repo the core marker does not list is refused and gets no branch', async () => {
    // Same repo as the sandbox code repo, spelled in upper case: GitHub resolves it, but the marker lists it exactly.
    const unlisted = process.env.DEVFW_SANDBOX_CODE.toUpperCase();
    const heads = () => execFileSync('git', ['ls-remote', '--heads', `https://github.com/${unlisted}.git`], { encoding: 'utf8' });
    const before = heads();
    await assert.rejects(() => openRun({ codeRepo: unlisted }), (e) => e instanceof SandboxError && /not listed/.test(e.message));
    assert.equal(heads(), before, 'no new branch may appear in the unlisted code repo');
  });

  await t.test('a hand-built run object cannot exec scripts or close issues', async () => {
    const forged = {
      runId: 'rforged000aaa', coreDir: '.', codeDir: '.', tmp: path.join(os.tmpdir(), 'devfw-forged-none'),
      coreRepo: process.env.DEVFW_SANDBOX_CORE, codeRepo: process.env.DEVFW_SANDBOX_CODE, env: process.env,
    };
    assert.throws(() => execIn(forged, 'ticket-sync', ['--core-dir', '.']), SandboxError);
    await assert.rejects(() => closeRun(forged), SandboxError);
  });

  const runs = [];
  t.after(async () => { for (const r of runs) await closeRun(r); });

  await t.test('openRun builds a run the real scripts can read', async () => {
    const run = await openRun();
    runs.push(run);
    assert.match(run.runId, /^r\d{12}[a-z]{3}$/);
    assert.ok(listBranches(process.env.DEVFW_SANDBOX_CORE).includes(`run/${run.runId}`), 'core branch run/<runId> exists');
    const r = run.exec('ticket-sync', ['--core-dir', run.coreDir]);
    assert.equal(r.code, 7, `ticket-sync exit: ${r.stdout} ${r.stderr}`);
    assert.deepEqual([...r.json.missing].sort(), ids(run));
  });

  await t.test('a second run is not confused by the first', async () => {
    const first = runs[0];
    assert.ok(first, 'the previous scenario must have produced a run');
    const second = await openRun();
    runs.push(second);
    assert.notEqual(second.runId, first.runId);
    const r = second.exec('ticket-sync', ['--core-dir', second.coreDir]);
    assert.equal(r.code, 7, `ticket-sync exit: ${r.stdout} ${r.stderr}`);
    assert.deepEqual([...r.json.missing].sort(), ids(second));
  });
});
