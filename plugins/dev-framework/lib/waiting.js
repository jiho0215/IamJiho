'use strict';
// waiting: who is the pipeline waiting on? Read from issue comments, once, repo-wide (never /search).
const { loadConfig, ConfigError } = require('./config');
const { parseCommand } = require('./comments');

const WINDOW_DAYS = 30;
const OWNER_KINDS = new Set(['owner-ask', 'plan-ready', 'stopped']);

function parseArgs(argv) {
  const o = { coreDir: '' };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--core-dir') o.coreDir = argv[++i];
    else throw new ConfigError(`unknown argument: ${argv[i]}`);
  }
  if (!o.coreDir) throw new ConfigError('--core-dir is required');
  return o;
}

const ts = (c) => Date.parse(c.created_at);

function waiting(comments) {
  const cmds = [];
  for (const c of comments) {
    const cmd = parseCommand(c.body);
    if (cmd && !Number.isNaN(ts(c))) cmds.push({ ...cmd, at: ts(c), since: c.created_at, url: c.html_url || '', id: c.id });
  }
  cmds.sort((a, b) => a.at - b.at || (a.id || 0) - (b.id || 0));
  // "later" = strictly later created_at on the same issue.
  const clearedBy = (cmd, kind) => cmds.some((x) => x.kind === kind && x.issue === cmd.issue && x.at > cmd.at);
  const row = (x) => ({ issue: x.issue, kind: x.kind, since: x.since, url: x.url });
  return {
    owner: cmds.filter((x) => OWNER_KINDS.has(x.kind) && !clearedBy(x, 'owner-said')).map(row),
    orchestrator: cmds.filter((x) => x.kind === 'plan-request' && !clearedBy(x, 'plan-applied')).map(row),
  };
}

function run({ argv, gh, env = process.env }) {
  try {
    const o = parseArgs(argv);
    const config = loadConfig({ coreDir: o.coreDir, env });
    if (!config.plan.repo) throw new ConfigError('plan.repo is not configured');
    const since = new Date(Date.now() - WINDOW_DAYS * 86400000).toISOString().replace(/\.\d+Z$/, 'Z');
    const comments = gh.paginate(`repos/${config.plan.repo}/issues/comments?since=${since}`);
    return { exitCode: 0, result: waiting(comments) };
  } catch (e) {
    if (e instanceof ConfigError) return { exitCode: 2, result: { error: e.message } };
    throw e;
  }
}

module.exports = { run, waiting };
