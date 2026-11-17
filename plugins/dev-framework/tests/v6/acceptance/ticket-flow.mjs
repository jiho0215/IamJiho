// Shared helpers for the ticket scenarios (A2, A3, A8). Not a scenario itself (the runner only globs *.accept.mjs).
// Every write goes through the harness's verified-run guard; the raw gh/git wrappers here are read-only and refuse writes.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync, execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { eventually, ghWrite, gitWrite, assertVerifiedRun } from './harness.mjs';

const WRITE_FLAGS = new Set(['-X', '--method', '-f', '-F', '--field', '--raw-field', '--input']);
export const ghRead = (args) => {
  if (args.some((a) => WRITE_FLAGS.has(a)) || (args[0] !== 'api' && !(args[0] === 'repo' && args[1] === 'clone'))) {
    throw new Error(`ghRead refuses a non-read call: gh ${args.slice(0, 3).join(' ')}`);
  }
  const r = spawnSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`gh ${args.slice(0, 2).join(' ')} failed: ${r.stderr || r.stdout}`);
  return r.stdout;
};
const ID = ['-c', 'user.name=devfw-harness', '-c', 'user.email=devfw-harness@users.noreply.github.com'];
// Local or fetching git only: a push must go through gitWrite(run, ...).
export const gitRead = (dir, args) => {
  if (args.includes('push')) throw new Error('gitRead refuses push; use gitWrite(run, dir, args)');
  return execFileSync('git', ['-C', dir, ...ID, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
};

// ticket-sync --apply, then wait (read-only dry run) until the listing shows every issue. Returns Map(planId -> issue#).
export async function syncTickets(run) {
  const sync = run.exec('ticket-sync', ['--core-dir', run.coreDir, '--apply']);
  assert.equal(sync.code, 0, `ticket-sync: ${sync.stdout} ${sync.stderr}`);
  const num = new Map(sync.json.created.map((c) => [c.id, c.issue]));
  assert.equal(num.size, 3);
  await eventually(() => {
    const r = run.exec('ticket-sync', ['--core-dir', run.coreDir]);
    assert.deepEqual(r.json && r.json.missing, [], `listing not settled: ${r.stdout}`);
  });
  return num;
}

// The issue's own Cites line (every ID@hash), read from GitHub.
export async function issueCites(run, issue) {
  return eventually(() => {
    const body = JSON.parse(ghRead(['api', `repos/${run.coreRepo}/issues/${issue}`])).body;
    const m = /^\s*(?:[-*]\s*)?\*{0,2}Cites:\*{0,2}\s*(.*)$/m.exec(body.replace(/\r/g, ''));
    assert.ok(m && m[1].trim(), 'issue body has a Cites line');
    return m[1].trim();
  });
}

// Claims t/<issue>-<slug> off the run's base branch (one write), checks the claim branch out in run.codeDir, commits one
// file, pushes (fast-forward), and opens the PR into the run's base with the design 6.7 body. Returns { branch, pr, cites }.
export async function claimCommitPr(run, issue, slug, file) {
  assertVerifiedRun(run);
  const base = run.config.repos.api.default;
  const claim = run.exec('claim', [String(issue), slug, '--repo-dir', run.codeDir, '--base', base]); // guarded by execIn
  assert.equal(claim.code, 0, `claim: ${claim.stdout} ${claim.stderr}`);
  const branch = `t/${issue}-${slug}`;
  await eventually(() => gitRead(run.codeDir, ['fetch', '-q', 'origin', `+refs/heads/${branch}:refs/remotes/origin/${branch}`]));
  gitRead(run.codeDir, ['checkout', '-q', '-b', branch, `origin/${branch}`]);
  fs.mkdirSync(path.dirname(path.join(run.codeDir, file)), { recursive: true });
  fs.writeFileSync(path.join(run.codeDir, file), `// ${run.runId} ${slug}\nmodule.exports = 'ok';\n`);
  gitRead(run.codeDir, ['add', file]);
  gitRead(run.codeDir, ['commit', '-q', '-m', `${slug} ${run.runId}`]);
  gitWrite(run, run.codeDir, ['push', '-q', 'origin', branch]);
  const cites = await issueCites(run, issue);
  const body = `Fixes ${run.coreRepo}#${issue}\nCites: ${cites}\nEvidence:\nnpm test \u2014 1 passed\n`;
  const url = ghWrite(run, ['pr', 'create', '--repo', run.codeRepo, '--base', base, '--head', branch, '--title', `${slug} ${run.runId}`, '--body', body]).trim();
  const pr = Number(url.split('/').pop());
  assert.ok(pr > 0, `pr url: ${url}`);
  return { branch, pr, cites };
}

// Owner ack comment on the plan issue, posted as the authenticated user.
export const postAck = (run, issue, planSha, text) =>
  ghWrite(run, ['api', '-X', 'POST', `repos/${run.coreRepo}/issues/${issue}/comments`, '-f', `body=ack ${issue} ${planSha}: ${text}`]);

// Squash merge into the run's base branch of the sandbox code repo. Never --auto, never --delete-branch.
export const mergePr = (run, pr) => ghWrite(run, ['pr', 'merge', String(pr), '--repo', run.codeRepo, '--squash']);

export const gate = (run, pr) => run.exec('merge-gate', ['--core-dir', run.coreDir, '--repo', run.codeRepo, '--pr', String(pr)]);
