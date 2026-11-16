'use strict';
// ticket-sync: plan of record -> GitHub issues, labels, milestones, Project. Dry run unless --apply.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { loadConfig, ConfigError } = require('./config');
const { parsePlan, planHashes, PlanError } = require('./plan');
const { renderBody, parseCites } = require('./ticket-body');
const { readIssues, sleepMs } = require('./plan-issues');

const COLORS = { plan: 'ededed', epic: 'c5def5', stage: '0e8a16', kind: 'fbca04', state: 'd93f0b', repo: '5319e7' };
const EXTRA_LABELS = [
  ['state:in-progress', COLORS.state], ['state:in-review', COLORS.state], ['state:done', COLORS.state],
  ['state:needs-ack', COLORS.state], ['merged-stale', 'e11d21'],
];

function parseArgs(argv) {
  const o = { apply: false, writeback: false, ref: 'origin/main', coreDir: '', only: '', refresh: new Set() };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') o.apply = true;
    else if (a === '--writeback') o.writeback = true;
    else if (a === '--core-dir') o.coreDir = argv[++i];
    else if (a === '--ref') o.ref = argv[++i];
    else if (a === '--only') o.only = argv[++i];
    else if (a === '--refresh-cites') for (const id of String(argv[++i] || '').split(',')) { if (id.trim()) o.refresh.add(id.trim()); }
    else throw new ConfigError(`unknown argument: ${a}`);
  }
  if (!o.coreDir) throw new ConfigError('--core-dir is required');
  return o;
}

