'use strict';
// The one fresh-read rule for the plan (O6). Every reader of the plan of record resolves its ref here.
//   ref given  -> used as-is, no fetch (an explicit, caller-chosen snapshot).
//   no ref     -> fetch origin/<plan.branch> with an explicit refspec, then read origin/<plan.branch>.
// A failed fetch throws PlanFetchError: origin/<branch> may be stale, so no caller may read it as current.
const { execFileSync } = require('node:child_process');
const { PlanError } = require('./plan');

class PlanFetchError extends PlanError {
  constructor(msg) { super(msg); this.name = 'PlanFetchError'; }
}

function resolvePlanRef({ coreDir, config, ref }) {
  if (ref) return ref;
  const b = config && config.plan && config.plan.branch;
  if (!b) throw new PlanFetchError('plan.branch is not configured');
  try {
    execFileSync('git', ['-C', coreDir, 'fetch', '-q', 'origin', `+refs/heads/${b}:refs/remotes/origin/${b}`], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (e) {
    throw new PlanFetchError(`cannot fetch origin ${b} (the plan must be read fresh): ${String(e.stderr || e.message).trim()}`);
  }
  return `origin/${b}`;
}

module.exports = { resolvePlanRef, PlanFetchError };
