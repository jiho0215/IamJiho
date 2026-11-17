// Unit tests of the acceptance runner (run.sh + tap-report.mjs). No network, no sandbox writes.
// Run: node --test --test-timeout=60000 plugins/dev-framework/tests/v6/acceptance/runner.unit.test.mjs
// Each case writes tiny scenario files, runs the REAL run.sh over them, and checks the report and exit code.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HARNESS_URL = pathToFileURL(path.join(HERE, 'harness.mjs')).href;

function runWith(scenarios, expected) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'devfw-runner-'));
  try {
    for (const [name, src] of Object.entries(scenarios)) fs.writeFileSync(path.join(dir, name), src);
    fs.writeFileSync(path.join(dir, 'expected.json'), JSON.stringify(expected));
    const env = { ...process.env, DEVFW_ACCEPT_DIR: dir, DEVFW_SANDBOX_CORE: 'o/core', DEVFW_SANDBOX_CODE: 'o/code' };
    delete env.NODE_TEST_CONTEXT; // else the inner node --test would not emit TAP
    const r = spawnSync('bash', [path.join(HERE, 'run.sh')], {
      encoding: 'utf8', env,
    });
    return { code: r.status, out: r.stdout + r.stderr };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
const head = "import test from 'node:test';\n";

test('I1: a SandboxError thrown by a scenario that should be green makes the runner exit 2', () => {
  const r = runWith({
    'a.accept.mjs': `${head}import { SandboxError } from '${HARNESS_URL}';\ntest('A1: refused', () => { throw new SandboxError('no marker'); });\n`,
  }, { A1: { expect: 'green' } });
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /A1 UNEXPECTED red/);
});

test('I1: an ordinary failure still exits 1, not 2', () => {
  const r = runWith({ 'a.accept.mjs': `${head}test('A1: broken', () => { throw new Error('plain'); });\n` }, { A1: { expect: 'green' } });
  assert.equal(r.code, 1, r.out);
});

test('I2: a skipped scenario never satisfies a green expectation', () => {
  const r = runWith({ 'a.accept.mjs': `${head}test.skip('A1: skipped', () => {});\n` }, { A1: { expect: 'green' } });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /A1 UNEXPECTED skip/);
  assert.doesNotMatch(r.out, /green ok/);
});

test('I2: a todo scenario never satisfies an expectation either', () => {
  const r = runWith({ 'a.accept.mjs': `${head}test('A1: todo', { todo: true }, () => {});\n` }, { A1: { expect: 'green' } });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /A1 UNEXPECTED todo/);
});

test('I5: the reason is matched against the failure message, not the scenario title', () => {
  const r = runWith({
    'a.accept.mjs': `${head}test('A1: plan-edit-guard title', async (t) => { await t.test('sub plan-edit-guard', () => { throw new Error('boom'); }); });\n`,
  }, { A1: { expect: 'red', until: 'later', reason: 'plan-edit-guard' } });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /A1 UNEXPECTED red \(wrong reason/);
  assert.doesNotMatch(r.out, /red ok/);
});

test('I5: a failure whose message carries the reason is red ok', () => {
  const r = runWith({
    'a.accept.mjs': `${head}test('A1: guard', () => { throw new Error('plan-edit-guard is missing'); });\n`,
  }, { A1: { expect: 'red', until: 'later', reason: 'plan-edit-guard' } });
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /A1 red ok \(until later\)/);
});

test('a scenario file that crashes on import reports UNEXPECTED red, never a match', () => {
  const r = runWith({ 'a.accept.mjs': "import './does-not-exist.mjs';\n" }, { A1: { expect: 'red', until: 'later', reason: 'does-not-exist' } });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /A1 UNEXPECTED red/);
});

test('an expected red that passes is UNEXPECTED green', () => {
  const r = runWith({ 'a.accept.mjs': `${head}test('A1: fine', () => {});\n` }, { A1: { expect: 'red', until: 'later', reason: 'nope' } });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /A1 UNEXPECTED green/);
});
