// Unit tests of the harness guards. No network, no sandbox writes: every GitHub read/write goes through an injected io.
// Run: node --test --test-timeout=60000 plugins/dev-framework/tests/v6/acceptance/harness.unit.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as H from './harness.mjs';

const { SandboxError } = H;

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CORE = 'o/core'; const CODE = 'o/code';
const ENV = { DEVFW_SANDBOX_CORE: CORE, DEVFW_SANDBOX_CODE: CODE };

// A fake GitHub: per repo { marker: text | null | Error, private, commits, closedPrs }. Records writes.
function fakeIo(world) {
  const writes = []; const reads = [];
  const repo = (r) => { if (!world[r]) throw new Error(`fake: unknown repo ${r}`); return world[r]; };
  return {
    writes, reads,
    io: {
      readMarker(r) { reads.push(['marker', r]); const m = repo(r).marker; if (m instanceof Error) throw m; return m ?? null; },
      repoInfo(r) { reads.push(['info', r]); return { private: repo(r).private !== false, default_branch: 'main' }; },
      commitCount(r, branch, limit) { reads.push(['commits', r, branch, limit]); return Math.min(repo(r).commits ?? 1, limit); },
      closedPrs(r) { reads.push(['prs', r]); return repo(r).closedPrs || []; },
      writeMarker(core, body, message) { writes.push({ core, body, message }); },
    },
  };
}
const sandboxWorld = (over = {}) => ({
  [CORE]: { marker: null, private: true, commits: 2, closedPrs: [], ...(over.core || {}) },
  [CODE]: { marker: null, private: true, commits: 3, closedPrs: [{ number: 5, head: 't/1-x', base: 'run/r202611170000abc' }], ...(over.code || {}) },
});
const init = (world, opts) => H.initSandbox({ env: ENV, confirm: [CORE, CODE], ...opts, io: world.io });

test('I1: --init without --confirm, or with names that differ from env, refuses and writes nothing', async () => {
  for (const confirm of [undefined, null, [], [CORE], [CODE, CORE], [CORE, 'o/other'], [`${CORE} `, CODE], ['O/core', CODE]]) {
    const w = fakeIo(sandboxWorld());
    await assert.rejects(() => init(w, { confirm }), (e) => e instanceof SandboxError && /--confirm/.test(e.message), JSON.stringify(confirm));
    assert.deepEqual(w.writes, []); assert.deepEqual(w.reads, [], 'refused before any GitHub read');
  }
});

test('I1: --force-sandbox never skips --confirm', async () => {
  const w = fakeIo(sandboxWorld());
  await assert.rejects(() => init(w, { confirm: undefined, forceSandbox: true }), /--confirm/);
  assert.deepEqual(w.writes, []);
});

test('I1: a public core or code repo refuses, writes nothing', async () => {
  for (const side of ['core', 'code']) {
    const w = fakeIo(sandboxWorld({ [side]: { private: false } }));
    await assert.rejects(() => init(w), (e) => e instanceof SandboxError && /public/.test(e.message), side);
    assert.deepEqual(w.writes, [], side);
  }
});

test('I1: a repo with more than 20 commits on its default branch refuses; exactly 20 does not', async () => {
  for (const side of ['core', 'code']) {
    const w = fakeIo(sandboxWorld({ [side]: { commits: 500 } }));
    await assert.rejects(() => init(w), (e) => e instanceof SandboxError && /more than 20 commits/.test(e.message), side);
    assert.deepEqual(w.writes, [], side);
  }
  const ok = fakeIo(sandboxWorld({ core: { commits: 20 }, code: { commits: 20 } }));
  await init(ok);
  assert.equal(ok.writes.length, 1);
});

