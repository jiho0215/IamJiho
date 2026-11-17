// Acceptance harness: drives the real v6 scripts against a real GitHub sandbox.
// Sandbox repos come only from env (DEVFW_SANDBOX_CORE / DEVFW_SANDBOX_CODE, "owner/name"); no name is committed.
// Every write path first proves the core repo carries the DEVFW_SANDBOX marker on its default branch.
import { spawn, spawnSync, execFileSync } from 'node:child_process';
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
// Its content lists the sandbox code repos allowed to be written, one owner/name per line ('#' lines are comments).
function readMarker(repo) {
  const r = gh(['api', '-H', 'Accept: application/vnd.github.raw', `repos/${repo}/contents/${MARKER}`], { allowFail: true });
  return r.status === 0 ? r.stdout : null;
}
const allowedRepos = (text) => String(text).replace(/\r/g, '').split('\n').map((l) => l.trim()).filter((l) => OWNER_NAME.test(l));

// A run is writable only if openRun verified it: core carries the marker AND the marker lists the code repo.
// The record lives in a module-private WeakMap, so a hand-built run object has none. Re-verified after 10 minutes.
const VERIFIED = new WeakMap();
const REVERIFY_MS = 10 * 60 * 1000;
function verifyPair(core, code, read = readMarker) {
  const text = read(core);
  if (text === null) throw new SandboxError(`${core} has no ${MARKER} file on its default branch (or gh could not read it): refusing to write`);
  if (!allowedRepos(text).includes(code)) throw new SandboxError(`${code} is not listed in the ${MARKER} file of ${core}: refusing to write`);
  return { core, code, at: Date.now() };
}
// Read-only check for scripts that write outside openRun (the manual two-machine race): env names, then the marker.
export function verifySandboxPair(opts = {}) {
  const { core, code } = resolveRepos(opts);
  verifyPair(core, code);
  return { core, code };
}
function requireRun(run) {
  const rec = VERIFIED.get(run);
  if (!rec || rec.core !== run.coreRepo || rec.code !== run.codeRepo) throw new SandboxError('run was not verified by openRun: refusing to write');
  if (Date.now() - rec.at > REVERIFY_MS) VERIFIED.set(run, verifyPair(rec.core, rec.code));
}

function runIdNow() {
  const d = new Date().toISOString().replace(/\D/g, '').slice(0, 12);
  const rnd = [...crypto.randomBytes(3)].map((b) => String.fromCharCode(97 + (b % 26))).join('');
  return `r${d}${rnd}`;
}

export async function openRun(opts = {}) {
  const { core, code } = resolveRepos(opts);
  const verified = verifyPair(core, code);               // before anything is cloned, created or pushed
  const runId = runIdNow();
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), `devfw-accept-${runId}-`));
  const coreDir = path.join(tmp, 'core');
  const codeDir = path.join(tmp, 'code');
  try {
  gh(['repo', 'clone', core, coreDir, '--', '-q']);
  gh(['repo', 'clone', code, codeDir, '--', '-q']);
  // Run isolation: the code repo gets its own base branch for this run, cut from its default branch and pushed (guarded)
  // before any scenario clones the code repo, so claims, PRs and merges never touch the default branch and runs cannot
  // see each other's merges.
  const codeDefault = `run/${runId}`;
  git(codeDir, ['checkout', '-q', '-b', codeDefault]);

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
  const env = { ...process.env, DEVFW_CONFIG: configFile };
  const run = { runId, coreDir, codeDir, config, env, tmp, coreRepo: core, codeRepo: code };
  VERIFIED.set(run, verified);
  run.exec = (script, args = [], opts = {}) => execIn(run, script, args, opts);
  requireRun(run);                                       // re-check right before the push
  git(codeDir, ['push', '-q', '-u', 'origin', codeDefault]);
  git(coreDir, ['push', '-q', '-u', 'origin', `run/${runId}`]);
  await sleep(HARNESS_DELAY_MS);
  return run;
  } catch (e) {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* left for the temp cleaner */ }
    throw e;
  }
}

