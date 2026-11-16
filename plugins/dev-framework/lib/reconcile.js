'use strict';
// reconcile: ticket state from git facts. Dry run unless --apply. Only this writes state:* labels.
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { parsePlan, planHashes, PlanError } = require('./plan');
const { parseCites } = require('./ticket-body');
const { readIssues, sleepMs, labelNames } = require('./plan-issues');
const { ackCovers } = require('./acks');
const { deriveState } = require('./state');

function parseArgs(argv) {
  const o = { apply: false, ref: 'origin/main', coreDir: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') o.apply = true;
    else if (a === '--core-dir') o.coreDir = argv[++i];
    else if (a === '--ref') o.ref = argv[++i];
    else throw new ConfigError(`unknown argument: ${a}`);
  }
  if (!o.coreDir) throw new ConfigError('--core-dir is required');
  return o;
}

const gitOut = (coreDir, args) => execFileSync('git', ['-C', coreDir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const claimNo = (name) => { const m = /^t\/(\d+)-/.exec(name); return m ? Number(m[1]) : null; };

// One read per repo: claim branches and t/* PRs, keyed by issue number.
function repoFacts(gh, repoKey, config, cache) {
  if (cache.has(repoKey)) return cache.get(repoKey);
  const r = config.repos[repoKey];
  const facts = { branches: new Map(), open: new Map(), merged: new Map() };
  for (const ref of gh.paginate(`repos/${r.github}/git/matching-refs/heads/t/`)) {
    const name = String(ref.ref || '').replace(/^refs\/heads\//, '');
    const n = claimNo(name);
    if (n !== null && !facts.branches.has(n)) facts.branches.set(n, name);
  }
  for (const pr of gh.paginate(`repos/${r.github}/pulls?state=all`)) {
    const head = pr.head && pr.head.ref;
    const n = head ? claimNo(head) : null;
    if (n === null) continue;
    if (pr.merged_at) { if (pr.base && pr.base.ref === r.default) facts.merged.set(n, pr); }
    else if (pr.state === 'open') facts.open.set(n, pr);
  }
  cache.set(repoKey, facts);
  return facts;
}

function readComments(gh, planRepo, openIssues) {
  if (!openIssues.length) return [];
  const since = openIssues.map((i) => i.created_at).filter(Boolean).sort()[0];
  return gh.paginate(`repos/${planRepo}/issues/comments${since ? `?since=${since}` : ''}`);
}

function reconcile(o, config, gh) {
  const planRepo = config.plan.repo;
  let text;
  try { text = gitOut(o.coreDir, ['show', `${o.ref}:${config.plan.path}/PLAN.md`]); } catch { throw new PlanError(`${config.plan.path}/PLAN.md not found at ${o.ref}`); }
  const items = parsePlan(text, config);
  const hashes = planHashes(o.coreDir, o.ref, config);
  const { byId } = readIssues(gh, planRepo);
  const comments = readComments(gh, planRepo, [...byId.values()].filter((i) => i.state === 'open'));
  const cache = new Map();
  const byItem = new Map(items.map((i) => [i.id, i]));
  const memo = new Map();
  const visiting = new Set();

  const stateOf = (item) => {
    if (memo.has(item.id)) return memo.get(item.id);
    const iss = byId.get(item.id);
    let res;
    if (item.repo === config.ownerArea) {
      res = iss && iss.state === 'closed' ? { state: 'done', why: 'owner item, issue closed' } : { state: item.fields.state, why: 'owner item: plan state field' };
    } else {
      if (visiting.has(item.id)) return { state: 'blocked', why: 'dependency cycle' };
      const facts = { depStates: new Map() };
      visiting.add(item.id);
      for (const d of item.deps) if (byItem.has(d)) facts.depStates.set(d, stateOf(byItem.get(d)).state);
      visiting.delete(item.id);
      if (iss) {
        const rf = repoFacts(gh, item.repo, config, cache);
        facts.mergedPr = rf.merged.get(iss.number);
        facts.openPr = rf.open.get(iss.number);
        facts.branch = rf.branches.get(iss.number);
        facts.citedHash = parseCites(iss.body).get(item.id);
        facts.currentHash = hashes.get(item.id);
        facts.ackedHashes = new Set();
        if (facts.citedHash && facts.currentHash && facts.citedHash !== facts.currentHash
            && ackCovers({ coreDir: o.coreDir, config, comments, issue: iss.number, id: item.id, hash: facts.currentHash })) {
          facts.ackedHashes.add(facts.currentHash);
        }
      }
      res = deriveState(item, facts);
    }
    memo.set(item.id, res);
    return res;
  };

  const out = []; const changes = []; const todo = [];
  for (const item of items) {
    const { state, why } = stateOf(item);
    const iss = byId.get(item.id);
    out.push({ id: item.id, issue: iss ? iss.number : null, state, why });
    if (!iss) continue;
    const names = labelNames(iss);
    const stale = names.filter((n) => n.startsWith('state:') && n !== `state:${state}`);
    const hasNew = names.includes(`state:${state}`);
    if (stale.length || !hasNew) {
      changes.push({ issue: iss.number, from: stale.length ? stale[0].slice(6) : null, to: state });
      todo.push({ iss, state, stale, hasNew });
    }
    if (state === 'done' && iss.state === 'open') todo.push({ iss, close: true });
  }
  if (o.apply) {
    let writes = 0;
    const w = (method, p, body) => { if (writes++ > 0) sleepMs(config.github.writeDelayMs); return gh.api(method, p, body); };
    for (const t of todo) {
      const base = `repos/${planRepo}/issues/${t.iss.number}`;
      if (t.close) { w('PATCH', base, { state: 'closed' }); continue; }
      for (const n of t.stale) w('DELETE', `${base}/labels/${encodeURIComponent(n)}`);
      if (!t.hasNew) w('POST', `${base}/labels`, { labels: [`state:${t.state}`] });
    }
  }
  return { exitCode: 0, result: { items: out, changes } };
}

function run({ argv, gh, env = process.env }) {
  try {
    const o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    if (!config.plan.repo) throw new ConfigError('plan.repo is not configured');
    return reconcile(o, config, gh);
  } catch (e) {
    if (e instanceof ConfigError || e instanceof PlanError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

module.exports = { run, parseArgs };
