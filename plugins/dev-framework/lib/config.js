'use strict';
// Config rule (same as bin/_lib.sh): DEVFW_CONFIG, else <coreDir>/orchestrator.json, else defaults. Never cwd.
const fs = require('node:fs');
const path = require('node:path');

class ConfigError extends Error {
  constructor(msg) { super(msg); this.name = 'ConfigError'; }
}

const DEFAULTS = {
  plan: { repo: '', path: 'docs/plan', branch: 'main' },
  repos: {},
  ownerArea: 'owner',
  stages: {},
  project: { owner: '', number: 0, fields: {} },
  coverage: { enforce: false, min: 90 },
  github: { writeDelayMs: 1000, trustedAuthors: [] }, // trustedAuthors: logins whose comments count besides OWNER/MEMBER/COLLABORATOR
  reconcile: { lookbackDays: 14 },
};

function merge(base, over) {
  if (over === null || typeof over !== 'object' || Array.isArray(over)) return over;
  const out = { ...base };
  for (const [k, v] of Object.entries(over)) {
    out[k] = base && typeof base[k] === 'object' && !Array.isArray(base[k]) && base[k] !== null ? merge(base[k], v) : v;
  }
  return out;
}

function loadConfig({ coreDir, env = process.env } = {}) {
  let file = env.DEVFW_CONFIG || (coreDir ? path.join(coreDir, 'orchestrator.json') : '');
  let user = {};
  if (file && fs.existsSync(file)) {
    try {
      user = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, '').replace(/\r/g, ''));
    } catch (e) {
      throw new ConfigError(`unreadable config ${file}: ${e.message}`);
    }
  } else if (env.DEVFW_CONFIG) {
    throw new ConfigError(`DEVFW_CONFIG file not found: ${env.DEVFW_CONFIG}`);
  }
  const config = merge(DEFAULTS, user);
  validate(config);
  return config;
}

// Fail closed: a missing or malformed value is a ConfigError (exit 2), never a silent default.
const nonEmpty = (v) => typeof v === 'string' && v.trim() !== '';
const OWNER_NAME = /^[\w.-]+\/[\w.-]+$/;

function validate(config) {
  const plan = config.plan || {};
  if (typeof plan.repo !== 'string' || !OWNER_NAME.test(plan.repo)) {
    throw new ConfigError(`plan.repo must be "owner/name", got ${JSON.stringify(plan.repo)}`);
  }
  for (const k of ['branch', 'path']) {
    if (!nonEmpty(plan[k])) throw new ConfigError(`plan.${k} must be a non-empty string, got ${JSON.stringify(plan[k])}`);
  }
  if (!config.repos || typeof config.repos !== 'object' || Array.isArray(config.repos)) {
    throw new ConfigError('repos must be an object');
  }
  for (const [name, repo] of Object.entries(config.repos)) {
    if (!repo || !['required', 'none'].includes(repo.ci)) {
      throw new ConfigError(`repos.${name}.ci must be "required" or "none", got ${JSON.stringify(repo && repo.ci)}`);
    }
    if (typeof repo.github !== 'string' || !OWNER_NAME.test(repo.github)) {
      throw new ConfigError(`repos.${name}.github must be "owner/name", got ${JSON.stringify(repo.github)}`);
    }
    if (!nonEmpty(repo.default)) {
      throw new ConfigError(`repos.${name}.default must be a non-empty branch name, got ${JSON.stringify(repo.default)}`);
    }
    if (repo.ci === 'none' && (!Array.isArray(repo.tests) || repo.tests.length === 0 || !repo.tests.every(nonEmpty))) {
      throw new ConfigError(`repos.${name}.tests must be a non-empty array of test commands when ci is "none", got ${JSON.stringify(repo.tests)}`);
    }
  }
}

module.exports = { loadConfig, ConfigError };
