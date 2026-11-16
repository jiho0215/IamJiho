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
  github: { writeDelayMs: 1000 },
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
  for (const [name, repo] of Object.entries(config.repos || {})) {
    if (!repo || !['required', 'none'].includes(repo.ci)) {
      throw new ConfigError(`repos.${name}.ci must be "required" or "none", got ${JSON.stringify(repo && repo.ci)}`);
    }
    if (typeof repo.github !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(repo.github)) {
      throw new ConfigError(`repos.${name}.github must be "owner/name", got ${JSON.stringify(repo.github)}`);
    }
  }
  return config;
}

module.exports = { loadConfig, ConfigError };