// Guarded write helpers for scenarios: each refuses a run that openRun did not verify, before touching anything.
export function ghWrite(run, args) { requireRun(run); return gh(args).stdout; }
export function gitWrite(run, dir, args) { requireRun(run); return git(dir, args); }
export function assertVerifiedRun(run) { requireRun(run); }

// opts.env: extra environment for this one call (e.g. DEVFW_CONFIG pointing at a config variant).
export function execIn(run, script, args = [], opts = {}) {
  requireRun(run);                                       // scripts can write issues, PRs and merges
  const file = path.join(PLUGIN, 'bin', script);
  const cmd = NODE_SCRIPTS.has(script) ? ['node', [file, ...args]] : BASH_SCRIPTS.has(script) ? ['bash', [file, ...args]] : null;
  if (!cmd) throw new Error(`unknown plugin script: ${script}`);
  const r = spawnSync(cmd[0], cmd[1], { env: { ...run.env, ...(opts.env || {}) }, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const stdout = r.stdout || '';
  let json = null;
  const last = stdout.split('\n').map((l) => l.trim()).filter(Boolean).pop();
  if (last) { try { json = JSON.parse(last); } catch { json = null; } }
  return { code: r.status, json, stdout, stderr: r.stderr || '' };
}

// Same guard and result shape as execIn, but asynchronous: for scenarios that run several scripts at once.
export function execAsyncIn(run, script, args = []) {
  requireRun(run);
  const file = path.join(PLUGIN, 'bin', script);
  const cmd = NODE_SCRIPTS.has(script) ? ['node', [file, ...args]] : BASH_SCRIPTS.has(script) ? ['bash', [file, ...args]] : null;
  if (!cmd) throw new Error(`unknown plugin script: ${script}`);
  return new Promise((resolve, reject) => {
    const c = spawn(cmd[0], cmd[1], { env: run.env });
    let stdout = ''; let stderr = '';
    c.stdout.on('data', (d) => { stdout += d; });
    c.stderr.on('data', (d) => { stderr += d; });
    c.on('error', reject);
    c.on('close', (code) => {
      let json = null;
      const last = stdout.split('\n').map((l) => l.trim()).filter(Boolean).pop();
      if (last) { try { json = JSON.parse(last); } catch { json = null; } }
      resolve({ code, json, stdout, stderr });
    });
  });
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
  requireRun(run);
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

// ---- Sweep: orphans of killed runs (a run that died before closeRun leaves its issues and PRs open).
const RUN_ID_RE = /r(\d{12})[a-z]{3}/g;
const STALE_RUN_MS = 60 * 60 * 1000;
const TRACKER_RE = /^(merged-stale|merged-unverifiable): ([\w.-]+\/[\w.-]+)#(\d+)$/;
const runIdTime = (digits) => Date.UTC(+digits.slice(0, 4), +digits.slice(4, 6) - 1, +digits.slice(6, 8), +digits.slice(8, 10), +digits.slice(10, 12));

// Pure. rows: open issues/PRs { repo, number, title, labels: [name], pull_request }. prBase(repo, n): the PR's base ref or null.
// Picks (a) an item naming only runIds older than 1 hour (in an epic:<runId> label or its title), and (b) an open
// merged-stale / merged-unverifiable tracker whose PR's base ref starts with run/. A fresh run's items, a tracker whose
// PR is on another (or an unknown) base, and anything naming no runId are never picked.
export function selectSweep({ rows, now = Date.now(), prBase }) {
  const picked = [];
  for (const r of rows) {
    const t = TRACKER_RE.exec(String(r.title || ''));
    if (t) {
      const base = prBase(t[2], Number(t[3]));
      if (typeof base === 'string' && base.startsWith('run/')) picked.push({ repo: r.repo, number: r.number, why: `${t[1]} tracker of a PR into ${base}` });
      continue;
    }
    const texts = [String(r.title || ''), ...(r.labels || []).filter((l) => l.startsWith('epic:')).map((l) => l.slice(5))];
    const ids = new Map();
    for (const s of texts) for (const m of s.matchAll(RUN_ID_RE)) ids.set(m[0], runIdTime(m[1]));
    if (!ids.size) continue;
    if ([...ids.values()].every((ms) => now - ms > STALE_RUN_MS)) picked.push({ repo: r.repo, number: r.number, why: `run ${[...ids.keys()].join(',')} is older than 1 hour` });
  }
  return picked;
}

const ghSweepIo = {
  readMarker: (repo) => ghIo.readMarker(repo),
  listOpen(repo) {
    const out = gh(['api', '--paginate', `repos/${repo}/issues?state=open&per_page=100`, '--jq', '.[] | {number, title, labels: [.labels[].name], pull_request: (.pull_request != null)}']).stdout;
    return out.split('\n').map((s) => s.trim()).filter(Boolean).map((s) => ({ repo, ...JSON.parse(s) }));
  },
  prBase(repo, n) {
    const r = gh(['api', `repos/${repo}/pulls/${n}`, '--jq', '.base.ref'], { allowFail: true });
    return r.status === 0 ? r.stdout.trim() : null;
  },
  close(repo, n) { gh(['api', '-X', 'PATCH', `repos/${repo}/issues/${n}`, '-f', 'state=closed']); },
};

// Closes the orphans in both sandbox repos. Guarded like every write: env names, then the marker pair, before any read.
export async function sweep({ env = process.env, io = ghSweepIo, now = Date.now(), delayMs = HARNESS_DELAY_MS } = {}) {
  const { core, code } = resolveRepos({ coreRepo: env.DEVFW_SANDBOX_CORE, codeRepo: env.DEVFW_SANDBOX_CODE });
  verifyPair(core, code, io.readMarker);
  const pair = new Set([core, code]);
  const rows = [...io.listOpen(core), ...io.listOpen(code)];
  const prBase = (repo, n) => (pair.has(repo) ? io.prBase(repo, n) : null);
  const picked = selectSweep({ rows, now, prBase });
  const closed = [];
  for (const p of picked) {
    if (closed.length) await sleep(delayMs);
    io.close(p.repo, p.number);
    closed.push(p);
  }
  return { closed };
}

// GitHub access for --init. Injected in unit tests (harness.unit.test.mjs); this is the real one.
const MAX_SANDBOX_COMMITS = 20;
const ghIo = {
  // The marker text, null on a 404, and a throw on anything else (an auth, rate-limit or network error is never "absent").
  readMarker(repo) {
    const r = gh(['api', '-H', 'Accept: application/vnd.github.raw', `repos/${repo}/contents/${MARKER}`], { allowFail: true });
    if (r.status === 0) return r.stdout;
    const err = (r.stderr || r.stdout || '').trim();
    if (/\bHTTP 404\b/.test(err)) return null;
    throw new Error(`cannot read ${MARKER} of ${repo} (not a 404): ${err}`);
  },
  repoInfo(repo) {
    const j = JSON.parse(gh(['api', `repos/${repo}`]).stdout);
    return { private: j.private === true && j.visibility !== 'public', default_branch: j.default_branch };
  },
  commitCount(repo, branch, limit) {
    const out = gh(['api', `repos/${repo}/commits?sha=${encodeURIComponent(branch)}&per_page=${limit}`, '--jq', 'length']).stdout;
    return Number(out.trim());
  },
  closedPrs(repo) {
    const out = gh(['api', '--paginate', `repos/${repo}/pulls?state=closed&per_page=100`, '--jq', '.[] | {number, head: .head.ref, base: .base.ref}']).stdout;
    return out.split('\n').map((s) => s.trim()).filter(Boolean).map((s) => JSON.parse(s));
  },
  writeMarker(core, body, message) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'devfw-accept-init-'));
    try {
      const dir = path.join(tmp, 'core');
      gh(['repo', 'clone', core, dir, '--', '-q']);
      fs.writeFileSync(path.join(dir, MARKER), body);
      git(dir, ['add', MARKER]);
      git(dir, ['commit', '-q', '-m', message]);
      git(dir, ['push', '-q', 'origin', 'HEAD']);
    } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  },
};