function gitOut(coreDir, args) {
  return execFileSync('git', ['-C', coreDir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

// Unified-style line diff: "-" = on GitHub now, "+" = what the plan renders. Unchanged lines are omitted.
function lineDiff(a, b) {
  const x = a.split('\n'); const y = b.split('\n');
  const dp = Array.from({ length: x.length + 1 }, () => new Array(y.length + 1).fill(0));
  for (let i = x.length - 1; i >= 0; i--) {
    for (let j = y.length - 1; j >= 0; j--) dp[i][j] = x[i] === y[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  }
  const out = [];
  let i = 0; let j = 0;
  while (i < x.length || j < y.length) {
    if (i < x.length && j < y.length && x[i] === y[j]) { i++; j++; }
    else if (j >= y.length || (i < x.length && dp[i + 1][j] >= dp[i][j + 1])) out.push(`-${x[i++]}`);
    else out.push(`+${y[j++]}`);
  }
  return out.join('\n');
}

// The banner carries the plan commit; moving main must not make every issue "drift".
const norm = (s) => String(s || '').replace(/\r/g, '').replace(/^(> Mirror of .*plan at `)[0-9a-f]*(`)/, '$1$2').replace(/\s+$/, '');

function itemLabels(item, config) {
  const f = item.fields;
  return [
    `plan:${item.id}`, `epic:${item.id.split('-')[1]}`, `stage:${f.stage}`, `kind:${f.kind}`,
    `state:${f.state}`, `repo:${repoLabel(item, config)}`,
  ];
}
function repoLabel(item, config) {
  if (item.repo === config.ownerArea) return 'owner';
  const r = config.repos[item.repo];
  return (r && r.label) || item.repo;
}
const labelColor = (name) => COLORS[name.split(':')[0]] || COLORS.plan;

function readProject(gh, config) {
  const { owner, number } = config.project;
  const mk = (root) => `query ProjectInfo($owner:String!,$number:Int!,$cursor:String){${root}(login:$owner){projectV2(number:$number){id fields(first:50){nodes{... on ProjectV2SingleSelectField{id name options{id name}}}} items(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{id content{... on Issue{number repository{nameWithOwner}}} fieldValues(first:20){nodes{... on ProjectV2ItemFieldSingleSelectValue{name field{... on ProjectV2SingleSelectField{name}}}}}}}}}}`;
  let root = 'user';
  const fetchPage = (cursor) => {
    try { return gh.graphql(mk(root), { owner, number, cursor }); } catch (e) {
      if (root !== 'user') throw e;
      root = 'organization';
      return gh.graphql(mk(root), { owner, number, cursor });
    }
  };
  let data = fetchPage(null);
  let proj = (data.user || data.organization || {}).projectV2;
  if (!proj) throw new ConfigError(`project ${owner}/${number} not found`);
  const id = proj.id; const fields = (proj.fields.nodes || []).filter((f) => f && f.name);
  const items = [...(proj.items.nodes || [])];
  while (proj.items.pageInfo && proj.items.pageInfo.hasNextPage) {
    data = fetchPage(proj.items.pageInfo.endCursor);
    proj = (data.user || data.organization).projectV2;
    items.push(...(proj.items.nodes || []));
  }
  return { id, fields, items };
}

function writebackPlan(coreDir, config, numbers) {
  const file = path.join(coreDir, config.plan.path, 'PLAN.md');
  const text = fs.readFileSync(file, 'utf8');
  const parts = text.split(/(\r?\n)/);
  let cur = null; let changed = 0;
  for (let i = 0; i < parts.length; i += 2) {
    const line = parts[i];
    const h = /^### ([A-Z]+(?:-[a-z0-9]+)*-[0-9]+) · /.exec(line);
    if (h) { cur = h[1]; continue; }
    if (/^##? /.test(line)) { cur = null; continue; }
    if (cur && /^- ticket:/.test(line) && numbers.has(cur)) {
      const want = `- ticket: ${config.plan.repo}#${numbers.get(cur)}`;
      if (line.trimEnd() !== want) { parts[i] = want; changed++; }
    }
  }
  if (changed) fs.writeFileSync(file, parts.join(''));
  return changed;
}

function run({ argv, gh, env = process.env }) {
  let o;
  try {
    o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    if (!config.plan.repo) throw new ConfigError('plan.repo is not configured');
    return { exitCode: undefined, ...sync(o, config, gh) };
  } catch (e) {
    if (e instanceof ConfigError || e instanceof PlanError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

function sync(o, config, gh) {
  const planRepo = config.plan.repo;
  let planSha;
  try { planSha = gitOut(o.coreDir, ['rev-parse', o.ref]).trim(); } catch (e) { throw new PlanError(`cannot resolve ref ${o.ref}`); }
  let text;
  try { text = gitOut(o.coreDir, ['show', `${o.ref}:${config.plan.path}/PLAN.md`]); } catch (e) { throw new PlanError(`${config.plan.path}/PLAN.md not found at ${o.ref}`); }
  const allItems = parsePlan(text, config);
  const hashes = planHashes(o.coreDir, o.ref, config);
  for (const it of allItems) {
    if (!config.stages[it.fields.stage]) throw new ConfigError(`${it.id}: stage "${it.fields.stage}" is not in config.stages`);
  }
  const items = o.only ? allItems.filter((i) => i.id === o.only) : allItems;
  if (o.only && !items.length) throw new PlanError(`--only ${o.only}: no such item`);

  const { byId, planIds } = readIssues(gh, planRepo);
  const numbers = new Map();
  for (const [id, iss] of byId) numbers.set(id, iss.number);
  const itemIds = new Set(allItems.map((i) => i.id));
  const extra = planIds.filter(([id, iss]) => iss.state === 'open' && !itemIds.has(id)).map(([, iss]) => iss.number);
  const missing = items.filter((i) => !byId.has(i.id)).map((i) => i.id);

  // An existing issue keeps the Cites hashes it already carries (reconcile reads them to raise needs-ack);
  // only --refresh-cites <ID> re-renders that issue's Cites with the current plan.
  const render = (item) => {
    const iss = byId.get(item.id);
    const keepCites = iss && !o.refresh.has(item.id) ? parseCites(iss.body) : undefined;
    return renderBody(item, { hashes, issueNumbers: numbers, planSha, config, keepCites });
  };
  const computeDrift = () => {
    const d = [];
    for (const item of items) {
      const iss = byId.get(item.id);
      if (!iss) continue;
      const want = render(item);
      if (norm(iss.body) !== norm(want)) d.push({ id: item.id, issue: iss.number, diff: lineDiff(norm(iss.body), norm(want)), want });
    }
    return d;
  };
  const drift0 = computeDrift();

  const labels = gh.paginate(`repos/${planRepo}/labels`);
  const have = new Set(labels.map((l) => l.name.toLowerCase()));
  const wanted = new Map();
  for (const it of items) for (const n of itemLabels(it, config)) wanted.set(n, labelColor(n));
  for (const [n, c] of EXTRA_LABELS) wanted.set(n, c);
  const labelsMissing = [...wanted.keys()].filter((n) => !have.has(n.toLowerCase()));

  const publicDrift = (d) => d.map(({ id, issue, diff }) => ({ id, issue, diff }));
  const result = { missing, extra, drift: publicDrift(drift0), labelsMissing, ok: items.filter((i) => byId.has(i.id)).length - drift0.length };

  if (!o.apply) {
    let wrote = 0;
    if (o.writeback) wrote = writebackPlan(o.coreDir, config, numbers);
    if (o.writeback) result.writeback = wrote;
    return { exitCode: missing.length || drift0.length ? 7 : 0, result };
  }

  // --apply
  let writesDone = 0;
  const pace = () => { if (writesDone++ > 0) sleepMs(config.github.writeDelayMs); };
  const write = (method, p, body) => { pace(); return gh.api(method, p, body); };

  for (const name of labelsMissing) write('POST', `repos/${planRepo}/labels`, { name, color: wanted.get(name) });

  const milestones = new Map(gh.paginate(`repos/${planRepo}/milestones?state=all`).map((m) => [m.title, m.number]));
  const stageKeys = [...new Set(allItems.map((i) => i.fields.stage))];
  for (const k of stageKeys) {
    const title = config.stages[k];
    if (!milestones.has(title)) milestones.set(title, write('POST', `repos/${planRepo}/milestones`, { title }).number);
  }
  for (const title of Object.values(config.stages)) {
    if (!milestones.has(title)) milestones.set(title, write('POST', `repos/${planRepo}/milestones`, { title }).number);
  }

  const created = [];
  for (const item of items) {
    if (byId.has(item.id)) continue;
    const iss = write('POST', `repos/${planRepo}/issues`, {
      title: `${item.id} · ${item.title}`, body: render(item),
      milestone: milestones.get(config.stages[item.fields.stage]), labels: itemLabels(item, config),
    });
    byId.set(item.id, iss);
    numbers.set(item.id, iss.number);
    created.push({ id: item.id, issue: iss.number });
  }

  // Bodies depend on other issues' numbers: settle them now that every number is known.
  const patched = [];
  for (const d of computeDrift()) {
    write('PATCH', `repos/${planRepo}/issues/${d.issue}`, { body: d.want });
    byId.get(d.id).body = d.want;
    patched.push({ id: d.id, issue: d.issue });
  }

  const project = config.project && config.project.number ? syncProject(gh, config, items, byId, pace) : null;
  if (o.writeback) result.writeback = writebackPlan(o.coreDir, config, numbers);
  Object.assign(result, { created, patched });
  if (project) result.project = project;
  return { exitCode: 0, result };
}

function syncProject(gh, config, items, byId, pace) {
  const proj = readProject(gh, config);
  const added = []; const set = []; const missingOptions = [];
  const itemFor = new Map();
  for (const pi of proj.items) {
    const c = pi.content;
    if (c && c.number && (!c.repository || c.repository.nameWithOwner === config.plan.repo)) itemFor.set(c.number, pi);
  }
  for (const item of items) {
    const iss = byId.get(item.id);
    let pi = itemFor.get(iss.number);
    if (!pi) {
      pace();
      const r = gh.graphql(
        'mutation AddItem($projectId:ID!,$contentId:ID!){addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){item{id}}}',
        { projectId: proj.id, contentId: iss.node_id },
      );
      pi = { id: r.addProjectV2ItemById.item.id, fieldValues: { nodes: [] } };
      itemFor.set(iss.number, pi);
      added.push(item.id);
    }
    for (const [fieldName, source] of Object.entries(config.project.fields)) {
      const want = source === 'stage' ? config.stages[item.fields.stage] : source === 'repo' ? repoLabel(item, config) : item.fields[source];
      const field = proj.fields.find((f) => f.name === fieldName);
      const opt = field && (field.options || []).find((x) => x.name === want || (source === 'stage' && x.name === item.fields.stage));
      if (!opt) { missingOptions.push({ id: item.id, field: fieldName, value: want }); continue; }
      const cur = ((pi.fieldValues || {}).nodes || []).find((v) => v && v.field && v.field.name === fieldName);
      if (cur && cur.name === opt.name) continue;
      pace();
      gh.graphql(
        'mutation SetField($projectId:ID!,$itemId:ID!,$fieldId:ID!,$optionId:String!){updateProjectV2ItemFieldValue(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:{singleSelectOptionId:$optionId}}){projectV2Item{id}}}',
        { projectId: proj.id, itemId: pi.id, fieldId: field.id, optionId: opt.id },
      );
      set.push({ id: item.id, field: fieldName, value: opt.name });
    }
  }
  return { added, set, missingOptions };
}

module.exports = { run, lineDiff, parseArgs };
