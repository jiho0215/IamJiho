'use strict';
// new-ticket: add a plan item and its ticket in one step. Dry run unless --apply. Needs the orchestrator lease.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { PlanError, parsePlan, planHashes, list: planList } = require('./plan');
const impact = require('./impact');
const ticketSync = require('./ticket-sync');
const { resolvePlanRef } = require('./fetch-plan');

const BIN = path.join(__dirname, '..', 'bin');
const VALUE_FLAGS = { '--core-dir': 'coreDir', '--epic': 'epic', '--title': 'title', '--area': 'area', '--kind': 'kind', '--stage': 'stage', '--depends': 'depends', '--decisions': 'decisions', '--body-file': 'bodyFile' };

function parseArgs(argv) {
  const o = { apply: false, depends: '—', decisions: '—' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') o.apply = true;
    else if (VALUE_FLAGS[a]) o[VALUE_FLAGS[a]] = argv[++i];
    else throw new ConfigError(`unknown argument: ${a}`);
  }
  for (const [flag, key] of Object.entries(VALUE_FLAGS)) {
    if (!['depends', 'decisions'].includes(key) && !o[key]) throw new ConfigError(`${flag} is required`);
    if (typeof o[key] === 'string' && /[\r\n]/.test(o[key])) throw new ConfigError(`${flag} must be one line`);
  }
  o.epic = String(o.epic).replace(/^P-/, '');
  if (!/^[0-9]+$/.test(o.epic)) throw new ConfigError('--epic must be the epic number');
  return o;
}

const git = (dir, args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

// 0 held; 4 mismatch; 3 missing. Anything else is passed through.
function leaseStatus(coreDir, env) {
  try {
    execFileSync('bash', [path.join(BIN, 'lease'), 'check', '--core-dir', coreDir], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, ...env } });
    return 0;
  } catch (e) {
    return typeof e.status === 'number' ? e.status : 1;
  }
}

// IDs are never reused: any P-<e>-<n> mentioned anywhere in the file (an "Unused on purpose" note) is taken.
function nextId(text, epic) {
  const re = new RegExp(`P-${epic}-(\\d+)(?!\\d)`, 'g');
  let max = 0;
  for (const m of text.matchAll(re)) max = Math.max(max, Number(m[1]));
  return `P-${epic}-${max + 1}`;
}

function itemLines(o, id, body) {
  const head = [`### ${id} · ${o.title}`, '- stage: ' + o.stage, '- kind: ' + o.kind, '- state: ready', '- area: ' + o.area,
    '- depends: ' + o.depends, '- decisions: ' + o.decisions, '- ticket: —'];
  const b = body.replace(/\r/g, '').replace(/\s+$/, '');
  return b ? [...head, '', ...b.split('\n')] : head;
}

// Insert at the end of the "##" section that holds the epic's items; keeps the file's own line ending.
function insertItem(text, o, id, body) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const heading = new RegExp(`^### P-${o.epic}-\\d+ · `);
  let last = -1;
  lines.forEach((l, i) => { if (heading.test(l)) last = i; });
  if (last < 0) throw new PlanError(`no existing item of epic P-${o.epic} in PLAN.md`);
  let end = last + 1;
  while (end < lines.length && !/^#{1,2} /.test(lines[end])) end++;
  while (end > last + 1 && lines[end - 1].trim() === '') end--;
  lines.splice(end, 0, '', ...itemLines(o, id, body));
  return lines.join(eol);
}

// The working tree must be clean: --apply commits from it, and a local edit would ride along unvalidated.
function assertClean(coreDir) {
  const dirty = git(coreDir, ['status', '--porcelain', '--untracked-files=no']).trim();
  if (dirty) throw new ConfigError(`the core working tree is dirty; commit or stash first:\n${dirty}`);
}

// Where HEAD was: a branch name, or a sha when detached. Restored in finally.
function headOf(coreDir) {
  try { return { branch: git(coreDir, ['symbolic-ref', '-q', '--short', 'HEAD']).trim() }; } catch {
    return { sha: git(coreDir, ['rev-parse', 'HEAD']).trim() };
  }
}
function restoreHead(coreDir, start) {
  if (start.branch) git(coreDir, ['checkout', '-q', start.branch]);
  else git(coreDir, ['checkout', '-q', '--detach', start.sha]);
}