// Heuristics that tell a throwaway sandbox from a real repo. Any hit refuses (--force-sandbox skips only these).
// A closed PR counts as a sandbox PR only when it belongs to an acceptance run: its head or its base is a run/ branch.
function notASandbox(io, repo) {
  const why = [];
  const info = io.repoInfo(repo);
  if (!info.private) why.push(`${repo} is public`);
  const n = io.commitCount(repo, info.default_branch, MAX_SANDBOX_COMMITS + 1);
  if (n > MAX_SANDBOX_COMMITS) why.push(`${repo} has more than ${MAX_SANDBOX_COMMITS} commits on ${info.default_branch}`);
  const foreign = io.closedPrs(repo).filter((p) => !String(p.head || '').startsWith('run/') && !String(p.base || '').startsWith('run/'));
  if (foreign.length) why.push(`${repo} has closed PRs not made by a run/ branch (#${foreign.slice(0, 5).map((p) => p.number).join(', #')})`);
  return why;
}

// One-time: the marker goes to the CORE repo's default branch only (a normal push) and lists the code repo.
// --confirm <core> <code> must repeat the env names exactly; it is checked before any GitHub read and is never skipped.
// Before the marker is created or a code repo is added to it, both repos must look like throwaway sandboxes.
// A marker that already lists the code repo is a no-op. A marker read that fails (not a 404) refuses: never overwrite.
export async function initSandbox({ confirm, forceSandbox = false, env = process.env, io = ghIo } = {}) {
  const { core, code } = resolveRepos({ coreRepo: env.DEVFW_SANDBOX_CORE, codeRepo: env.DEVFW_SANDBOX_CODE });
  if (!Array.isArray(confirm) || confirm.length !== 2 || confirm[0] !== core || confirm[1] !== code) {
    throw new SandboxError(`--init needs --confirm <core> <code> repeating DEVFW_SANDBOX_CORE and DEVFW_SANDBOX_CODE exactly (${core} ${code}): refusing to write`);
  }
  if (io.readMarker(code) !== null) throw new SandboxError('the code repo carries a marker; only the core repo may');
  const existing = io.readMarker(core);
  if (existing !== null && allowedRepos(existing).includes(code)) return { created: false, added: false };
  if (!forceSandbox) {
    const why = [...notASandbox(io, core), ...notASandbox(io, code)];
    if (why.length) throw new SandboxError(`these do not look like throwaway sandbox repos (--force-sandbox overrides): ${why.join('; ')}`);
  }
  const body = existing === null
    ? `# Throwaway sandbox for the dev-framework acceptance suite. Safe to write to.\n# Sandbox code repos allowed for this core repo, one per line:\n${code}\n`
    : existing.replace(/\r/g, '').replace(/\n*$/, '\n') + `${code}\n`;
  io.writeMarker(core, body, existing === null ? 'add DEVFW_SANDBOX marker' : 'DEVFW_SANDBOX: list the code repo');
  return { created: existing === null, added: existing !== null };
}

// --init --confirm <core> <code> [--force-sandbox]. Anything else is refused (exit 2) before any GitHub call.
export function parseInitArgs(argv) {
  const o = { confirm: null, forceSandbox: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--confirm') { o.confirm = argv.slice(i + 1, i + 3); i += 2; }
    else if (argv[i] === '--force-sandbox') o.forceSandbox = true;
    else throw new SandboxError(`--init: unknown argument ${argv[i]} (usage: --init --confirm <core> <code> [--force-sandbox])`);
  }
  return o;
}

const cliFail = (e) => { console.error(`${e.name}: ${e.message}`); process.exit(e instanceof SandboxError ? 2 : 1); };
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href && process.argv[2] === '--init') {
  Promise.resolve().then(() => initSandbox(parseInitArgs(process.argv.slice(3))))
    .then((r) => { console.log(r.created ? 'marker committed to the sandbox core repo' : r.added ? 'code repo added to the marker' : 'marker already present'); })
    .catch(cliFail);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href && process.argv[2] === '--sweep') {
  sweep().then((r) => {
    for (const x of r.closed) console.log(`swept ${x.repo}#${x.number}: ${x.why}`);
    console.log(`sweep: closed ${r.closed.length}`);
  }).catch(cliFail);
}
