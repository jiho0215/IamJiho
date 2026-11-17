// A9: the two-machine claim race. NOT a *.accept.mjs file; run.sh never runs it. See ../manual/claim-race.md.
//   node a9-two-machine.mjs --issue <n> --slug <s> --at <HH:MM:SS UTC> [--rounds 5] [--gap 30] [--base main]
//   node a9-two-machine.mjs --verify --issue <n> --slug <s> [--rounds 5] [--base main]
// Run the SAME command on both machines. Round k claims issue <n>+k-1 with slug <s><k> (one issue, one claim: a
// repeated issue number would make every later round lose before any push), starting at <at> + (k-1)*gap seconds.
// Sandbox repos come only from env DEVFW_SANDBOX_CORE / DEVFW_SANDBOX_CODE; the marker check runs before any write.
import { spawnSync, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifySandboxPair, SandboxError } from './harness.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLAIM = path.resolve(HERE, '..', '..', '..', 'bin', 'claim');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const die = (msg, code = 2) => { console.error(msg); process.exit(code); };

function parseArgs(argv) {
  const o = { rounds: 5, gap: 30, base: 'main', verify: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--verify') o.verify = true;
    else if (['--issue', '--slug', '--at', '--rounds', '--gap', '--base'].includes(a)) o[a.slice(2)] = argv[++i];
    else die(`unknown argument: ${a}`);
  }
  o.rounds = Number(o.rounds); o.gap = Number(o.gap); o.issue = Number(o.issue);
  if (!Number.isInteger(o.issue) || o.issue < 1) die('--issue must be a positive integer');
  if (!/^[a-z0-9-]{1,30}$/.test(o.slug || '')) die('--slug must match ^[a-z0-9-]{1,30}$');
  if (!Number.isInteger(o.rounds) || o.rounds < 1 || o.rounds > 20) die('--rounds must be 1..20');
  if (!(o.gap >= 0)) die('--gap must be >= 0 seconds');
  if (!o.verify && !/^\d\d:\d\d:\d\d$/.test(o.at || '')) die('--at <HH:MM:SS UTC> is required');
  return o;
}

function cloneCode(code) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'devfw-a9-'));
  const r = spawnSync('gh', ['repo', 'clone', code, path.join(dir, 'code'), '--', '-q'], { encoding: 'utf8' });
  if (r.status !== 0) die(`clone failed: ${(r.stderr || '').trim()}`, 1);
  return { tmp: dir, dir: path.join(dir, 'code') };
}

// Next occurrence of HH:MM:SS UTC; if it is already past by more than 12 h we mean tomorrow, otherwise it is an error.
function startMs(at) {
  const [h, m, s] = at.split(':').map(Number);
  const now = new Date();
  const t = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), h, m, s);
  if (t < now.getTime() - 5000) die(`--at ${at} UTC is already past (now ${now.toISOString()}); agree a later time`);
  return t;
}

async function race(o, code) {
  const { tmp, dir } = cloneCode(code);                 // a fresh clone, fetched before the start time
  try {
    const t0 = startMs(o.at);
    for (let k = 1; k <= o.rounds; k++) {
      const wait = t0 + (k - 1) * o.gap * 1000 - Date.now();
      if (wait > 0) await sleep(wait);
      const issue = o.issue + k - 1;
      const r = spawnSync('bash', [CLAIM, String(issue), `${o.slug}${k}`, '--repo-dir', dir, '--base', o.base], { encoding: 'utf8' });
      let json = null;
      const last = (r.stdout || '').split('\n').map((l) => l.trim()).filter(Boolean).pop();
      try { json = JSON.parse(last); } catch { /* reported below */ }
      console.log(JSON.stringify({ round: k, issue, machine: os.hostname(), code: r.status, result: json ? json.result : 'error',
        branch: json && json.branch, at: new Date().toISOString(), ...(json ? {} : { stderr: (r.stderr || '').trim() }) }));
    }
  } finally { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* temp cleaner */ } }
}

function verify(o, code) {
  const { tmp, dir } = cloneCode(code);
  try {
    const me = os.hostname();
    let ok = true;
    for (let k = 1; k <= o.rounds; k++) {
      const issue = o.issue + k - 1;
      const ref = `t/${issue}-${o.slug}${k}`;
      const f = spawnSync('git', ['-C', dir, 'rev-parse', '--verify', '-q', `origin/${ref}^{commit}`], { encoding: 'utf8' });
      if (f.status !== 0) { ok = false; console.log(JSON.stringify({ round: k, ref, winner: null, note: 'no such ref' })); continue; }
      const body = execFileSync('git', ['-C', dir, 'log', '-1', '--format=%B', f.stdout.trim()], { encoding: 'utf8' }).replace(/\r/g, '');
      const t = (n) => (body.match(new RegExp(`^${n}: (.*)$`, 'm')) || [])[1] || null;
      const machine = t('Claim-Machine');
      console.log(JSON.stringify({ round: k, ref, winner: machine, thisMachine: machine === me, issue: t('Claim-Issue'), at: t('Claim-At'), nonce: t('Claim-Nonce') }));
    }
    console.log(JSON.stringify({ verified: ok, rounds: o.rounds, me }));
    if (!ok) process.exitCode = 1;
  } finally { try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* temp cleaner */ } }
}

const o = parseArgs(process.argv.slice(2));
let pair;
try { pair = verifySandboxPair(); } catch (e) { die(`${e.name}: ${e.message}`, e instanceof SandboxError ? 2 : 1); }
if (o.verify) verify(o, pair.code); else await race(o, pair.code);
