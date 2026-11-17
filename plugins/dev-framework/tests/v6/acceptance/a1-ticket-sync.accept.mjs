// A1: ticket-sync against the real sandbox. Needs DEVFW_SANDBOX_CORE / DEVFW_SANDBOX_CODE (see README.md).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { openRun, closeRun, eventually } from './harness.mjs';

const ghJson = (args) => {
  const r = spawnSync('gh', ['api', '--paginate', ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`gh api ${args[0]} failed: ${r.stderr}`);
  return JSON.parse(`[${r.stdout.replace(/\]\s*\[/g, '],[')}]`).flat();
};
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

test('A1: ticket-sync', async () => {
  const run = await openRun();
  try {
    const id = (n) => `P-${run.runId}-${n}`;
    const core = process.env.DEVFW_SANDBOX_CORE;
    const first = run.exec('ticket-sync', ['--core-dir', run.coreDir, '--apply']);
    assert.equal(first.code, 0, `apply: ${first.stdout} ${first.stderr}`);
    assert.equal(first.json.created.length, 3);

    const issues = await eventually(() => {
      const rows = ghJson([`repos/${core}/issues?state=open&per_page=100&labels=epic:${run.runId}`]);
      assert.equal(rows.length, 3, `3 issues expected, got ${rows.length}`);
      return rows;
    });
    for (const n of [1, 2, 3]) {
      const iss = issues.find((i) => i.title.startsWith(`${id(n)} `));
      assert.ok(iss, `issue for ${id(n)}`);
      const names = iss.labels.map((l) => l.name);
      for (const want of [`plan:${id(n)}`, `epic:${run.runId}`, 'repo:api']) assert.ok(names.includes(want), `${id(n)} label ${want} in ${names}`);
      assert.equal(iss.milestone && iss.milestone.title, 'Stage A', `${id(n)} milestone`);
      assert.match(iss.body.replace(/\r/g, '').split('\n')[0], /^> Mirror of /, `${id(n)} banner on line 1`);
    }

    const second = await eventually(() => {
      const r = run.exec('ticket-sync', ['--core-dir', run.coreDir, '--apply']);
      assert.equal(r.code, 0, `second apply: ${r.stdout} ${r.stderr}`);
      assert.deepEqual(r.json.missing, []);
      assert.deepEqual(r.json.drift, []);
      return r;
    });
    assert.deepEqual(second.json.created ?? [], []);

    const wb = run.exec('ticket-sync', ['--core-dir', run.coreDir, '--writeback']);
    assert.ok(wb.json && wb.json.writeback === 3, `writeback: ${wb.stdout} ${wb.stderr}`);
    const plan = fs.readFileSync(path.join(run.coreDir, 'docs', 'plan', 'PLAN.md'), 'utf8');
    const lines = plan.split('\n').filter((l) => l.startsWith('- ticket:'));
    assert.equal(lines.length, 3);
    for (const l of lines) assert.match(l.trimEnd(), new RegExp(`^- ticket: ${escapeRe(core)}#\\d+$`));
  } finally { await closeRun(run); }
});
