'use strict';
// Thin wrapper over the gh CLI. No search API (separate rate limit, can return incomplete results).
const { execFileSync } = require('node:child_process');

function defaultExec(args, input) {
  return execFileSync('gh', args, { input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

function createGh({ exec = defaultExec } = {}) {
  // Only the search API itself is forbidden; a label such as kind:research is fine.
  const guard = (path) => {
    if (String(path).replace(/^\//, "").split(/[/?]/)[0] === "search") throw new Error("search API forbidden");
  };
  const api = (method, path, body) => {
    guard(path);
    const args = ['api', '-X', method, path];
    let input;
    if (body !== undefined) { args.push('--input', '-'); input = JSON.stringify(body); }
    const out = exec(args, input);
    return out && String(out).trim() ? JSON.parse(out) : {};
  };
  const paginate = (path, { key } = {}) => {
    guard(path);
    const all = [];
    for (let page = 1; ; page++) {
      const sep = path.includes('?') ? '&' : '?';
      const res = api("GET", `${path}${sep}per_page=100&page=${page}`);
      const rows = key ? res && res[key] : res;
      if (!Array.isArray(rows)) throw new Error(`paginate: expected array${key ? " at ." + key : ""} from ${path}`);
      all.push(...rows);
      if (rows.length < 100) return all;
    }
  };
  // Whole request goes as JSON so Int/Boolean/object variables keep their types.
  const graphql = (query, vars = {}) => {
    const out = exec(["api", "graphql", "--input", "-"], JSON.stringify({ query, variables: vars }));
    const parsed = JSON.parse(out);
    if (parsed.errors) throw new Error(`graphql: ${JSON.stringify(parsed.errors)}`);
    return parsed.data;
  };
  const raw = (args, input) => String(exec(args, input));
  return { api, paginate, graphql, raw };
}

module.exports = { createGh };
