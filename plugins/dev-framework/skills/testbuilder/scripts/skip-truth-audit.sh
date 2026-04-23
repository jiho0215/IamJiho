#!/usr/bin/env bash
# skip-truth-audit.sh — Phase 5 skip-claim verifier.
#
# Walks the repo looking for disabled tests across common frameworks, extracts
# the human-readable skip message, and verifies any "covered / verified /
# tested in <X>" claim by grepping for a matching test at the claimed location.
# Emits a JSON report of verified vs unverified claims plus skips with no
# claim at all (still valid as long as they carry a tracking link, which
# this script also checks for).
#
# Usage:
#   skip-truth-audit.sh [--repo <path>] [--out <file>]
#
# Defaults: --repo . --out <stdout>
#
# Output shape:
#   {
#     "summary": {"total": N, "verified": N, "unverified": N, "noClaim": N, "noTracking": N},
#     "skips": [
#       {"file": "...", "line": N, "framework": "xunit|nunit|jest|pytest|junit|go",
#        "message": "...", "trackingLink": "GH-123 | null",
#        "claim": {"kind": "covered|verified|tested", "target": "..."} | null,
#        "verified": true|false|null,   // null when no claim
#        "evidence": ["path:line", ...] // empty when unverified or no claim
#       }
#     ]
#   }
#
# Exit codes:
#   0 — script ran to completion (report written); report itself may contain violations
#   2 — invalid CLI args
#   3 — repo path doesn't exist

set -euo pipefail

REPO="."
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$REPO" ]] || { echo "repo not found: $REPO" >&2; exit 3; }

have_rg=0
command -v rg >/dev/null 2>&1 && have_rg=1

# Framework patterns. Each line: framework|regex (PCRE-ish; ripgrep -P compatible).
# We match the *opener* so we can anchor a small window to extract the message.
PATTERNS=(
  'xunit|\[Fact\(Skip\s*=\s*"[^"]*"'
  'xunit|\[Theory\(Skip\s*=\s*"[^"]*"'
  'nunit|\[Ignore\("[^"]*"'
  'junit|@Disabled\("[^"]*"'
  'junit|@Ignore\("[^"]*"'
  'jest|(?:x?it|xdescribe|describe)\.skip\('
  'jest|\bxit\('
  'jest|\bxdescribe\('
  'pytest|@(?:unittest\.skip|pytest\.mark\.skip)\("[^"]*"'
  'go|t\.Skip\('
)

search_one() {
  local framework="$1" pattern="$2"
  if [[ $have_rg -eq 1 ]]; then
    rg --no-heading --with-filename --line-number -P "$pattern" "$REPO" \
      --glob '!node_modules' --glob '!**/bin/**' --glob '!**/obj/**' \
      --glob '!**/.git/**' --glob '!**/dist/**' --glob '!**/build/**' \
      2>/dev/null | while IFS=: read -r file line match; do
        printf '%s\t%s\t%s\t%s\n' "$framework" "$file" "$line" "$match"
      done
  else
    grep -RInE --exclude-dir=node_modules --exclude-dir=.git \
      --exclude-dir=bin --exclude-dir=obj --exclude-dir=dist --exclude-dir=build \
      "$pattern" "$REPO" 2>/dev/null | while IFS=: read -r file line match; do
        printf '%s\t%s\t%s\t%s\n' "$framework" "$file" "$line" "$match"
      done
  fi
}

# Collect raw hits.
raw_tsv="$(mktemp)"
trap 'rm -f "$raw_tsv"' EXIT

for entry in "${PATTERNS[@]}"; do
  fw="${entry%%|*}"
  pat="${entry#*|}"
  search_one "$fw" "$pat" >> "$raw_tsv" || true
done

