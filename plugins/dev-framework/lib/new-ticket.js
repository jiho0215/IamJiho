'use strict';
// new-ticket: add a plan item and its ticket in one step. Dry run unless --apply. Needs the orchestrator lease.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { PlanError } = require('./plan');
const impact = require('./impact');
const ticketSync = require('./ticket-sync');

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

function run({ argv, gh, env = process.env }) {
  try {
    const o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    if (!config.plan.repo) throw new ConfigError('plan.repo is not configured');
    const lease = leaseStatus(o.coreDir, env);
    if (lease !== 0) return { exitCode: lease === 3 ? 3 : 4, result: { error: lease === 4 ? 'the orchestrator lease is not held by this clone' : `lease check failed (exit ${lease})` } };
    const body = fs.readFileSync(o.bodyFile, 'utf8');
    const planFile = path.join(o.coreDir, config.plan.path, 'PLAN.md');
    const render = () => {
      const text = fs.readFileSync(planFile, 'utf8');
      const id = nextId(text, o.epic);
      return { id, planText: insertItem(text, o, id, body), text: itemLines(o, id, body).join('\n') };
    };
    if (!o.apply) {
      const r = render();
      return { exitCode: 0, result: { id: r.id, text: r.text, planText: r.planText } };
    }
    return apply(o, config, gh, env, planFile, render);
  } catch (e) {
    if (e instanceof ConfigError || e instanceof PlanError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

function apply(o, config, gh, env, planFile, render) {
  const planRepo = config.plan.repo;
  const base = config.plan.branch || 'main';
  const token = fs.readFileSync(path.join(o.coreDir, '.orchestrator', 'lease'), 'utf8').trim();
  const start = git(o.coreDir, ['rev-parse', '--abbrev-ref', 'HEAD']).trim();
  git(o.coreDir, ['fetch', '-q', 'origin', base]);
  // The branch name needs the ID, which needs the freshest plan: allocate on origin's tip first.
  const tip = git(o.coreDir, ['show', `origin/${base}:${config.plan.path}/PLAN.md`]);
  const id = nextId(tip, o.epic);
  const branch = `plan/new-${id}`;
  git(o.coreDir, ['checkout', '-q', '-b', branch, `origin/${base}`]);
  let pr;
  try {
    const r = render();
    fs.writeFileSync(planFile, r.planText);
    git(o.coreDir, ['add', '--', path.join(config.plan.path, 'PLAN.md')]);
    git(o.coreDir, ['commit', '-q', '-m', `plan: add ${id} · ${o.title}`]);
    git(o.coreDir, ['push', '-q', 'origin', branch]); // never forced
    pr = gh.api('POST', `repos/${planRepo}/pulls`, {
      title: `plan: add ${id} · ${o.title}`, head: branch, base,
      body: `Adds plan item ${id}.\n\nlease: ${token}\n`,
    }).number;
  } finally {
    git(o.coreDir, ['checkout', '-q', start]);
  }

  const im = impact.run({ argv: ['--core-dir', o.coreDir, '--pr', String(pr), '--apply'], gh, env });
  if (im.exitCode !== 0) return { exitCode: im.exitCode || 8, result: { error: 'plan impact check did not pass; PR left open', id, planPr: pr, impact: im.result } };

  gh.raw(['pr', 'merge', String(pr), '--repo', planRepo, '--squash']);
  git(o.coreDir, ['fetch', '-q', 'origin', base]);

  const ts = ticketSync.run({ argv: ['--core-dir', o.coreDir, '--ref', `origin/${base}`, '--only', id, '--apply'], gh, env });
  if (ts.exitCode !== 0) return { exitCode: ts.exitCode || 1, result: { error: 'ticket-sync failed after the plan PR merged', id, planPr: pr, sync: ts.result } };
  const made = (ts.result.created || []).find((c) => c.id === id);
  return { exitCode: 0, result: { id, issue: made ? made.issue : null, planPr: pr } };
}

module.exports = { run, nextId, insertItem };
