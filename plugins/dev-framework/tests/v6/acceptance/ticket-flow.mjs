// Shared helpers for the ticket scenarios (A2, A3, A8). Not a scenario itself (the runner only globs *.accept.mjs).
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync, execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { eventually } from './harness.mjs';

export const gh = (args) => {
  const r = spawnSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`gh ${args.slice(0, 2).join(' ')} failed: ${r.stderr || r.stdout}`);
  return r.stdout;
};
const ID = ['-c', 'user.name=devfw-harness', '-c', 'user.email=devfw-harness@users.noreply.github.com'];
export const git = (dir, args) => execFileSync('git', ['-C', dir, ...ID, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

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
    const body = JSON.parse(gh(['api', `repos/${run.coreRepo}/issues/${issue}`])).body;
    const m = /^\s*(?:[-*]\s*)?\*{0,2}Cites:\*{0,2}\s*(.*)$/m.exec(body.replace(/\r/g, ''));
    assert.ok(m && m[1].trim(), 'issue body has a Cites line');
    return m[1].trim();
  });
}

// Claims t/<issue>-<slug> (one write), checks out the claim branch in run.codeDir, commits one file, pushes (fast-forward),
// and opens the PR with the design 6.7 body. Returns { branch, pr, cites }.
export async function claimCommitPr(run, issue, slug, file) {
  const base = run.config.repos.api.default;
  const claim = run.exec('claim', [String(issue), slug, '--repo-dir', run.codeDir, '--base', base]);
  assert.equal(claim.code, 0, `claim: ${claim.stdout} ${claim.stderr}`);
  const branch = `t/${issue}-${slug}`;
  await eventually(() => git(run.codeDir, ['fetch', '-q', 'origin', `+refs/heads/${branch}:refs/remotes/origin/${branch}`]));
  git(run.codeDir, ['checkout', '-q', '-b', branch, `origin/${branch}`]);
  fs.mkdirSync(path.dirname(path.join(run.codeDir, file)), { recursive: true });
  fs.writeFileSync(path.join(run.codeDir, file), `// ${run.runId} ${slug}\nmodule.exports = 'ok';\n`);
  git(run.codeDir, ['add', file]);
  git(run.codeDir, ['commit', '-q', '-m', `${slug} ${run.runId}`]);
  git(run.codeDir, ['push', '-q', 'origin', branch]);
  const cites = await issueCites(run, issue);
  const body = `Fixes ${run.coreRepo}#${issue}\nCites: ${cites}\nEvidence:\nnpm test — 1 passed\n`;
  const url = gh(['pr', 'create', '--repo', run.codeRepo, '--base', base, '--head', branch, '--title', `${slug} ${run.runId}`, '--body', body]).trim();
  const pr = Number(url.split('/').pop());
  assert.ok(pr > 0, `pr url: ${url}`);
  return { branch, pr, cites };
}

export const gate = (run, pr) => run.exec('merge-gate', ['--core-dir', run.coreDir, '--repo', run.codeRepo, '--pr', String(pr)]);
