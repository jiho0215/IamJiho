#!/bin/bash
# Acceptance runner (needs the network; writes only to the sandbox repos). Not part of tests/v6/run.sh.
#   run.sh          run every acceptance/*.accept.mjs and compare with expected.json
#   run.sh --init   one-time: commit the DEVFW_SANDBOX marker to the sandbox core repo's main
# Exit: 0 every scenario matches expected.json, 1 a mismatch, 2 sandbox/env guard.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${DEVFW_SANDBOX_CORE:-}" ] || [ -z "${DEVFW_SANDBOX_CODE:-}" ]; then
  echo "run.sh: set DEVFW_SANDBOX_CORE and DEVFW_SANDBOX_CODE (owner/name of the sandbox repos)" >&2
  exit 2
fi
if [ "${1:-}" = "--init" ]; then
  node "$DIR/harness.mjs" --init; exit $?
fi

TAP="$(mktemp)"; trap 'rm -f "$TAP"' EXIT
node --test --test-timeout=300000 --test-reporter=tap "$DIR"/*.accept.mjs >"$TAP" 2>&1

node - "$TAP" "$DIR/expected.json" <<'JS'
const fs = require('node:fs');
const [tapFile, expFile] = process.argv.slice(2);
const expected = JSON.parse(fs.readFileSync(expFile, 'utf8'));
const lines = fs.readFileSync(tapFile, 'utf8').replace(/\r/g, '').split('\n');

// Top-level result lines are unindented; nested subtests precede their parent, its yaml diagnostics follow it.
const results = []; let buf = []; let last = null; let inYaml = false;
for (const line of lines) {
  const m = /^(not ok|ok) \d+ - (.*?)( # .*)?$/.exec(line);
  if (m) {
    last = { name: m[2], ok: m[1] === 'ok', text: buf.join('\n') };
    results.push(last); buf = []; inYaml = true; continue;
  }
  if (last && inYaml) { last.text += '\n' + line; if (/^ {2}\.\.\.$/.test(line)) inYaml = false; continue; }
  buf.push(line);
}
const byId = new Map();
for (const r of results) { const id = (/^(A\d+):/.exec(r.name) || [])[1]; if (id) byId.set(id, r); }
const tail = buf.join('\n') + '\n' + results.filter((r) => !/^A\d+:/.test(r.name) && !r.ok).map((r) => `${r.name}\n${r.text}`).join('\n');

const msg = (text) => {
  const t = String(text || '');
  const i = t.search(/error: /);
  let s = i >= 0 ? t.slice(i + 7).split('\n').filter((l) => l.trim() && !/^\s*(\.\.\.|---)\s*$/.test(l)).slice(0, 3).join(' ') : t.split('\n').filter((l) => /not ok|Error/.test(l)).slice(0, 3).join(' ');
  return s.replace(/\s+/g, ' ').trim().slice(0, 240) || '(no message captured)';
};

let bad = 0; let guard = false;
const ids = [...new Set([...Object.keys(expected), ...byId.keys()])].sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));
for (const id of ids) {
  const exp = expected[id]; const r = byId.get(id);
  if (!exp) { console.log(`${id} UNEXPECTED: scenario has no entry in expected.json`); bad = 1; continue; }
  const actual = r ? (r.ok ? 'green' : 'red') : 'red';
  const crash = /^# (\w*Error.*)$/m.exec(tail);
  const m = r ? msg(r.text) : `no result reported: ${crash ? crash[1].slice(0, 200) : msg(tail)}`;
  if (actual === 'red' && /SandboxError: /.test(r ? r.text : tail) && exp.expect === 'green') guard = true;
  if (exp.expect === 'green') {
    if (actual === 'green') console.log(`${id} green ok`);
    else { console.log(`${id} UNEXPECTED red: ${m}`); bad = 1; }
  } else if (actual === 'green') {
    console.log(`${id} UNEXPECTED green (expected red until ${exp.until}: ${exp.reason})`); bad = 1;
  } else if (!r || !(r.text.includes(exp.reason))) {
    console.log(`${id} UNEXPECTED red (wrong reason, wanted "${exp.reason}"): ${m}`); bad = 1;
  } else console.log(`${id} red ok (until ${exp.until})`);
}
process.exit(guard ? 2 : bad);
JS
exit $?