# Extract message from a matched line. The opener usually contains the message
# after Skip=/Ignore/@Disabled("...")/skip("..."). For framework-heavy multi-line
# decorators (junit/pytest with multi-arg), we read a small window after the hit.
extract_message() {
  local file="$1" line="$2" framework="$3"
  local window
  window="$(sed -n "${line},$((line+4))p" "$file" 2>/dev/null || true)"
  case "$framework" in
    xunit)
      printf '%s' "$window" | grep -oE 'Skip\s*=\s*"[^"]*"' | head -1 \
        | sed -E 's/Skip\s*=\s*"([^"]*)"/\1/' ;;
    nunit)
      printf '%s' "$window" | grep -oE '\[Ignore\("[^"]*"' | head -1 \
        | sed -E 's/\[Ignore\("([^"]*)"/\1/' ;;
    junit)
      printf '%s' "$window" | grep -oE '@(Disabled|Ignore)\("[^"]*"' | head -1 \
        | sed -E 's/@(Disabled|Ignore)\("([^"]*)"/\2/' ;;
    jest)
      printf '%s' "$window" | grep -oE '(skip|xit|xdescribe)\(\s*"[^"]*"|(skip|xit|xdescribe)\(\s*'\''[^'\'']*'\''' | head -1 \
        | sed -E "s/.*(['\"])([^'\"]*)(['\"]).*/\\2/" ;;
    pytest)
      printf '%s' "$window" | grep -oE '@(?:unittest\.skip|pytest\.mark\.skip)\("[^"]*"' | head -1 \
        | sed -E 's/@[^(]*\("([^"]*)"/\1/' ;;
    go)
      printf '%s' "$window" | grep -oE 't\.Skip\(\s*"[^"]*"' | head -1 \
        | sed -E 's/t\.Skip\(\s*"([^"]*)"/\1/' ;;
  esac
}

# Detect a coverage claim inside a message. Returns "kind<TAB>target" or empty.
detect_claim() {
  local msg="$1"
  local kind="" target=""
  # Normalise.
  local lower="${msg,,}"
  for kw in "covered in " "covered by " "verified in " "verified by " "tested in " "tested by "; do
    if [[ "$lower" == *"$kw"* ]]; then
      kind="${kw%% *}"
      # Extract text after the keyword up to the next period/semicolon/comma.
      target="$(printf '%s' "$msg" | sed -E "s/.*[Cc]overed (in|by) |.*[Vv]erified (in|by) |.*[Tt]ested (in|by) //" \
                | sed -E 's/[.;,].*$//' | awk '{$1=$1};1')"
      break
    fi
  done
  [[ -n "$kind" ]] && printf '%s\t%s' "$kind" "$target"
}

# Detect a tracking link (GH-<n>, #<n>, URL, JIRA-STYLE-<n>).
detect_tracking() {
  local msg="$1"
  printf '%s' "$msg" \
    | grep -oE '(https?://[^ )]+|GH-[0-9]+|#[0-9]+|[A-Z]{2,}-[0-9]+)' \
    | head -1 || true
}

# Verify a claim: grep the repo for the target string; return matching "path:line" lines.
verify_claim() {
  local target="$1"
  [[ -z "$target" ]] && return 0
  # Strip surrounding quotes/backticks.
  target="${target//\`/}"
  target="${target//\"/}"
  target="${target//\'/}"
  if [[ $have_rg -eq 1 ]]; then
    rg --no-heading --with-filename --line-number --fixed-strings "$target" "$REPO" \
      --glob '!node_modules' --glob '!**/bin/**' --glob '!**/obj/**' \
      --glob '!**/.git/**' --glob '!**/dist/**' --glob '!**/build/**' \
      2>/dev/null | head -20 || true
  else
    grep -RInF --exclude-dir=node_modules --exclude-dir=.git \
      --exclude-dir=bin --exclude-dir=obj --exclude-dir=dist --exclude-dir=build \
      "$target" "$REPO" 2>/dev/null | head -20 || true
  fi
}

# JSON-escape a string (minimal: backslashes, quotes, control chars).
json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' <<<"$1" 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Build the JSON report. Python path is cleaner; fall back to hand-rolled if absent.
# Pick the first python that actually runs (Windows has a `python3.exe` stub
# that points to the Store installer — exit code 9009/nonzero on invoke).
PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done

if [[ -n "$PY_BIN" ]]; then
  "$PY_BIN" - "$raw_tsv" "$REPO" <<'PY'