function run({ argv, gh, env = process.env }) {
  try {
    const o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    if (!config.plan.repo) throw new ConfigError('plan.repo is not configured');
    if (o.apply) assertClean(o.coreDir); // before anything else
    const lease = leaseStatus(o.coreDir, env);
    if (lease !== 0) {
      const why = lease === 4 ? 'the orchestrator lease is held by another token' : lease === 3 ? 'the lease is missing (no lease line on origin or no local token)' : `lease check failed unexpectedly (exit ${lease})`;
      return { exitCode: 4, result: { error: `lease not held: ${why}` } };
    }
    // One read of the fetched tip: the ID, the validated text and the committed text all come from it.
    const ref = resolvePlanRef({ coreDir: o.coreDir, config });
    const body = fs.readFileSync(o.bodyFile, 'utf8');
    const tip = git(o.coreDir, ['show', `${ref}:${config.plan.path}/PLAN.md`]);
    const id = nextId(tip, o.epic);
    const planText = insertItem(tip, o, id, body);
    // Validate before any write: the new plan must parse, the stage must exist, decision IDs must exist.
    if (!config.stages || !(o.stage in config.stages)) throw new ConfigError(`stage "${o.stage}" is not in config.stages`);
    parsePlan(planText, config);
    const wanted = planList(o.decisions);
    if (wanted.length) {
      const known = planHashes(o.coreDir, ref, config);
      for (const d of wanted) if (!known.has(d)) throw new ConfigError(`decision ${d} does not exist in the plan`);
    }
    if (!o.apply) return { exitCode: 0, result: { id, text: itemLines(o, id, body).join('\n'), planText } };
    return apply(o, config, gh, env, { ref, id, planText });
  } catch (e) {
    if (e instanceof ConfigError || e instanceof PlanError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

// planText: exactly the text run() validated; it is what gets committed.
function apply(o, config, gh, env, { ref, id, planText }) {
  const planRepo = config.plan.repo;
  const base = config.plan.branch;
  const planRel = path.join(config.plan.path, 'PLAN.md');
  const token = fs.readFileSync(path.join(o.coreDir, '.orchestrator', 'lease'), 'utf8').trim();
  const start = headOf(o.coreDir);
  const branch = `plan/new-${id}`;
  git(o.coreDir, ['checkout', '-q', '-b', branch, ref]);
  let pr;
  let committed = false;
  try {
    fs.writeFileSync(path.join(o.coreDir, planRel), planText);
    git(o.coreDir, ['add', '--', planRel]);
    git(o.coreDir, ['commit', '-q', '-m', `plan: add ${id} · ${o.title}`]);
    committed = true;
    git(o.coreDir, ['push', '-q', 'origin', branch]); // never forced
    pr = gh.api('POST', `repos/${planRepo}/pulls`, {
      title: `plan: add ${id} · ${o.title}`, head: branch, base,
      body: `Adds plan item ${id}.\n\nlease: ${token}\n`,
    }).number;
  } finally {
    // An uncommitted write is ours alone (the tree was clean): drop it so the checkout back cannot carry it.
    if (!committed) { try { git(o.coreDir, ['checkout', '-q', '--', planRel]); } catch { /* reported by the throw */ } }
    restoreHead(o.coreDir, start);
  }

  const im = impact.run({ argv: ['--core-dir', o.coreDir, '--pr', String(pr), '--apply'], gh, env });
  if (im.exitCode !== 0) return { exitCode: im.exitCode || 8, result: { error: 'plan impact check did not pass; PR left open', id, planPr: pr, impact: im.result } };

  gh.raw(['pr', 'merge', String(pr), '--repo', planRepo, '--squash']);

  // No --ref: ticket-sync fetches the merged plan branch itself (resolvePlanRef).
  const ts = ticketSync.run({ argv: ['--core-dir', o.coreDir, '--only', id, '--apply'], gh, env });
  if (ts.exitCode !== 0) return { exitCode: ts.exitCode || 1, result: { error: 'ticket-sync failed after the plan PR merged', id, planPr: pr, sync: ts.result } };
  const made = (ts.result.created || []).find((c) => c.id === id);
  return { exitCode: 0, result: { id, issue: made ? made.issue : null, planPr: pr } };
}

module.exports = { run, nextId, insertItem };
