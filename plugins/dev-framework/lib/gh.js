'use strict';
// Thin wrapper over the gh CLI. No search API (separate rate limit, can return incomplete results).
const { execFileSync } = require('node:child_process');

function defaultExec(args, input) {
  return execFileSync('gh', args, { input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

function createGh({ exec = defaultExec } = {}) {
  const guard = (path) => {
    if (/search/i.test(path)) throw new Error('search API forbidden');
  };
  const api = (method, path, body) => {
    guard(path);
    const args = ['api', '-X', method, path];
    let input;
    if (body !== undefined) { args.push('--input', '-'); input = JSON.stringify(body); }
    const out = exec(args, input);
    return out && String(out).trim() ? JSON.parse(out) : {};
  };
  const paginate = (path) => {
    guard(path);
    const all = [];
    for (let page = 1; ; page++) {
      const sep = path.includes('?') ? '&' : '?';
      const rows = api('GET', `${path}${sep}per_page=100&page=${page}`);
      if (!Array.isArray(rows)) throw new Error(`paginate: expected array from ${path}`);
      all.push(...rows);
      if (rows.length < 100) return all;
    }
  };
  const graphql = (query, vars = {}) => {
    const args = ['api', 'graphql', '-f', `query=${query}`];
    for (const [k, v] of Object.entries(vars)) args.push(typeof v === 'number' ? '-F' : '-f', `${k}=${v}`);
    const out = exec(args);
    const parsed = JSON.parse(out);
    if (parsed.errors) throw new Error(`graphql: ${JSON.stringify(parsed.errors)}`);
    return parsed.data;
  };
  const raw = (args, input) => String(exec(args, input));
  return { api, paginate, graphql, raw };
}

module.exports = { createGh };
