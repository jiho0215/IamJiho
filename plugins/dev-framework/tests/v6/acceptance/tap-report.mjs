// Parses `node --test --test-reporter=tap` output and compares each scenario with expected.json.
// Used by run.sh; unit-tested in runner.unit.test.mjs against REAL TAP captured from node (no network).
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

// -> { scenarios: Map(id -> {name, ok, directive, blocks[], dup}), crashes: block[], noise: string[] }
// A block is the yaml diagnostic of one test: { error, name }. Nested subtest blocks precede their parent's
// result line (deeper indent); a test's own block follows it at indent 2.
export function parseTap(text) {
  const lines = String(text).replace(/\r/g, '').split('\n');
  const scenarios = new Map(); const crashes = []; const noise = [];
  let pending = []; let cur = null; let curOwn = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const m = /^(not ok|ok) \d+ - (.*?)(?: # (SKIP|TODO)\b.*)?$/i.exec(line);
    if (m) {
      cur = { name: m[2], ok: m[1] === 'ok', directive: m[3] ? m[3].toUpperCase() : '', blocks: pending, dup: false };
      pending = []; curOwn = false;
      const id = (/^(A\d+):/.exec(cur.name) || [])[1];
      if (id) { if (scenarios.has(id)) { scenarios.get(id).dup = true; } else scenarios.set(id, cur); }
      else if (!cur.ok) crashes.push(cur);
      continue;
    }
    const open = /^(\s*)---$/.exec(line);
    if (open) {
      const indent = open[1].length; const block = { error: '', name: '' };
      let j = i + 1;
      for (; j < lines.length && !/^\s*\.\.\.$/.test(lines[j]); j++) {
        const kv = new RegExp(`^ {${indent}}(error|name): (.*)$`).exec(lines[j]);
        if (!kv) continue;
        let v = kv[2];
        if (/^\|[-+]?$/.test(v)) {
          const body = [];
          while (j + 1 < lines.length && new RegExp(`^ {${indent + 2}}`).test(lines[j + 1])) body.push(lines[++j].slice(indent + 2));
          v = body.join('\n');
        } else v = v.replace(/^'(.*)'$/, '$1');
        block[kv[1]] = v;
      }
      i = j;
      if (indent === 2 && cur && !curOwn) { cur.blocks.push(block); curOwn = true; } else pending.push(block);
      continue;
    }
    if (/^# \w*Error/.test(line)) noise.push(line.slice(2));
  }
  return { scenarios, crashes, noise };
}

const flat = (s) => String(s || '').replace(/\s+/g, ' ').trim();
const messageOf = (blocks) => flat(blocks.map((b) => b.error).filter(Boolean).join(' | ')).slice(0, 240) || '(no message captured)';

// -> { lines: string[], exitCode: 0|1|2 }
export function evaluate(tapText, expected) {
  const { scenarios, crashes, noise } = parseTap(tapText);
  const out = []; let bad = 0; let guard = false;
  const ids = [...new Set([...Object.keys(expected), ...scenarios.keys()])].sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));
  for (const id of ids) {
    const exp = expected[id]; const r = scenarios.get(id);
    if (!exp) { out.push(`${id} UNEXPECTED: scenario has no entry in expected.json`); bad = 1; continue; }
    if (r && r.dup) { out.push(`${id} UNEXPECTED: more than one result reported for this scenario`); bad = 1; continue; }
    if (r && r.directive) { out.push(`${id} UNEXPECTED ${r.directive.toLowerCase()}: a ${r.directive} scenario never satisfies an expectation`); bad = 1; continue; }
    const blocks = r ? r.blocks : crashes.flatMap((c) => c.blocks);
    const msg = r ? messageOf(blocks) : `no result reported: ${flat(noise[0] || messageOf(blocks)).slice(0, 200)}`;
    const red = !r || !r.ok;
    if (red && exp.expect === 'green' && (blocks.some((b) => b.name === 'SandboxError') || (!r && noise.some((n) => /^SandboxError\b/.test(n))))) guard = true;
    if (exp.expect === 'green') {
      if (!red) out.push(`${id} green ok`); else { out.push(`${id} UNEXPECTED red: ${msg}`); bad = 1; }
    } else if (!red) {
      out.push(`${id} UNEXPECTED green (expected red until ${exp.until}: ${exp.reason})`); bad = 1;
    } else if (!r || !blocks.some((b) => b.error.includes(exp.reason))) {
      out.push(`${id} UNEXPECTED red (wrong reason, wanted "${exp.reason}"): ${msg}`); bad = 1;
    } else out.push(`${id} red ok (until ${exp.until})`);
  }
  return { lines: out, exitCode: guard ? 2 : bad };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [tapFile, expFile] = process.argv.slice(2);
  const { lines, exitCode } = evaluate(fs.readFileSync(tapFile, 'utf8'), JSON.parse(fs.readFileSync(expFile, 'utf8')));
  for (const l of lines) console.log(l);
  process.exit(exitCode);
}
