// fakeGh(routes) -> { gh, calls }.
// routes: "METHOD path-without-pagination" -> response.
//   A flat array (or any value) is ONE page. Multi-page is explicit: { pages: [page1, page2, ...] }
//   where each page is an array, or an object such as { check_runs: [...] } for wrapped endpoints.
//   Exception: a git/matching-refs route returns its whole list for every page=, as the real endpoint does.
// GraphQL: "GRAPHQL <operationName or first field>" or "POST graphql" -> response data. Recorded in calls
//   as { method: 'POST', path: 'graphql', body: { query, variables } }. An unrouted graphql call throws.
// Writes are recorded in calls; unrouted writes default to {}; an unrouted GET throws.
import { createRequire } from 'node:module';
const { createGh } = createRequire(import.meta.url)('../../../lib/gh.js');

function graphqlKeys(query) {
  const op = /^\s*(?:query|mutation)\s+(\w+)/.exec(query);
  const first = /\{\s*(\w+)/.exec(query);
  return [op && op[1], first && first[1]].filter(Boolean).map((k) => `GRAPHQL ${k}`).concat('POST graphql');
}

export function fakeGh(routes = {}) {
  const calls = [];
  const exec = (args, input) => {
    if (args[0] === 'api' && args[1] === 'graphql') {
      const body = JSON.parse(input);
      calls.push({ method: 'POST', path: 'graphql', body });
      const key = graphqlKeys(body.query).find((k) => k in routes);
      if (!key) throw new Error(`fakeGh: unrouted graphql ${graphqlKeys(body.query)[0]}`);
      return JSON.stringify({ data: routes[key] });
    }
    if (args[0] !== 'api') {
      calls.push({ method: 'RAW', path: args.join(' '), body: input });
      return routes['RAW ' + args.join(' ')] ?? '';
    }
    const method = args[args.indexOf('-X') + 1];
    const path = args[args.indexOf('-X') + 2];
    const m = /^(.*?)[?&]per_page=100&page=(\d+)$/.exec(path);
    const base = m ? m[1] : path;
    const page = m ? Number(m[2]) : 1;
    const key = `${method} ${base}`;
    if (method !== 'GET') {
      calls.push({ method, path: base, body: input ? JSON.parse(input) : undefined });
      return JSON.stringify(key in routes ? routes[key] : {});
    }
    if (!(key in routes)) throw new Error(`fakeGh: unrouted ${key}`);
    const r = routes[key];
    if (r && typeof r === 'object' && !Array.isArray(r) && Array.isArray(r.pages)) {
      const empty = Array.isArray(r.pages[0]) ? [] : Object.fromEntries(Object.keys(r.pages[0] || {}).map((k) => [k, Array.isArray(r.pages[0][k]) ? [] : r.pages[0][k]]));
      return JSON.stringify(r.pages[page - 1] ?? empty);
    }
    // git/matching-refs ignores page= on the real API (verified live): every page is the full list.
    if (/\/git\/matching-refs\//.test(base)) return JSON.stringify(r);
    // Flat value: one page. Later pages are empty so a flat array of >= 100 rows terminates.
    return JSON.stringify(m && page > 1 && Array.isArray(r) ? [] : r);
  };
  return { gh: createGh({ exec }), calls };
}
