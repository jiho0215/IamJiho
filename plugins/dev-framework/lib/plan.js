'use strict';
// PLAN.md parsing and hashing. No GitHub calls.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

class PlanError extends Error {
  constructor(msg) { super(msg); this.name = 'PlanError'; }
}

const ID_RE = /^### ([A-Z]+(?:-[a-z0-9]+)*-[0-9]+) · (.+)$/;
const FIELD_RE = /^- (stage|kind|state|area|depends|decisions|ticket):[ \t]*(.*)$/;
const REQUIRED = ['stage', 'kind', 'state', 'area'];

const list = (v) => (!v || v === '—' ? [] : v.split(',').map((s) => s.trim()).filter((s) => s && s !== '—'));

function parsePlan(text, config) {
  const lines = text.replace(/\r/g, '').split('\n');
  const raw = [];
  let cur = null;
  for (const line of lines) {
    if (/^## /.test(line) || /^### /.test(line)) {
      cur = null;
      const m = ID_RE.exec(line);
      if (m) { cur = { id: m[1], title: m[2].trim(), fields: {}, bodyLines: [], inFields: true }; raw.push(cur); }
      continue;
    }
    if (!cur) continue;
    const f = FIELD_RE.exec(line);
    // Field block: from the heading to the first blank line after a field. Known fields are read anywhere in it;
    // an unknown bullet or stray line inside it is body text but does not end field parsing.
    if (cur.inFields && f) { cur.fields[f[1]] = f[2].trim(); continue; }
    if (cur.inFields && !line.trim() && Object.keys(cur.fields).length) cur.inFields = false;
    cur.bodyLines.push(line);
  }

  const ids = new Set();
  for (const it of raw) {
    if (ids.has(it.id)) throw new PlanError(`duplicate item ID: ${it.id}`);
    ids.add(it.id);
  }
  const ownerArea = (config && config.ownerArea) || 'owner';
  const repoKeys = config && config.repos ? Object.keys(config.repos) : null;
  return raw.map((it) => {
    for (const k of REQUIRED) {
      if (!it.fields[k]) throw new PlanError(`${it.id}: missing required field "${k}"`);
    }
    const repo = it.fields.area.split(/\s+/)[0];
    if (repoKeys && repo !== ownerArea && !repoKeys.includes(repo)) {
      throw new PlanError(`${it.id}: unknown repo "${repo}" in area`);
    }
    const deps = list(it.fields.depends);
    for (const d of deps) {
      if (!ids.has(d)) throw new PlanError(`${it.id}: depends on unknown item ${d}`);
    }
    return {
      id: it.id, title: it.title, fields: { ticket: '—', depends: '—', decisions: '—', ...it.fields },
      repo, deps, decisions: list(it.fields.decisions),
      body: it.bodyLines.join('\n').trim(),
    };
  });
}

function gitShow(coreDir, ref, file) {
  try {
    return execFileSync('git', ['-C', coreDir, 'show', `${ref}:${file}`], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
    });
  } catch {
    return null;
  }
}

function planHashes(coreDir, ref, config) {
  const planPath = (config && config.plan && config.plan.path) || 'docs/plan';
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'devfw-planhash-'));
  try {
    const files = [];
    for (const name of ['PLAN.md', 'DECISIONS.md', 'RULINGS.md']) {
      const text = gitShow(coreDir, ref, `${planPath}/${name}`);
      if (text === null) {
        if (name === 'PLAN.md') throw new PlanError(`${planPath}/PLAN.md not found at ${ref}`);
        continue;
      }
      const f = path.join(tmp, name);
      fs.writeFileSync(f, text.replace(/\r/g, ''));
      files.push(f);
    }
    const script = path.join(__dirname, '..', 'bin', 'plan-hash');
    const out = execFileSync('bash', [script, ...files], { encoding: 'utf8' });
    const map = new Map();
    for (const l of out.replace(/\r/g, '').split('\n')) {
      const m = /^(\S+) ([0-9a-f]{12})$/.exec(l);
      if (m) map.set(m[1], m[2]);
    }
    return map;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

module.exports = { parsePlan, planHashes, PlanError };
