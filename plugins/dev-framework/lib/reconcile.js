'use strict';
// reconcile: ticket state from git facts. Dry run unless --apply. Only this writes state:* labels.
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { parsePlan, planHashes, PlanError } = require('./plan');
const { parseCites } = require('./ticket-body');
const { readIssues, sleepMs, labelNames, claimRefs } = require('./plan-issues');
const { ackCovers } = require('./acks');
const { deriveState, staleCites } = require('./state');
const gate = require('./gate');
const { resolvePlanRef } = require('./fetch-plan');

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
  for (const name of claimRefs(gh, r.github)) {
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
  o.ref = resolvePlanRef({ coreDir: o.coreDir, config, ref: o.ref });
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
        facts.expected = [item.id, ...item.decisions];
        facts.acked = new Set();
        // Every cited ID (the item and each decision) is checked on its own. A removed or missing cite has no
        // current hash to ack, so no ack can clear it.
        for (const { id, cur, removed, missing } of staleCites(facts)) {
          if (removed || missing) continue;
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
  const branch = config.plan.branch;
  const days = (config.reconcile && config.reconcile.lookbackDays) || 14;
  const cutoff = Date.now() - days * 86400000;
  let fetchError = null;
  // Fetched so the merge-time plan commits are in the clone; a failure makes every PR unverifiable, never fine.
  try { resolvePlanRef({ coreDir: o.coreDir, config }); } catch (e) { fetchError = e.message; }
  // The plan as of merged_at: its hashes AND its items (the ticket tie reads the item's decisions from the same commit).
  const planCache = new Map();
  const planAtMerge = (mergedAt) => {
    if (fetchError) throw new Error(fetchError);
    const rows = gh.api('GET', `repos/${planRepo}/commits?sha=${encodeURIComponent(branch)}&until=${mergedAt}&per_page=1`);
    const sha = Array.isArray(rows) && rows[0] && rows[0].sha;
    if (!sha) throw new Error(`no ${branch} commit at or before ${mergedAt}`);
    try { gitOut(o.coreDir, ['cat-file', '-e', `${sha}^{commit}`]); } catch { throw new Error(`plan commit ${sha} is not in the core clone`); }
    if (!planCache.has(sha)) {
      const items = parsePlan(gitOut(o.coreDir, ['show', `${sha}:${config.plan.path}/PLAN.md`]), config);
      planCache.set(sha, { sha, hashes: planHashes(o.coreDir, sha, config), items: new Map(items.map((i) => [i.id, i])) });
    }
    return planCache.get(sha);
  };
  // The current issue is read only for its plan: label (and to know it exists); what the PR must cite comes from the
  // merge-time plan item: its ID and its decisions.
  const wantAtMerge = (plan) => (iss, n) => {
    const label = labelNames(iss || {}).find((x) => x.startsWith('plan:'));
    if (!label) throw new Error(`issue #${n} has no plan: label to tie it to a plan item`);
    const id = label.slice(5);
    const item = plan.items.get(id);
    if (!item) throw new Error(`${id} is not in the plan at merge time (${plan.sha.slice(0, 7)})`);
    return [item.id, ...item.decisions];
  };

  // judged: every PR that passed the filters and was judged (clean, stale or unverifiable), so a caller can tell a clean
  // verdict from a PR that was never looked at.
  const staleMerges = []; const unverifiable = []; const judged = [];
  for (const repoKey of Object.keys(config.repos || {})) {
    const r = config.repos[repoKey];
    const prs = gh.paginate(`repos/${r.github}/pulls?state=closed`).filter((p) =>
      p.merged_at && Date.parse(p.merged_at) >= cutoff && p.base && p.base.ref === r.default &&
      p.head && String(p.head.ref || '').startsWith('t/'));
    for (const p of prs) {
      judged.push({ repo: r.github, pr: p.number });
      try {
        const plan = planAtMerge(p.merged_at);
        const hashes = plan.hashes;
        const body = p.body || '';
        const evidence = gate.evidenceBlock(body);
        const reasons = [
          ...gate.checkCites({
            body, planRepo, hashes, coreDir: o.coreDir, config,
            // Only acks that existed when the PR merged count.
            loadComments: (n) => gh.paginate(`repos/${planRepo}/issues/${n}/comments`).filter((c) => !c.created_at || Date.parse(c.created_at) <= Date.parse(p.merged_at)),
          }),
          // The ticket tie: the PR sits on its own issue's claim branch and cites the item and its decisions as the
          // plan had them at merged_at. An unreadable or unlabelled issue is a ticket: reason, never silently fine.
          ...gate.checkTicket({ headRef: p.head.ref, body, planRepo, loadIssue: (n) => gh.api('GET', `repos/${planRepo}/issues/${n}`), wantFor: wantAtMerge(plan) }),
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

  const NL = String.fromCharCode(10);
  const titleOf = (kind, x) => `${kind}: ${x.repo}#${x.pr}`;
  const todo = [
    ...staleMerges.map((s) => ({
      title: titleOf('merged-stale', s), list: 'staleMerges', entry: s,
      body: ['PR ' + s.repo + '#' + s.pr + ' was merged against a plan it did not satisfy, judged at its merge time.', '', ...s.reasons.map((x) => `- ${x}`), ''].join(NL),
    })),
    ...unverifiable.map((u) => ({
      title: titleOf('merged-unverifiable', u), list: 'unverifiable', entry: u,
      body: ['PR ' + u.repo + '#' + u.pr + ' was merged but could not be judged against the plan at its merge time.', '', `Reason: ${u.reason}`, ''].join(NL),
    })),
  ];

  // Existing tracking issues, open AND closed: a closed one means a person resolved that PR, so it must not reopen
  // (a new issue) and no longer counts toward exit 9. An open one is still a problem, just not a new issue.
  const resolved = []; const created = [];
  const pending = { staleMerges: [], unverifiable: [] };
  if (todo.length) {
    const seen = new Map(); // title -> { open, number }
    for (const i of gh.paginate(`repos/${planRepo}/issues?state=all&labels=merged-stale`)) {
      if (i.pull_request) continue;
      const cur = seen.get(i.title);
      if (!cur || (!cur.open && i.state === 'open')) seen.set(i.title, { open: i.state === 'open', number: i.number });
    }
    let writes = 0;
    for (const t of todo) {
      const had = seen.get(t.title);
      if (had && !had.open) { resolved.push({ repo: t.entry.repo, pr: t.entry.pr, issue: had.number, title: t.title }); continue; }
      pending[t.list].push(t.entry);
      if (!o.apply || had) continue;
      if (writes++ > 0) sleepMs(config.github.writeDelayMs);
      gh.api('POST', `repos/${planRepo}/issues`, { title: t.title, body: t.body, labels: ['merged-stale'] });
      seen.set(t.title, { open: true }); created.push(t.title);
    }
  }
  // 9 = something merged that is stale or could not be verified and nobody has closed its issue; 0 otherwise.
  const out = { staleMerges: pending.staleMerges, unverifiable: pending.unverifiable, resolved, created, judged };
  return { exitCode: out.staleMerges.length || out.unverifiable.length ? 9 : 0, result: out };
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
