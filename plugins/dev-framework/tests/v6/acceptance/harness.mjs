// Acceptance harness: drives the real v6 scripts against a real GitHub sandbox.
// Sandbox repos come only from env (DEVFW_SANDBOX_CORE / DEVFW_SANDBOX_CODE, "owner/name"); no name is committed.
// Every write path first proves the core repo carries the DEVFW_SANDBOX marker on its default branch.
import { spawnSync, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.resolve(HERE, '..', '..', '..');
const MARKER = 'DEVFW_SANDBOX';
const NODE_SCRIPTS = new Set(['ticket-sync', 'reconcile', 'impact', 'merge-gate', 'waiting', 'new-ticket']);
const BASH_SCRIPTS = new Set(['claim', 'lease', 'plan-hash', 'pr-size', 'stop-check']);
const HARNESS_DELAY_MS = 1000;
const GIT_ID = ['-c', 'user.name=devfw-harness', '-c', 'user.email=devfw-harness@users.noreply.github.com'];

export class SandboxError extends Error {
  constructor(msg) { super(msg); this.name = 'SandboxError'; }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const OWNER_NAME = /^[\w.-]+\/[\w.-]+$/;

function gh(args, { allowFail = false } = {}) {
  const r = spawnSync('gh', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0 && !allowFail) throw new Error(`gh ${args.slice(0, 3).join(' ')} failed: ${(r.stderr || r.stdout || '').trim()}`);
  return r;
}
function git(dir, args) {
  return execFileSync('git', ['-C', dir, ...GIT_ID, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

export function listBranches(repo) {
  const out = gh(['api', '--paginate', `repos/${repo}/branches?per_page=100`, '--jq', '.[].name']).stdout;
  return out.split('\n').map((s) => s.trim()).filter(Boolean).sort();
}

function resolveRepos({ coreRepo, codeRepo } = {}) {
  const core = coreRepo || process.env.DEVFW_SANDBOX_CORE;
  const code = codeRepo || process.env.DEVFW_SANDBOX_CODE;
  if (!core || !code) throw new SandboxError('DEVFW_SANDBOX_CORE and DEVFW_SANDBOX_CODE must be set');
  for (const r of [core, code]) if (!OWNER_NAME.test(r)) throw new SandboxError(`not an owner/name repo: ${r}`);
  if (core === code) throw new SandboxError('the core and code sandbox repos must differ');
  return { core, code };
}

// Read-only. The marker must exist on the repo's DEFAULT branch (no ref given to the contents API).
function hasMarker(repo) {
  return gh(['api', `repos/${repo}/contents/${MARKER}`], { allowFail: true }).status === 0;
}
function assertSandbox(repo) {
  if (!hasMarker(repo)) throw new SandboxError(`${repo} has no ${MARKER} file on its default branch: refusing to write`);
}

function runIdNow() {
  const d = new Date().toISOString().replace(/\D/g, '').slice(0, 12);
  const rnd = [...crypto.randomBytes(3)].map((b) => String.fromCharCode(97 + (b % 26))).join('');
  return `r${d}${rnd}`;
}

export async function openRun(opts = {}) {
  const { core, code } = resolveRepos(opts);
  assertSandbox(core);                                   // before anything is cloned, created or pushed
  const runId = runIdNow();
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), `devfw-accept-${runId}-`));
  const coreDir = path.join(tmp, 'core');
  const codeDir = path.join(tmp, 'code');
  gh(['repo', 'clone', core, coreDir, '--', '-q']);
  gh(['repo', 'clone', code, codeDir, '--', '-q']);
  const codeDefault = git(codeDir, ['rev-parse', '--abbrev-ref', 'HEAD']).trim();

  git(coreDir, ['checkout', '-q', '-b', `run/${runId}`]);
  const planDir = path.join(coreDir, 'docs', 'plan');
  fs.mkdirSync(planDir, { recursive: true });
  const tpl = fs.readFileSync(path.join(HERE, 'fixtures', 'plan-template.md'), 'utf8');
  fs.writeFileSync(path.join(planDir, 'PLAN.md'), tpl.replaceAll('{{RUN}}', runId));
  fs.writeFileSync(path.join(planDir, 'DECISIONS.md'),
    '# Decisions\n\n### D-1 · Ping answers plain ok\nThe ping endpoint answers with the text ok.\n\n### D-2 · Version comes from package metadata\nThe version endpoint reads the package version.\n');
  const token = crypto.randomBytes(8).toString('hex');
  const since = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  fs.writeFileSync(path.join(planDir, 'START-HERE.md'), `orchestrator: ${token} · devfw-harness · since ${since}\n\nAcceptance run ${runId}.\n`);
  fs.mkdirSync(path.join(coreDir, '.orchestrator'), { recursive: true });
  fs.writeFileSync(path.join(coreDir, '.orchestrator', 'lease'), token + '\n'); // local only, never committed
  const config = {
    plan: { repo: core, path: 'docs/plan', branch: `run/${runId}` },
    repos: { api: { github: code, default: codeDefault, label: 'api', ci: 'none', tests: ['npm test'] } },
    stages: { A: 'Stage A' },
    // project left unset (number 0): ticket-sync skips its Project step, so no GitHub Project is ever touched.
    github: { writeDelayMs: 1000, trustedAuthors: [] },
  };
  const configFile = path.join(coreDir, 'orchestrator.json');
  fs.writeFileSync(configFile, JSON.stringify(config, null, 2) + '\n');
  git(coreDir, ['add', 'docs/plan/PLAN.md', 'docs/plan/DECISIONS.md', 'docs/plan/START-HERE.md', 'orchestrator.json']);
  git(coreDir, ['commit', '-q', '-m', `acceptance run ${runId}`]);
  git(coreDir, ['push', '-q', '-u', 'origin', `run/${runId}`]);
  await sleep(HARNESS_DELAY_MS);

  const env = { ...process.env, DEVFW_CONFIG: configFile };
  const run = { runId, coreDir, codeDir, config, env, tmp, coreRepo: core, codeRepo: code };
  run.exec = (script, args = []) => execScript(run, script, args);
  return run;
}

function execScript(run, script, args) {
  const file = path.join(PLUGIN, 'bin', script);
  const cmd = NODE_SCRIPTS.has(script) ? ['node', [file, ...args]] : BASH_SCRIPTS.has(script) ? ['bash', [file, ...args]] : null;
  if (!cmd) throw new Error(`unknown plugin script: ${script}`);
  const r = spawnSync(cmd[0], cmd[1], { env: run.env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const stdout = r.stdout || '';
  let json = null;
  const last = stdout.split('\n').map((l) => l.trim()).filter(Boolean).pop();
  if (last) { try { json = JSON.parse(last); } catch { json = null; } }
  return { code: r.status, json, stdout, stderr: r.stderr || '' };
}

// Retries a READ assertion only. Never pass a write: it would be repeated.
export async function eventually(fn, { timeoutMs = 30000, everyMs = 2000 } = {}) {
  const end = Date.now() + timeoutMs;
  let lastErr;
  for (;;) {
    try { return await fn(); } catch (e) { lastErr = e; }
    if (Date.now() + everyMs > end) throw lastErr;
    await sleep(everyMs);
  }
}

// Close every open issue and PR labelled epic:<runId> or titled with the runId, in both sandbox repos.
export async function closeRun(run) {
  const closed = [];
  for (const repo of [run.coreRepo, run.codeRepo]) {
    const out = gh(['api', '--paginate', `repos/${repo}/issues?state=open&per_page=100`, '--jq', '.[] | {number, title, labels: [.labels[].name]}']).stdout;
    const rows = out.split('\n').map((s) => s.trim()).filter(Boolean).map((s) => JSON.parse(s));
    for (const iss of rows) {
      const labelled = iss.labels.includes(`epic:${run.runId}`);
      if (!labelled && !String(iss.title || '').includes(run.runId)) continue;
      gh(['api', '-X', 'PATCH', `repos/${repo}/issues/${iss.number}`, '-f', 'state=closed']);
      closed.push(`${repo}#${iss.number}`);
      await sleep(HARNESS_DELAY_MS);
    }
  }
  try { fs.rmSync(run.tmp, { recursive: true, force: true, maxRetries: 3 }); } catch { /* an OS-locked dir is left for the temp cleaner */ }
  return closed;
}

// One-time: the marker goes to the CORE repo's default branch only (a normal push).
export async function initSandbox(opts = {}) {
  const { core, code } = resolveRepos(opts);
  if (hasMarker(core)) return { created: false };
  if (hasMarker(code)) throw new SandboxError('the code repo already carries the marker; it must not');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'devfw-accept-init-'));
  try {
    const dir = path.join(tmp, 'core');
    gh(['repo', 'clone', core, dir, '--', '-q']);
    fs.writeFileSync(path.join(dir, MARKER), 'Throwaway sandbox for the dev-framework acceptance suite. Safe to write to.\n');
    git(dir, ['add', MARKER]);
    git(dir, ['commit', '-q', '-m', 'add DEVFW_SANDBOX marker']);
    git(dir, ['push', '-q', 'origin', 'HEAD']);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  return { created: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href && process.argv[2] === '--init') {
  initSandbox().then((r) => { console.log(r.created ? 'marker committed to the sandbox core repo' : 'marker already present'); })
    .catch((e) => { console.error(`${e.name}: ${e.message}`); process.exit(e instanceof SandboxError ? 2 : 1); });
}
