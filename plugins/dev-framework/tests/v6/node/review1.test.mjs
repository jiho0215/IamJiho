import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fakeGh } from './fake-gh.mjs';

const require = createRequire(import.meta.url);
const { parsePlan } = require('../../../lib/plan.js');
const { createGh } = require('../../../lib/gh.js');
const config = { ownerArea: 'owner', repos: { 'acme-api': { github: 'acme/api', ci: 'required' } } };

const item = (extra) => `### P-1-1 · Thing
- stage: A
- kind: code
- state: ready
${extra}- area: acme-api
- depends: —
- decisions: —
- ticket: acme/core#12

Body text.
`;

test('1: unknown bullet in the field block does not hide a later ticket field', () => {
  const [it] = parsePlan(item('- note: x\n'), config);
  assert.equal(it.fields.ticket, 'acme/core#12');
  assert.equal(it.fields.area, 'acme-api');
  assert.match(it.body, /Body text/);
  assert.match(it.body, /note: x/);
});

test('1: a field-looking line in the body after a blank line stays body', () => {
  const [it] = parsePlan(item('') + '\n- ticket: acme/core#99\n', config);
  assert.equal(it.fields.ticket, 'acme/core#12');
});

test('2: only the search API is forbidden; labels like kind:research are fine', () => {
  const gh = createGh({ exec: () => '[]' });
  assert.throws(() => gh.api('GET', 'search/issues?q=x'), /search API forbidden/);
  assert.throws(() => gh.api('GET', '/search/issues?q=x'), /search API forbidden/);
  assert.deepEqual(gh.api('GET', 'repos/acme/core/issues?labels=kind:research'), []);
  assert.deepEqual(gh.api('GET', 'repos/acme/core/labels/kind:research'), []);
  const { gh: fg } = fakeGh({ 'GET repos/acme/core/issues?labels=kind:research': [] });
  assert.deepEqual(fg.paginate('repos/acme/core/issues?labels=kind:research'), []);
});

test('3: graphql sends numbers and booleans typed, strings as strings', () => {
  let seen;
  const gh = createGh({ exec: (args, input) => { seen = { args, input }; return '{"data":{"ok":1}}'; } });
  assert.deepEqual(gh.graphql('query Q { x }', { number: 1, ok: true, name: 'x', obj: { a: 1 } }), { ok: 1 });
  const req = JSON.parse(seen.input);
  assert.equal(req.query, 'query Q { x }');
  assert.deepEqual(req.variables, { number: 1, ok: true, name: 'x', obj: { a: 1 } });
  assert.ok(!seen.args.some((a) => a === '-f'));
});

test('4: paginate with key reads wrapped lists (check-runs shape)', () => {
  const run = (i) => ({ id: i });
  const p1 = { total_count: 103, check_runs: Array.from({ length: 100 }, (_, i) => run(i)) };
  const p2 = { total_count: 103, check_runs: [run(100), run(101), run(102)] };
  const { gh } = fakeGh({ 'GET repos/acme/api/commits/abc/check-runs': { pages: [p1, p2] } });
  assert.equal(gh.paginate('repos/acme/api/commits/abc/check-runs', { key: 'check_runs' }).length, 103);
  assert.throws(() => gh.paginate('repos/acme/api/commits/abc/check-runs'), /expected array/);
});

test('5a: a flat array of >= 100 rows is one page and terminates', () => {
  const rows = Array.from({ length: 120 }, (_, i) => ({ n: i }));
  const { gh } = fakeGh({ 'GET repos/acme/core/issues': rows });
  assert.equal(gh.paginate('repos/acme/core/issues').length, 120);
});

test('5b: fake graphql routes by operation name or first field, records calls, throws when unrouted', () => {
  const { gh, calls } = fakeGh({ 'GRAPHQL ProjectItems': { node: { id: 'N1' } } });
  assert.deepEqual(gh.graphql('query ProjectItems($n: Int!) { node(n: $n) { id } }', { n: 1 }), { node: { id: 'N1' } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].path, 'graphql');
  assert.deepEqual(calls[0].body.variables, { n: 1 });
  assert.throws(() => gh.graphql('query Other { x }', {}), /unrouted graphql/);
  const { gh: g2 } = fakeGh({ 'POST graphql': { z: 1 } });
  assert.deepEqual(g2.graphql('{ anything }', {}), { z: 1 });
});
