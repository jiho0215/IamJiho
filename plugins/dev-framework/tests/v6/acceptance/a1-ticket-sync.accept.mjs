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

    // The second apply is a write: it runs exactly once, never inside eventually().
    const second = run.exec('ticket-sync', ['--core-dir', run.coreDir, '--apply']);
    assert.equal(second.code, 0, `second apply: ${second.stdout} ${second.stderr}`);
    assert.deepEqual(second.json.created, [], 'second apply creates nothing');
    assert.deepEqual(second.json.patched, [], 'second apply patches nothing');
    assert.deepEqual(second.json.drift, []);

    // Read-only: exactly one issue per plan label, and the count stays 3 across a stable window.
    const planLabelCounts = () => {
      const rows = ghJson([`repos/${core}/issues?state=all&per_page=100&labels=epic:${run.runId}`]);
      return [1, 2, 3].map((n) => rows.filter((i) => i.labels.some((l) => l.name === `plan:${id(n)}`)).length).concat(rows.length);
    };
    await eventually(() => assert.deepEqual(planLabelCounts(), [1, 1, 1, 3]));
    for (let i = 0; i < 5; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      assert.deepEqual(planLabelCounts(), [1, 1, 1, 3], 'issue count stays 3 (no late duplicates)');
    }
    const dry = run.exec('ticket-sync', ['--core-dir', run.coreDir]);
    assert.deepEqual(dry.json.missing, []);
    assert.deepEqual(dry.json.drift, []);

    const wb = run.exec('ticket-sync', ['--core-dir', run.coreDir, '--writeback']);
    assert.ok(wb.json && wb.json.writeback === 3, `writeback: ${wb.stdout} ${wb.stderr}`);
    const plan = fs.readFileSync(path.join(run.coreDir, 'docs', 'plan', 'PLAN.md'), 'utf8');
    const lines = plan.split('\n').filter((l) => l.startsWith('- ticket:'));
    assert.equal(lines.length, 3);
    const issueNo = new Map(first.json.created.map((c) => [c.id, c.issue]));
    for (const n of [1, 2, 3]) assert.ok(plan.includes(`- ticket: ${core}#${issueNo.get(id(n))}`), `${id(n)} ticket line carries its own issue number`);
    for (const l of lines) assert.match(l.trimEnd(), new RegExp(`^- ticket: ${escapeRe(core)}#\\d+$`));
  } finally { await closeRun(run); }
});
