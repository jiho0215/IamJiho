'use strict';
// merge-gate checks. Each check returns an array of refusal reasons (empty = pass); nothing here writes to GitHub.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { planHashes, PlanError } = require('./plan');
const { parseCites } = require('./ticket-body');
const { ackCovers } = require('./acks');

const OK_CONCLUSIONS = new Set(['success', 'skipped', 'neutral']);
const git = (coreDir, args) => execFileSync('git', ['-C', coreDir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

// The Evidence block: text after "Evidence:" (same line included) up to the next blank line or heading.
function evidenceBlock(body) {
  const lines = String(body || '').replace(/\r/g, '').split('\n');
  const i = lines.findIndex((l) => /^\s*(?:[-*]\s*)?(?:#{1,6}\s*)?\*{0,2}Evidence:/i.test(l));
  if (i === -1) return '';
  const out = [lines[i].replace(/^.*?Evidence:\*{0,2}/i, '').trim()];
  for (let j = i + 1; j < lines.length; j++) {
    if (!lines[j].trim() || /^\s*#{1,6}\s/.test(lines[j])) break;
    out.push(lines[j]);
  }
  return out.join('\n').trim();
}

function linkedIssue(body, planRepo) {
  const esc = String(planRepo).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const m = new RegExp(`\\bFixes\\s+${esc}#(\\d+)\\b`, 'i').exec(String(body || ''));
  return m ? Number(m[1]) : null;
}

// (a) ci. runs: check-run objects; statuses: commit status objects.
function checkCi({ repoConfig, runs, statuses, evidence }) {
  if (runs.length + statuses.length === 0) {
    if (repoConfig.ci === 'required') return ['ci: no checks attached'];
    const missing = (repoConfig.tests || []).filter((t) => !String(evidence).includes(t));
    return missing.length ? [`ci: none configured and Evidence lacks test command(s): ${missing.join(', ')}`] : [];
  }
  const reasons = [];
  for (const r of runs) {
    if (r.status !== 'completed') reasons.push(`ci: check "${r.name}" is ${r.status || 'pending'}`);
    else if (!OK_CONCLUSIONS.has(r.conclusion)) reasons.push(`ci: check "${r.name}" concluded ${r.conclusion}`);
  }
  for (const s of statuses) {
    if (s.state !== 'success') reasons.push(`ci: status "${s.context}" is ${s.state}`);
  }
  return reasons;
}

// (b) cites. hashes: Map of the plan to judge against; loadComments(issue): the linked issue's comments.
function checkCites({ body, planRepo, hashes, coreDir, config, loadComments }) {
  const cites = parseCites(body);
  if (!cites.size) return ['cites: PR body has no Cites: line'];
  const issue = linkedIssue(body, planRepo);
  if (issue === null) return [`cites: PR body has no "Fixes ${planRepo}#<n>" line`];
  const reasons = [];
  let comments = null;
  for (const [id, hash] of cites) {
    const cur = hashes.get(id);
    if (cur === hash) continue;
    if (!cur) { reasons.push(`cites: ${id} is not in the plan`); continue; }
    if (!comments) comments = loadComments(issue);
    if (!ackCovers({ coreDir, config, comments, issue, id, hash: cur })) {
      reasons.push(`cites: ${id}@${hash} is stale (plan has ${cur}) and issue #${issue} has no covering ack`);
    }
  }
  return reasons;
}

// (c) evidence
function checkEvidence({ evidence }) {
  return evidence ? [] : ['evidence: Evidence block is missing or empty'];
}

// (d) size: pr-size --files over the pulls/<n>/files list
function checkSize({ files, coreDir, env = process.env }) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'devfw-gate-'));
  try {
    const f = path.join(tmp, 'files.json');
    fs.writeFileSync(f, JSON.stringify(files));
    const childEnv = { ...process.env };
    delete childEnv.DEVFW_CONFIG;
    if (env.DEVFW_CONFIG) childEnv.DEVFW_CONFIG = env.DEVFW_CONFIG;
    const script = path.join(__dirname, '..', 'bin', 'pr-size');
    let out;
    try {
      out = execFileSync('bash', [script, '--files', f, '--core-dir', coreDir], { encoding: 'utf8', env: childEnv, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      if (e.status !== 5) throw new ConfigError(`pr-size failed (exit ${e.status}): ${String(e.stderr || e.message).trim()}`);
      out = e.stdout;
    }
    const r = JSON.parse(out);
    return r.verdict === 'ok' ? [] : [`size: ${r.seconds}s read time exceeds the ${r.limit}s limit (${r.files} files, ${r.weightedLines} weighted lines)`];
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// (e) coverage: null when not enforced
function checkCoverage({ config, evidence }) {
  const cov = config.coverage || {};
  if (!cov.enforce) return null;
  const m = /coverage:\s*(\d+(?:\.\d+)?)\s*%/i.exec(evidence);
  if (!m) return ['coverage: Evidence has no "coverage: <n>%" line'];
  return Number(m[1]) >= cov.min ? [] : [`coverage: ${m[1]}% is below the required ${cov.min}%`];
}

// Fresh reads (O6): fetch the plan branch before hashing it. A clone with no remote is read as-is.
function currentPlanHashes(coreDir, config) {
  const b = config.plan.branch;
  try { git(coreDir, ['fetch', '-q', 'origin', b]); } catch { /* planHashes reports a missing ref */ }
  return planHashes(coreDir, `origin/${b}`, config);
}

function evaluate({ gh, config, coreDir, repo, pr, env = process.env, hashes }) {
  const entry = Object.values(config.repos || {}).find((r) => r.github === repo);
  if (!entry) throw new ConfigError(`repo ${repo} is not in the config's repos`);
  const prObj = gh.api('GET', `repos/${repo}/pulls/${pr}`);
  const body = prObj.body || '';
  const head = prObj.head && prObj.head.sha;
  const evidence = evidenceBlock(body);
  const runs = gh.paginate(`repos/${repo}/commits/${head}/check-runs`, { key: 'check_runs' });
  const st = gh.api('GET', `repos/${repo}/commits/${head}/status`);
  const statuses = (st && Array.isArray(st.statuses)) ? st.statuses : [];
  const files = gh.paginate(`repos/${repo}/pulls/${pr}/files`);
  const current = hashes || currentPlanHashes(coreDir, config);
  const loadComments = (n) => gh.paginate(`repos/${config.plan.repo}/issues/${n}/comments`);

  const parts = {
    ci: checkCi({ repoConfig: entry, runs, statuses, evidence }),
    cites: checkCites({ body, planRepo: config.plan.repo, hashes: current, coreDir, config, loadComments }),
    evidence: checkEvidence({ evidence }),
    size: checkSize({ files, coreDir, env }),
    coverage: checkCoverage({ config, evidence }),
  };
  const checks = {};
  const reasons = [];
  for (const [k, v] of Object.entries(parts)) {
    checks[k] = v === null ? null : v.length === 0;
    if (v) reasons.push(...v);
  }
  return { pass: reasons.length === 0, checks, reasons };
}

function parseArgs(argv) {
  const o = { coreDir: '', repo: '', pr: 0 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--core-dir') o.coreDir = argv[++i];
    else if (a === '--repo') o.repo = argv[++i];
    else if (a === '--pr') o.pr = Number(argv[++i]);
    else throw new ConfigError(`unknown argument: ${a}`);
  }
  if (!o.coreDir) throw new ConfigError('--core-dir is required');
  if (!/^[\w.-]+\/[\w.-]+$/.test(o.repo)) throw new ConfigError('--repo <owner/name> is required');
  if (!Number.isInteger(o.pr) || o.pr <= 0) throw new ConfigError('--pr <number> is required');
  return o;
}

function run({ argv, gh, env = process.env }) {
  try {
    const o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    const result = evaluate({ gh, config, coreDir: o.coreDir, repo: o.repo, pr: o.pr, env });
    return { exitCode: result.pass ? 0 : 6, result };
  } catch (e) {
    if (e instanceof ConfigError || e instanceof PlanError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

module.exports = { run, evaluate, checkCi, checkCites, checkEvidence, checkSize, checkCoverage, evidenceBlock, linkedIssue, currentPlanHashes };
