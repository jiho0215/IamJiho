'use strict';
// reconcile: ticket state from git facts. Dry run unless --apply. Only this writes state:* labels.
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { parsePlan, planHashes, PlanError } = require('./plan');
const { parseCites } = require('./ticket-body');
const { readIssues, sleepMs, labelNames } = require('./plan-issues');
const { ackCovers } = require('./acks');
const { deriveState, staleCites } = require('./state');
const gate = require('./gate');

function parseArgs(argv) {
  const o = { apply: false, ref: '', coreDir: '', postMerge: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') o.apply = true;
    else if (a === '--post-merge') o.postMerge = true;
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

// Read fresh, never a cache: unless the caller named a ref explicitly, fetch the plan branch first.
function resolveRef(o, config) {
  if (o.ref) return;
  const b = config.plan.branch || 'main';
  try { gitOut(o.coreDir, ['fetch', '-q', 'origin', `+refs/heads/${b}:refs/remotes/origin/${b}`]); } catch (e) {
    throw new PlanError(`cannot fetch origin ${b} (the plan must be read fresh): ${String(e.stderr || e.message).trim()}`);
  }
  o.ref = `origin/${b}`;
}

function reconcile(o, config, gh) {
  const planRepo = config.plan.repo;
  resolveRef(o, config);
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
        facts.cites = parseCites(iss.body);
        facts.current = hashes;
        facts.acked = new Set();
        // Every cited ID (the item and each decision) is checked on its own.
        for (const { id, cur } of staleCites(facts)) {
          if (ackCovers({ coreDir: o.coreDir, config, comments, issue: iss.number, id, hash: cur })) facts.acked.add(id);
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

// --post-merge: judge each merged t/* PR against the plan AS IT WAS at merged_at (never today's plan), so a later
// plan edit cannot turn old merges stale. Anything that cannot be judged is `unverifiable`, never silently fine.
function postMerge(o, config, gh) {
  const planRepo = config.plan.repo;
  const branch = config.plan.branch || 'main';
  const days = (config.reconcile && config.reconcile.lookbackDays) || 14;
  const cutoff = Date.now() - days * 86400000;
  let fetchError = null;
  try { gitOut(o.coreDir, ['fetch', '-q', 'origin', `+refs/heads/${branch}:refs/remotes/origin/${branch}`]); } catch (e) {
    fetchError = `cannot fetch origin ${branch}: ${String(e.stderr || e.message).trim()}`;
  }
  const hashCache = new Map();
  const hashesAtMerge = (mergedAt) => {
    if (fetchError) throw new Error(fetchError);
    const rows = gh.api('GET', `repos/${planRepo}/commits?sha=${encodeURIComponent(branch)}&until=${mergedAt}&per_page=1`);
    const sha = Array.isArray(rows) && rows[0] && rows[0].sha;
    if (!sha) throw new Error(`no ${branch} commit at or before ${mergedAt}`);
    try { gitOut(o.coreDir, ['cat-file', '-e', `${sha}^{commit}`]); } catch { throw new Error(`plan commit ${sha} is not in the core clone`); }
    if (!hashCache.has(sha)) hashCache.set(sha, planHashes(o.coreDir, sha, config));
    return hashCache.get(sha);
  };

  const staleMerges = []; const unverifiable = [];
  for (const repoKey of Object.keys(config.repos || {})) {
    const r = config.repos[repoKey];
    const prs = gh.paginate(`repos/${r.github}/pulls?state=closed`).filter((p) =>
      p.merged_at && Date.parse(p.merged_at) >= cutoff && p.base && p.base.ref === r.default &&
      p.head && String(p.head.ref || '').startsWith('t/'));
    for (const p of prs) {
      try {
        const hashes = hashesAtMerge(p.merged_at);
        const body = p.body || '';
        const evidence = gate.evidenceBlock(body);
        const reasons = [
          ...gate.checkCites({
            body, planRepo, hashes, coreDir: o.coreDir, config,
            // Only acks that existed when the PR merged count.
            loadComments: (n) => gh.paginate(`repos/${planRepo}/issues/${n}/comments`).filter((c) => !c.created_at || Date.parse(c.created_at) <= Date.parse(p.merged_at)),
          }),
          ...gate.checkEvidence({ evidence }),
        ];
        if (r.ci === 'required') {
          const runs = gh.paginate(`repos/${r.github}/commits/${p.head.sha}/check-runs`, { key: 'check_runs' });
          const st = gh.api('GET', `repos/${r.github}/commits/${p.head.sha}/status`);
          const statuses = (st && Array.isArray(st.statuses)) ? st.statuses : [];
          reasons.push(...gate.checkCi({ repoConfig: r, runs, statuses, evidence }));
        }
        if (reasons.length) staleMerges.push({ repo: r.github, pr: p.number, reasons });
      } catch (e) {
        unverifiable.push({ repo: r.github, pr: p.number, reason: e.message });
      }
    }
  }

  const created = [];
  const NL = String.fromCharCode(10);
  const todo = [
    ...staleMerges.map((s) => ({
      title: `merged-stale: ${s.repo}#${s.pr}`,
      body: ['PR ' + s.repo + '#' + s.pr + ' was merged against a plan it did not satisfy, judged at its merge time.', '', ...s.reasons.map((x) => `- ${x}`), ''].join(NL),
    })),
    ...unverifiable.map((u) => ({
      title: `merged-unverifiable: ${u.repo}#${u.pr}`,
      body: ['PR ' + u.repo + '#' + u.pr + ' was merged but could not be judged against the plan at its merge time.', '', `Reason: ${u.reason}`, ''].join(NL),
    })),
  ];

  if (o.apply && todo.length) {
    const open = new Set(gh.paginate(`repos/${planRepo}/issues?state=open&labels=merged-stale`).filter((i) => !i.pull_request).map((i) => i.title));
    let writes = 0;
    for (const t of todo) {
      if (open.has(t.title)) continue;
      if (writes++ > 0) sleepMs(config.github.writeDelayMs);
      gh.api('POST', `repos/${planRepo}/issues`, { title: t.title, body: t.body, labels: ['merged-stale'] });
      open.add(t.title); created.push(t.title);
    }
  }
  // 9 = something merged that is stale or could not be verified; 0 only when both lists are empty.
  return { exitCode: staleMerges.length || unverifiable.length ? 9 : 0, result: { staleMerges, unverifiable, created } };
}

function run({ argv, gh, env = process.env }) {
  try {
    const o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    if (!config.plan.repo) throw new ConfigError('plan.repo is not configured');
    return o.postMerge ? postMerge(o, config, gh) : reconcile(o, config, gh);
  } catch (e) {
    if (e instanceof ConfigError || e instanceof PlanError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

module.exports = { run, parseArgs };
