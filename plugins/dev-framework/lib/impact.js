'use strict';
// impact: suspect-link impact list and commit status for a plan PR. Dry run unless --apply.
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { planHashes, PlanError } = require('./plan');
const { parseCites } = require('./ticket-body');
const { readIssues, sleepMs } = require('./plan-issues');
const { parseLeaseLine } = require('./lease');

const MARKER = '<!-- devfw:impact -->';
const CONTEXT = 'devfw/plan-impact';
const HEADING_RE = /^### ([A-Z]+(?:-[a-z0-9]+)*-[0-9]+) · /;
const SUPERSEDED_RE = /^\s*(?:-\s*)?superseded-by:\s*\S/;

function parseArgs(argv) {
  const o = { apply: false, coreDir: '', pr: 0 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') o.apply = true;
    else if (a === '--core-dir') o.coreDir = argv[++i];
    else if (a === '--pr') o.pr = Number(argv[++i]);
    else throw new ConfigError(`unknown argument: ${a}`);
  }
  if (!o.coreDir) throw new ConfigError('--core-dir is required');
  if (!Number.isInteger(o.pr) || o.pr <= 0) throw new ConfigError('--pr <number> is required');
  return o;
}

const git = (coreDir, args) => execFileSync('git', ['-C', coreDir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const gitShow = (coreDir, ref, file) => { try { return git(coreDir, ['show', `${ref}:${file}`]).replace(/\r/g, ''); } catch { return null; } };
const hasCommit = (coreDir, sha) => { try { git(coreDir, ['cat-file', '-e', `${sha}^{commit}`]); return true; } catch { return false; } };

// Fresh reads (O6): bring the PR's base and head into the clone. Objects already present are fine.
function fetchPr(coreDir, pr, base, head) {
  try { git(coreDir, ['fetch', '-q', 'origin', base, head]); } catch {
    try { git(coreDir, ['fetch', '-q', 'origin', `pull/${pr}/head`]); } catch { /* checked below */ }
  }
  for (const sha of [base, head]) {
    if (!hasCommit(coreDir, sha)) throw new PlanError(`cannot read commit ${sha} of PR #${pr} in ${coreDir} (fetch failed)`);
  }
}

// "### ID · title" entries -> Map(id -> lines), trailing blanks and whitespace dropped.
function entries(text) {
  const map = new Map();
  let cur = null;
  for (const line of String(text || '').split('\n')) {
    if (/^#{1,3} /.test(line)) {
      const m = HEADING_RE.exec(line);
      cur = m ? [] : null;
      if (m) map.set(m[1], cur);
    }
    if (cur) cur.push(line.replace(/\s+$/, ''));
  }
  for (const lines of map.values()) while (lines.length && lines[lines.length - 1] === '') lines.pop();
  return map;
}

const sameLines = (a, b) => a.length === b.length && a.every((l, i) => l === b[i]);

// Allowed change to an old entry: exactly one added superseded-by line, nothing else.
function onlySupersededAdded(oldL, newL) {
  if (sameLines(oldL, newL)) return true;
  if (newL.length !== oldL.length + 1) return false;
  const added = newL.findIndex((l, i) => SUPERSEDED_RE.test(l) && sameLines(newL.filter((_, j) => j !== i), oldL));
  return added !== -1;
}

function decisionViolations(coreDir, config, base, head) {
  const out = [];
  for (const name of ['DECISIONS.md', 'RULINGS.md']) {
    const file = `${config.plan.path}/${name}`;
    const before = entries(gitShow(coreDir, base, file));
    const after = entries(gitShow(coreDir, head, file));
    for (const [id, oldL] of before) {
      if (!after.has(id)) out.push(`decision-removed:${id}`);
      else if (!onlySupersededAdded(oldL, after.get(id))) out.push(`decision-edited:${id}`);
    }
  }
  return out;
}

function leaseViolations(coreDir, config, pr, base, head, files) {
  const file = `${config.plan.path}/START-HERE.md`;
  const line1 = (ref) => String(gitShow(coreDir, ref, file) || '').split('\n')[0];
  const touched = files.some((f) => f === file);
  if (touched && line1(base) !== line1(head)) return []; // a handoff: the PR itself moves the lease
  const held = parseLeaseLine(line1(base));
  if (!held) return ['lease-unreadable-at-base'];
  const m = /^\s*lease:\s*([0-9a-f]{16})\s*$/m.exec(String(pr.body || '').replace(/\r/g, ''));
  if (!m) return ['lease-missing'];
  return m[1] === held.token ? [] : ['lease-mismatch'];
}

const claimNo = (name) => { const m = /^t\/(\d+)-/.exec(name); return m ? Number(m[1]) : null; };

function findAffected(gh, config, changed) {
  const ch = new Set(changed);
  const issues = [];
  const { planIds } = readIssues(gh, config.plan.repo);
  const seen = new Set();
  for (const [labelId, iss] of planIds) {
    if (iss.state !== 'open' || seen.has(iss.number)) continue;
    const named = new Set([labelId, ...parseCites(iss.body).keys()]);
    const ids = [...ch].filter((id) => named.has(id)).sort();
    if (ids.length) { seen.add(iss.number); issues.push({ issue: iss.number, ids, kind: 'issue' }); }
  }
  issues.sort((a, b) => a.issue - b.issue);

  const prs = []; const branches = [];
  const nums = new Map(issues.map((a) => [a.issue, a.ids]));
  for (const r of Object.values(config.repos)) {
    for (const p of gh.paginate(`repos/${r.github}/pulls?state=open`)) {
      const ids = [...ch].filter((id) => parseCites(p.body).has(id)).sort();
      if (ids.length) prs.push({ issue: p.number, ids, kind: 'pr', repo: r.github });
    }
    if (!nums.size) continue;
    for (const ref of gh.paginate(`repos/${r.github}/git/matching-refs/heads/t/`)) {
      const name = String(ref.ref || '').replace(/^refs\/heads\//, '');
      const n = claimNo(name);
      if (n !== null && nums.has(n)) branches.push({ issue: n, ids: nums.get(n), kind: 'branch', repo: r.github, branch: name });
    }
  }
  prs.sort((a, b) => a.issue - b.issue);
  branches.sort((a, b) => a.issue - b.issue);
  return [...issues, ...prs, ...branches];
}

function ticked(commentBody) {
  const set = new Set();
  for (const line of String(commentBody || '').replace(/\r/g, '').split('\n')) {
    const m = /^- \[[xX]\] #(\d+)\b/.exec(line);
    if (m) set.add(Number(m[1]));
  }
  return set;
}

function renderComment(changed, affected, done, violations) {
  const lines = [MARKER, '## Plan impact', '', `Changed items: ${changed.length ? changed.join(', ') : 'none'}`, ''];
  const issues = affected.filter((a) => a.kind === 'issue');
  if (issues.length) {
    lines.push('Tick each box once the ticket has been acked or updated for this change:');
    for (const a of issues) lines.push(`- [${done.has(a.issue) ? 'x' : ' '}] #${a.issue} (${a.ids.join(', ')})`);
    lines.push('');
  }
  const prs = affected.filter((a) => a.kind === 'pr');
  if (prs.length) { lines.push('Open PRs citing a changed ID:'); for (const a of prs) lines.push(`- ${a.repo}#${a.issue} (${a.ids.join(', ')})`); lines.push(''); }
  const brs = affected.filter((a) => a.kind === 'branch');
  if (brs.length) { lines.push('Claim branches of affected tickets:'); for (const a of brs) lines.push(`- ${a.repo} ${a.branch} (#${a.issue})`); lines.push(''); }
  if (violations.length) { lines.push('Violations:'); for (const v of violations) lines.push(`- ${v}`); lines.push(''); }
  if (!issues.length && !violations.length) lines.push('Nothing pending.', '');
  return lines.join('\n');
}

function impact(o, config, gh) {
  const planRepo = config.plan.repo;
  const pr = gh.api('GET', `repos/${planRepo}/pulls/${o.pr}`);
  const base = pr.base && pr.base.sha; const head = pr.head && pr.head.sha;
  if (!base || !head) throw new PlanError(`PR #${o.pr} has no base/head sha`);
  const files = gh.paginate(`repos/${planRepo}/pulls/${o.pr}/files`).map((f) => f.filename);
  fetchPr(o.coreDir, o.pr, base, head);

  const before = planHashes(o.coreDir, base, config);
  const after = planHashes(o.coreDir, head, config);
  const changed = [...new Set([...before.keys(), ...after.keys()])].filter((id) => before.get(id) !== after.get(id)).sort();

  const violations = [
    ...decisionViolations(o.coreDir, config, base, head),
    ...leaseViolations(o.coreDir, config, pr, base, head, files),
  ];
  const affected = findAffected(gh, config, changed);

  const comments = gh.paginate(`repos/${planRepo}/issues/${o.pr}/comments`);
  const existing = comments.find((c) => String(c.body || '').replace(/\r/g, '').split('\n')[0] === MARKER);
  const done = existing ? ticked(existing.body) : new Set();
  const pending = affected.filter((a) => a.kind === 'issue' && !done.has(a.issue)).length;
  const result = { changed, affected, violations, pending };

  if (o.apply) {
    let writes = 0;
    const w = (method, p, body) => { if (writes++ > 0) sleepMs(config.github.writeDelayMs); return gh.api(method, p, body); };
    const text = renderComment(changed, affected, done, violations);
    if (existing) w('PATCH', `repos/${planRepo}/issues/comments/${existing.id}`, { body: text });
    else w('POST', `repos/${planRepo}/issues/${o.pr}/comments`, { body: text });
    const bad = pending > 0 || violations.length > 0;
    w('POST', `repos/${planRepo}/statuses/${head}`, {
      state: bad ? 'failure' : 'success',
      context: CONTEXT,
      description: (bad ? `${pending} unticked, ${violations.length} violation(s)` : 'plan impact acknowledged').slice(0, 140),
    });
  }
  return { exitCode: pending === 0 && violations.length === 0 ? 0 : 8, result };
}

function run({ argv, gh, env = process.env }) {
  try {
    const o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    if (!config.plan.repo) throw new ConfigError('plan.repo is not configured');
    return impact(o, config, gh);
  } catch (e) {
    if (e instanceof ConfigError || e instanceof PlanError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

module.exports = { run, parseArgs, entries, onlySupersededAdded };