test('I1: a closed PR that is not a run/ PR refuses', async () => {
  const w = fakeIo(sandboxWorld({ code: { closedPrs: [{ number: 9, head: 'feature/login', base: 'main' }] } }));
  await assert.rejects(() => init(w), (e) => e instanceof SandboxError && /#9/.test(e.message));
  assert.deepEqual(w.writes, []);
});

test('I1: --force-sandbox skips the heuristics only', async () => {
  const w = fakeIo(sandboxWorld({ code: { private: false, commits: 999 } }));
  const r = await init(w, { forceSandbox: true });
  assert.equal(r.created, true);
  assert.equal(w.writes.length, 1);
});

test('I1: a marker read that errors (not a 404) refuses, never overwrites', async () => {
  for (const side of ['core', 'code']) {
    const w = fakeIo(sandboxWorld({ [side]: { marker: new Error('HTTP 502: Bad Gateway') } }));
    await assert.rejects(() => init(w), /502/, side);
    assert.deepEqual(w.writes, [], side);
  }
  const forced = fakeIo(sandboxWorld({ core: { marker: new Error('HTTP 403: rate limited') } }));
  await assert.rejects(() => init(forced, { forceSandbox: true }), /403/);
  assert.deepEqual(forced.writes, []);
});

test('I1: a valid sandbox proceeds: one marker write to the core repo listing the code repo', async () => {
  const w = fakeIo(sandboxWorld());
  const r = await init(w);
  assert.deepEqual(r, { created: true, added: false });
  assert.equal(w.writes.length, 1);
  assert.equal(w.writes[0].core, CORE);
  assert.match(w.writes[0].body, new RegExp(`^${CODE}$`, 'm'));
});

test('I1: an existing marker that already lists the code repo is a no-op (no heuristics, no write)', async () => {
  const w = fakeIo(sandboxWorld({ core: { marker: `# sandbox\n${CODE}\n`, private: false, commits: 999 } }));
  const r = await init(w);
  assert.deepEqual(r, { created: false, added: false });
  assert.deepEqual(w.writes, []);
});

test('I1: adding the code repo to an existing marker runs the heuristics first', async () => {
  const bad = fakeIo(sandboxWorld({ core: { marker: '# sandbox\no/other\n' }, code: { commits: 100 } }));
  await assert.rejects(() => init(bad), /more than 20 commits/);
  assert.deepEqual(bad.writes, []);
  const good = fakeIo(sandboxWorld({ core: { marker: '# sandbox\no/other\n' } }));
  assert.deepEqual(await init(good), { created: false, added: true });
  assert.match(good.writes[0].body, /^o\/other$/m);
  assert.match(good.writes[0].body, /^o\/code$/m);
});

test('I1: a code repo carrying a marker refuses', async () => {
  const w = fakeIo(sandboxWorld({ code: { marker: 'x' } }));
  await assert.rejects(() => init(w), SandboxError);
  assert.deepEqual(w.writes, []);
});

test('I1: run.sh --init without --confirm (or mismatched) exits 2 before touching GitHub', () => {
  for (const extra of [[], ['--confirm', CORE], ['--confirm', CORE, 'o/elsewhere'], ['--force-sandbox']]) {
    const r = spawnSync('bash', [path.join(HERE, 'run.sh'), '--init', ...extra], {
      encoding: 'utf8', env: { ...process.env, ...ENV, PATH: process.env.PATH, GH_HOST: 'devfw-no-such-host.invalid' },
    });
    assert.equal(r.status, 2, `${extra.join(' ')}: ${r.stdout}${r.stderr}`);
    assert.match(r.stdout + r.stderr, /--confirm/);
  }
});

// ---------------------------------------------------------------- I3: sweep selection
const NOW = Date.UTC(2026, 10, 17, 12, 0, 0);
const OLD = 'r202611171030abc';   // 90 min before NOW
const FRESH = 'r202611171130xyz'; // 30 min before NOW
const iss = (repo, number, title, labels = [], pr = false) => ({ repo, number, title, labels, pull_request: pr });

test('I3: the sweep picks exactly the stale run items and the run-branch trackers', () => {
  const rows = [
    iss(CORE, 1, `P-${OLD}-1 · Add a ping endpoint`, [`plan:P-${OLD}-1`, `epic:${OLD}`]), // stale: label + title
    iss(CORE, 2, 'Some issue', [`epic:${OLD}`]),                                       // stale: label only
    iss(CODE, 3, `ping ${OLD}`, [], true),                                              // stale: PR titled with the runId
    iss(CORE, 4, `P-${FRESH}-1 · Add a ping endpoint`, [`epic:${FRESH}`]),               // fresh run: never
    iss(CODE, 5, `ping ${FRESH}`, [], true),                                            // fresh run PR: never
    iss(CORE, 6, 'A real issue with no run id', ['bug']),                               // not a run item
    iss(CORE, 7, `merged-stale: ${CODE}#40`, ['merged-stale']),                          // tracker, PR base run/: swept
    iss(CORE, 8, `merged-unverifiable: ${CODE}#41`, ['merged-stale']),                   // tracker, PR base run/: swept
    iss(CORE, 9, `merged-stale: ${CODE}#42`, ['merged-stale']),                          // tracker, PR base main: never
    iss(CORE, 10, `merged-stale: ${CODE}#43`, ['merged-stale']),                         // tracker, PR base unknown: never
    iss(CORE, 11, `mixed ${OLD} ${FRESH}`, []),                                         // names a fresh run too: never
  ];
  const base = new Map([[`${CODE}#40`, `run/${OLD}`], [`${CODE}#41`, `run/${FRESH}`], [`${CODE}#42`, 'main']]);
  const picked = H.selectSweep({ rows, now: NOW, prBase: (repo, n) => base.get(`${repo}#${n}`) ?? null });
  assert.deepEqual(picked.map((x) => `${x.repo}#${x.number}`).sort(), [`${CODE}#3`, `${CORE}#1`, `${CORE}#2`, `${CORE}#7`, `${CORE}#8`].sort());
  for (const x of picked) assert.ok(x.why, 'each pick says why');
});

test('I3: a runId exactly one hour old is not yet stale; one minute more is', () => {
  const at = (id) => H.selectSweep({ rows: [iss(CORE, 1, `x ${id}`)], now: NOW, prBase: () => null }).length;
  assert.equal(at('r202611171100abc'), 0);
  assert.equal(at('r202611171059abc'), 1);
});

test('I3: run.sh --sweep refuses (exit 2) when env is missing, before any GitHub call', () => {
  const env = { ...process.env, GH_HOST: 'devfw-no-such-host.invalid' };
  delete env.DEVFW_SANDBOX_CORE; delete env.DEVFW_SANDBOX_CODE;
  const r = spawnSync('bash', [path.join(HERE, 'run.sh'), '--sweep'], { encoding: 'utf8', env });
  assert.equal(r.status, 2, r.stdout + r.stderr);
});

test('I3: sweep() verifies the sandbox pair before reading or closing anything', async () => {
  const calls = [];
  const io = {
    readMarker: (r) => { calls.push(['marker', r]); return null; },
    listOpen: (r) => { calls.push(['list', r]); return []; },
    prBase: () => { calls.push(['base']); return null; },
    close: (r, n) => { calls.push(['close', r, n]); },
  };
  await assert.rejects(() => H.sweep({ env: ENV, io, now: NOW }), SandboxError);
  assert.deepEqual(calls, [['marker', CORE]]);
});

test('I3: sweep() closes exactly the selected items, in both repos', async () => {
  const closed = [];
  const io = {
    readMarker: () => `# sandbox\n${CODE}\n`,
    listOpen: (r) => (r === CORE ? [iss(CORE, 1, `x ${OLD}`), iss(CORE, 2, `x ${FRESH}`)] : [iss(CODE, 3, `y ${OLD}`, [], true)]),
    prBase: () => null,
    close: (r, n) => { closed.push(`${r}#${n}`); },
  };
  const r = await H.sweep({ env: ENV, io, now: NOW, delayMs: 0 });
  assert.deepEqual(closed.sort(), [`${CODE}#3`, `${CORE}#1`]);
  assert.equal(r.closed.length, 2);
});
