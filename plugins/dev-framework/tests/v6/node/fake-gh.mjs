// fakeGh(routes) -> { gh, calls }. routes: "METHOD path-without-pagination" -> response, or array of pages (GET).
import { createRequire } from 'node:module';
const { createGh } = createRequire(import.meta.url)('../../../lib/gh.js');

export function fakeGh(routes = {}) {
  const calls = [];
  const exec = (args, input) => {
    // createGh builds ['api', '-X', METHOD, path, ...] for API calls; anything else is a raw gh call.
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
    return JSON.stringify(m && Array.isArray(r) && Array.isArray(r[0]) ? (r[page - 1] ?? []) : r);
  };
  return { gh: createGh({ exec }), calls };
}