import json, os, re, subprocess, sys

raw_path, repo = sys.argv[1], sys.argv[2]

CLAIM_RE = re.compile(r'(covered|verified|tested)\s+(?:in|by)\s+([^.;,]+)', re.I)
TRACK_RE = re.compile(r'(https?://[^ )]+|GH-\d+|#\d+|[A-Z]{2,}-\d+)')

def have_rg():
    return subprocess.run(['rg', '--version'], capture_output=True).returncode == 0
RG = have_rg()

def grep_target(target):
    target = target.strip().strip('`"\'')
    if not target:
        return []
    if RG:
        cmd = ['rg', '--no-heading', '--with-filename', '--line-number',
               '--fixed-strings', target, repo,
               '--glob', '!node_modules', '--glob', '!**/bin/**',
               '--glob', '!**/obj/**', '--glob', '!**/.git/**',
               '--glob', '!**/dist/**', '--glob', '!**/build/**']
    else:
        cmd = ['grep', '-RInF',
               '--exclude-dir=node_modules', '--exclude-dir=.git',
               '--exclude-dir=bin', '--exclude-dir=obj',
               '--exclude-dir=dist', '--exclude-dir=build',
               target, repo]
    r = subprocess.run(cmd, capture_output=True, text=True)
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()][:20]
    return [':'.join(ln.split(':', 2)[:2]) for ln in lines]

def extract_message(file, line_no, framework):
    try:
        with open(file, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
    except OSError:
        return ''
    start = max(0, line_no - 1)
    window = ''.join(lines[start:start + 5])
    patterns = {
        'xunit':  r'Skip\s*=\s*"([^"]*)"',
        'nunit':  r'\[Ignore\("([^"]*)"',
        'junit':  r'@(?:Disabled|Ignore)\("([^"]*)"',
        'jest':   r'(?:skip|xit|xdescribe)\(\s*["\']([^"\']*)["\']',
        'pytest': r'@(?:unittest\.skip|pytest\.mark\.skip)\("([^"]*)"',
        'go':     r't\.Skip\(\s*"([^"]*)"',
    }
    m = re.search(patterns.get(framework, r'(?!)'), window)
    return m.group(1) if m else ''

skips = []
seen = set()
with open(raw_path) as f:
    for tline in f:
        parts = tline.rstrip('\n').split('\t', 3)
        if len(parts) < 4:
            continue
        framework, file, line_s, _opener = parts
        key = (file, line_s)
        if key in seen:
            continue
        seen.add(key)
        try:
            line_no = int(line_s)
        except ValueError:
            continue
        message = extract_message(file, line_no, framework)
        tracking = None
        tm = TRACK_RE.search(message)
        if tm:
            tracking = tm.group(1)
        claim = None
        cm = CLAIM_RE.search(message)
        if cm:
            claim = {'kind': cm.group(1).lower(), 'target': cm.group(2).strip()}
        verified = None
        evidence = []
        if claim:
            evidence = grep_target(claim['target'])
            verified = len(evidence) > 0
        skips.append({
            'file': file,
            'line': line_no,
            'framework': framework,
            'message': message,
            'trackingLink': tracking,
            'claim': claim,
            'verified': verified,
            'evidence': evidence,
        })

summary = {
    'total': len(skips),
    'verified':   sum(1 for s in skips if s['verified'] is True),
    'unverified': sum(1 for s in skips if s['verified'] is False),
    'noClaim':    sum(1 for s in skips if s['verified'] is None),
    'noTracking': sum(1 for s in skips if not s['trackingLink']),
}

json.dump({'summary': summary, 'skips': skips}, sys.stdout, indent=2)
sys.stdout.write('\n')
PY
else
  # Minimal fallback — emit a summary with counts only.
  total=$(wc -l < "$raw_tsv" | tr -d ' ')
  printf '{"summary":{"total":%s,"verified":null,"unverified":null,"noClaim":null,"noTracking":null},"skips":[],"note":"python3 not available; install for full report"}\n' "$total"
fi | if [[ -n "$OUT" ]]; then tee "$OUT" > /dev/null; else cat; fi
