'use strict';
// parseCommand: reads a Bash command line the way the v6 guards need it. It reports the merges, pushes,
// branch creations and commits the line would run, and lists as `opaque` every segment that mentions one of
// those but cannot be read exactly. Pure: no I/O, no environment.
//
// Reading rules (plan 3, task 2 + controller ruling R1):
// - Segments split on && || ; | & and newlines outside quotes; ( ) group, and a cd inside a group stays there.
// - Words honour '…', "…", backslash escapes, $'…', heredocs (body skipped) and redirections (dropped).
// - $(…), `…` and <(…) bodies are parsed too: they run. A word holding one is "dynamic".
// - A dynamic word in a needed argument (dir, remote, refspec, branch, PR, repo) makes the segment opaque;
//   an UNQUOTED dynamic word anywhere in a guarded git/gh call does too (word splitting can add flags).
//   A quoted dynamic word elsewhere (a commit message "$(cat <<'EOF' …)") is fine.
// - R1: a literal `cd <dir>` is the default dir of later segments (relative to the hook cwd). A cd whose
//   target cannot be read makes every later guarded git / gh-merge segment opaque.
// - A gh merge with no explicit repo after a cd is opaque: Merge has no dir, so its repo would be guessed.
// - eval, xargs, sh/bash -c, env -C/-S and friends are opaque when the segment mentions a guarded command.
// - Once a call is classified as guarded (push, commit, worktree add, a branch creation, gh pr merge, a merge
//   endpoint), an unreadable part makes it opaque UNCONDITIONALLY; the MENTION text test gates only the cases
//   decided before we know what the call is (dynamic command word, unknown git global option, exec wrappers).
// - push --all/--branches is opaque (pushes every branch yet names none); --tags reports refspec refs/tags/*.
// - GIT_DIR / GIT_WORK_TREE (segment env or export) and --git-dir/--work-tree make guarded git calls opaque.

const MENTION = new RegExp([
  String.raw`\bgh\b[\s\S]*\bpr\b[\s\S]*\bmerge\b`,
  String.raw`pulls/\S*/merge`,
  String.raw`mergePullRequest|enablePullRequestAutoMerge`,
  String.raw`\bgit\b[\s\S]*\b(push|commit|branch)\b`,
  String.raw`worktree\s+add`,
  String.raw`checkout\s+-[bB]`,
  String.raw`switch\s+(-[cC]\b|--create|--force-create)`,
].join('|'));

// Commands that run their arguments (or a script) as code: unreadable when they mention a guarded command.
const EXECS = new Set(['eval', 'xargs', 'sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'pwsh', 'powershell', 'cmd',
  'parallel', 'watch', 'ssh', 'su', 'find', 'source', '.', 'exec']);
const KEYWORDS = new Set(['{', '}', '!', 'if', 'then', 'else', 'elif', 'do', 'while', 'until', 'time']);

// ---------------------------------------------------------------- scanner

function scanAt(s, start, mode) {
  const items = [];
  const n = s.length;
  let i = start, depth = 0, broken = false, segBroken = false;
  let words = [], subs = [], word = null, segStart = start;
  let pendingRedir = false, pendingHeredoc = null;
  const heredocs = [];

  const markBroken = () => { broken = true; segBroken = true; };
  const w = () => {
    if (!word) {
      word = { text: '', dyn: false, udyn: false, quoted: false, brace: false, redir: pendingRedir, hd: pendingHeredoc };
      pendingRedir = false; pendingHeredoc = null;
    }
    return word;
  };
  const endWord = () => {
    if (!word) return;
    if (word.brace && word.text !== '{' && word.text !== '}') { word.dyn = true; word.udyn = true; }
    if (word.hd) heredocs.push({ delim: word.text, strip: word.hd.strip });
    else if (!word.redir) words.push(word);
    word = null;
  };
  const endSeg = (sep, at) => {
    endWord();
    const raw = s.slice(segStart, at).trim();
    if (words.length || raw) items.push({ kind: 'seg', words, subs, raw, sep, broken: segBroken });
    words = []; subs = []; segBroken = false;
  };
  const sub = (from) => {  // scan a $( … ) / <( … ) body starting at `from`; returns the index after ')'
    const r = scanAt(s, from, 'subst');
    if (r.broken) markBroken();
    subs.push(s.slice(from, Math.max(from, r.end - 1)));
    return r.end;
  };
  const consumeHeredocs = (k) => {
    for (const h of heredocs) {
      while (k < n) {
        const eol = s.indexOf('\n', k);
        const line = s.slice(k, eol < 0 ? n : eol);
        k = eol < 0 ? n : eol + 1;
        if ((h.strip ? line.replace(/^\t+/, '') : line) === h.delim) break;
      }
    }
    heredocs.length = 0;
    return k;
  };
  const dollar = (k, inDq) => {  // k at '$'; returns next index
    const ww = w();
    const c = s[k + 1];
    if (c === '(') {
      const end = sub(k + 2);
      ww.text += s.slice(k, end); ww.dyn = true; if (!inDq) ww.udyn = true;
      return end;
    }
    if (c === '{') {
      const j = s.indexOf('}', k + 2);
      const end = j < 0 ? n : j + 1;
      if (j < 0) markBroken();
      ww.text += s.slice(k, end); ww.dyn = true; if (!inDq) ww.udyn = true;
      return end;
    }
    if (c === "'" && !inDq) {  // $'…' ANSI-C quoting: literal
      let j = k + 2, t = '';
      while (j < n && s[j] !== "'") {
        if (s[j] === '\\' && j + 1 < n) { const e = s[j + 1]; t += e === 'n' ? '\n' : e === 't' ? '\t' : e; j += 2; } else t += s[j++];
      }
      if (j >= n) markBroken();
      ww.text += t; ww.quoted = true;
      return Math.min(n, j + 1);
    }
    const m = /^(?:[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/.exec(s.slice(k + 1));
    if (m) { ww.text += '$' + m[0]; ww.dyn = true; if (!inDq) ww.udyn = true; return k + 1 + m[0].length; }
    ww.text += '$';
    return k + 1;
  };
  const backtick = (k, inDq) => {
    let j = k + 1;
    while (j < n && s[j] !== '`') j += s[j] === '\\' ? 2 : 1;
    if (j >= n) { markBroken(); j = n; }
    subs.push(s.slice(k + 1, j).replace(/\\([`\\$])/g, '$1'));
    const ww = w();
    ww.text += s.slice(k, j + 1); ww.dyn = true; if (!inDq) ww.udyn = true;
    return Math.min(n, j + 1);
  };
  const dquote = (k) => {  // k just after the opening "
    const ww = w(); ww.quoted = true;
    while (k < n) {
      const c = s[k];
      if (c === '"') return k + 1;
      if (c === '\\') {
        const e = s[k + 1];
        if (e === '\n') { k += 2; continue; }
        if (e !== undefined && '$`"\\'.includes(e)) { ww.text += e; k += 2; continue; }
        ww.text += c; k++; continue;
      }
      if (c === '$') { k = dollar(k, true); continue; }
      if (c === '`') { k = backtick(k, true); continue; }
      ww.text += c; k++;
    }
    markBroken();
    return n;
  };

  while (i < n) {
    const c = s[i];
    if (c === '#' && !word) { while (i < n && s[i] !== '\n') i++; continue; }
    if (c === ' ' || c === '\t' || c === '\r') { endWord(); i++; continue; }
    if (c === '\n') { endSeg('\n', i); i = consumeHeredocs(i + 1); segStart = i; continue; }
    if (c === ';') { endSeg(';', i); i += s[i + 1] === ';' ? 2 : 1; segStart = i; continue; }
    if (c === '&') {
      if (s[i + 1] === '&') { endSeg('&&', i); i += 2; segStart = i; continue; }
      if (s[i + 1] === '>') { endWord(); i += s[i + 2] === '>' ? 3 : 2; pendingRedir = true; continue; }
      endSeg('&', i); i++; segStart = i; continue;
    }
    if (c === '|') {
      if (s[i + 1] === '|') { endSeg('||', i); i += 2; segStart = i; continue; }
      endSeg('|', i); i += s[i + 1] === '&' ? 2 : 1; segStart = i; continue;
    }
    if (c === '(' && !word) { endSeg(null, i); items.push({ kind: 'open' }); depth++; i++; segStart = i; continue; }
    if (c === ')') {
      if (mode === 'subst' && depth === 0) { endSeg(null, i); return { items, end: i + 1, broken }; }
      endSeg(null, i); if (depth > 0) depth--; items.push({ kind: 'close' }); i++; segStart = i; continue;
    }
    if (c === '<' || c === '>') {
      if (s[i + 1] === '(') {  // process substitution: it runs
        const end = sub(i + 2); const ww = w();
        ww.text += s.slice(i, end); ww.dyn = true; ww.udyn = true; i = end; continue;
      }
      if (word && /^\d+$/.test(word.text) && !word.quoted && !word.dyn) word = null; else endWord();
      if (c === '<' && s[i + 1] === '<' && s[i + 2] !== '<') {
        i += 2; let strip = false;
        if (s[i] === '-') { strip = true; i++; }
        while (s[i] === ' ' || s[i] === '\t') i++;
        pendingHeredoc = { strip }; continue;
      }
      // The operator: > >> < <> >& <& >| <<< (a following "&&" is a separator, not part of it).
      i++;
      while (i < n && (s[i] === '<' || s[i] === '>' || (s[i] === '&' && s[i + 1] !== '&') || (s[i] === '|' && s[i - 1] === '>'))) i++;
      pendingRedir = true; continue;
    }
    if (c === "'") {
      const j = s.indexOf("'", i + 1); const ww = w(); ww.quoted = true;
      if (j < 0) { ww.text += s.slice(i + 1); markBroken(); i = n; } else { ww.text += s.slice(i + 1, j); i = j + 1; }
      continue;
    }
    if (c === '"') { i = dquote(i + 1); continue; }
    if (c === '\\') {
      if (s[i + 1] === '\n') { i += 2; continue; }
      const ww = w(); ww.text += s[i + 1] ?? ''; ww.quoted = true; i += 2; continue;
    }
    if (c === '`') { i = backtick(i, false); continue; }
    if (c === '$') { i = dollar(i, false); continue; }
    const ww = w();
    if (c === '~' && ww.text === '') ww.dyn = true;               // tilde expansion
    if (c === '*' || c === '?' || c === '[') { ww.dyn = true; ww.udyn = true; }  // globbing
    if (c === '{') ww.brace = true;                               // brace expansion (unless a bare { group)
    ww.text += c; i++;
  }
  endSeg(null, n);
  if (mode === 'subst') markBroken();
  return { items, end: n, broken };
}

// ---------------------------------------------------------------- helpers

const isAbs = (p) => /^([A-Za-z]:[\\/]|[\\/])/.test(p);
function joinDir(base, p) {
  if (!base || isAbs(p)) return p;
  const parts = [];
  const lead = /^([A-Za-z]:)?\//.exec(base.replace(/\\/g, '/'));
  for (const x of `${base}/${p}`.replace(/\\/g, '/').slice(lead ? lead[0].length : 0).split('/')) {
    if (x === '' || x === '.') continue;
    if (x === '..' && parts.length && parts[parts.length - 1] !== '..') parts.pop();
    else if (x === '..' && lead) continue;
    else parts.push(x);
  }
  return (lead ? lead[0] : '') + (parts.join('/') || (lead ? '' : '.'));
}

class Opaque extends Error {}
const need = (word) => { if (!word || word.dyn) throw new Opaque(); return word.text; };

// ---------------------------------------------------------------- git

const COMMIT_SHORT_ARG = new Set(['m', 'F', 'C', 'c', 't']);
const COMMIT_LONG_ARG = new Set(['--message', '--file', '--reuse-message', '--reedit-message', '--fixup', '--squash',
  '--author', '--date', '--template', '--cleanup', '--trailer', '--pathspec-from-file']);
const PUSH_LONG_ARG = new Set(['--push-option', '--receive-pack', '--exec', '--repo']);
const BRANCH_CREATE_OK = /^(-f|--force|-t|--track(=.*)?|--no-track|-q|--quiet|--create-reflog|--recurse-submodules)$/;

function gitPush(args, dir) {
  let remote = null, force = false, del = false, endOpts = false, haveRemote = false, tags = false;
  const refspecs = [];
  for (let j = 0; j < args.length; j++) {
    const t = args[j].text;
    if (!endOpts && t === '--') { endOpts = true; continue; }
    if (!endOpts && t.startsWith('--')) {
      const eq = t.indexOf('='); const name = eq < 0 ? t : t.slice(0, eq);
      if (name === '--force' || name === '--force-with-lease' || name === '--mirror') force = true;
      if (name === '--delete' || name === '--prune') del = true;
      // --all/--branches push every branch, yet name none: refspecs [] would read as "the current branch".
      // (ruling R8) --mirror too: with force allowed it would otherwise read as "the current branch".
      if (name === '--all' || name === '--branches' || name === '--mirror') throw new Opaque();
      if (name === '--tags') tags = true;
      if (PUSH_LONG_ARG.has(name)) {
        const val = eq < 0 ? need(args[++j]) : (args[j].dyn ? need(null) : t.slice(eq + 1));
        if (name === '--repo' && !haveRemote) remote = val;
      }
      continue;
    }
    if (!endOpts && t.startsWith('-') && t.length > 1) {
      for (let k = 1; k < t.length; k++) {
        if (t[k] === 'f') force = true;
        if (t[k] === 'd') del = true;
        if (t[k] === 'o') { if (k === t.length - 1) j++; break; }
      }
      continue;
    }
    const v = need(args[j]);
    if (!haveRemote) { remote = v; haveRemote = true; } else refspecs.push(v);
  }
  if (tags) refspecs.push('refs/tags/*');  // a non-branch destination, so a guard never reads it as "current branch"
  if (refspecs.some((r) => r.startsWith('+'))) force = true;
  if (refspecs.some((r) => r.startsWith(':'))) del = true;
  return { dir, remote, refspecs, force, del };
}

function gitCommit(args, dir) {
  let all = false;
  for (let j = 0; j < args.length; j++) {
    const t = args[j].text;
    if (t === '--') break;
    if (t === '--all') { all = true; continue; }
    if (t.startsWith('--')) { if (!t.includes('=') && COMMIT_LONG_ARG.has(t)) j++; continue; }
    if (t.startsWith('-') && t.length > 1) {
      for (let k = 1; k < t.length; k++) {
        if (t[k] === 'a') all = true;
        else if (COMMIT_SHORT_ARG.has(t[k])) { if (k === t.length - 1) j++; break; }
      }
    }
  }
  return { dir, all };
}

// A short-option cluster (-qb, -bt/41-x, -fb x): the first char of `takes` ends the cluster; its value is the
// rest of the cluster or, if empty, the next word. Returns { value, next } or null when no such char.
function shortValue(args, j, takes) {
  const a = args[j]; const t = a.text;
  if (!t.startsWith('-') || t.startsWith('--') || t.length < 2) return null;
  for (let k = 1; k < t.length; k++) {
    if (takes.includes(t[k])) {
      if (k < t.length - 1) return { value: a.dyn ? need(null) : t.slice(k + 1), next: j };
      return { value: need(args[j + 1]), next: j + 1 };
    }
  }
  return null;
}

function gitWorktreeAdd(args, dir) {
  let name = null, detach = false;
  const pos = [];
  for (let j = 0; j < args.length; j++) {
    const t = args[j].text;
    if (t === '--reason') { j++; continue; }
    if (t === '--detach') { detach = true; continue; }
    if (t.startsWith('--')) continue;
    if (t.startsWith('-') && t.length > 1) {
      const sv = shortValue(args, j, 'bB');
      const cluster = sv ? t.slice(1, t.length - (sv.next === j ? sv.value.length : 0)) : t.slice(1);
      if (cluster.includes('d')) detach = true;
      if (sv) { name = sv.value; j = sv.next; }
      continue;
    }
    pos.push(args[j]);
  }
  if (name !== null) return { dir, name, via: 'worktree-add' };
  if (detach || pos.length === 0) return null;
  if (pos.length >= 2) return { dir, name: need(pos[1]), via: 'worktree-add' };
  const base = need(pos[0]).replace(/[\\/]+$/, '').split(/[\\/]/).pop();
  return { dir, name: base, via: 'worktree-add' };
}

// checkout -b x / -qb x / -bx / --orphan x;  switch -c x / -cx / --create=x
function gitNewBranchFlag(args, shorts, longs) {
  for (let j = 0; j < args.length; j++) {
    const t = args[j].text;
    if (t === '--') return null;
    if (longs.includes(t)) return need(args[j + 1]);
    const eq = t.indexOf('=');
    if (eq > 0 && longs.includes(t.slice(0, eq))) return args[j].dyn ? need(null) : t.slice(eq + 1);
    const sv = shortValue(args, j, shorts);
    if (sv) return sv.value;
  }
  return null;
}

// git branch <new> [start] creates <new>; -c/-C/-m/-M [<old>] <new> copies/renames into <new>.
function gitBranchCreate(args) {
  const pos = []; let copy = false;
  for (const a of args) {
    if (a.text.startsWith('-')) {
      if (/^(-[cCmM]|--copy|--move)$/.test(a.text)) { copy = true; continue; }
      if (!BRANCH_CREATE_OK.test(a.text)) return null;
      continue;
    }
    pos.push(a);
  }
  if (!pos.length) return null;
  if (copy) return pos.length > 2 ? need(null) : need(pos[pos.length - 1]);
  return need(pos[0]);
}

// Global options git takes before the subcommand.
const GIT_GLOBAL_VALUE = new Set(['-C', '-c', '--config-env', '--git-dir', '--work-tree', '--namespace',
  '--super-prefix', '--attr-source', '--list-cmds']);
const GIT_GLOBAL_FLAG = /^(-p|-P|--paginate|--no-pager|--bare|--no-replace-objects|--no-lazy-fetch|--no-optional-locks|--no-advice|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--exec-path(=.*)?|--html-path|--man-path|--info-path|--version|--help|-v|-h)$/;

// Verdicts: null = handled; 'opaque' = a guarded call that cannot be read exactly (always listed);
// 'maybe' = unreadable before we know what it is (listed only when the segment mentions a guarded verb).
function parseGit(args, st, env, out) {
  let i = 0, dir = st.dir, dirDyn = false;
  let gitDir = st.gitDir || env.GIT_DIR !== undefined || env.GIT_WORK_TREE !== undefined;
  while (i < args.length) {
    const t = args[i].text;
    if (args[i].dyn) return 'maybe';  // values of value-taking options are skipped below, never seen here
    if (!t.startsWith('-')) break;
    const eq = t.indexOf('='); const name = eq < 0 ? t : t.slice(0, eq);
    if (GIT_GLOBAL_VALUE.has(name)) {
      const v = eq < 0 ? args[i + 1] : { text: t.slice(eq + 1), dyn: args[i].dyn };
      if (name === '-C') { if (!v || v.dyn) dirDyn = true; else dir = joinDir(dir, v.text); }
      if (/^--(git-dir|work-tree|namespace)$/.test(name)) gitDir = true;
      i += eq < 0 ? 2 : 1; continue;
    }
    if (GIT_GLOBAL_FLAG.test(t)) { i++; continue; }
    return 'maybe';  // an unknown global option may take a value we would misread as the subcommand
  }
  const subcmd = args[i] ? args[i].text : '';
  const rest = args.slice(i + 1);
  const blocked = () => gitDir || dirDyn || st.cdOpaque;
  if (subcmd === 'push' || subcmd === 'commit' || (subcmd === 'worktree' && rest[0] && rest[0].text === 'add')) {
    if (blocked() || args.some((a) => a.udyn)) return 'opaque';
    if (subcmd === 'push') out.pushes.push(gitPush(rest, dir));
    else if (subcmd === 'commit') out.commits.push(gitCommit(rest, dir));
    else { const b = gitWorktreeAdd(rest.slice(1), dir); if (b) out.branches.push(b); }
    return null;
  }
  if (subcmd === 'checkout' || subcmd === 'switch' || subcmd === 'branch') {
    if (args.some((a) => a.udyn)) return 'opaque';  // word splitting could add -b
    const name = subcmd === 'checkout' ? gitNewBranchFlag(rest, 'bB', ['--orphan'])
      : subcmd === 'switch' ? gitNewBranchFlag(rest, 'cC', ['--create', '--force-create', '--orphan'])
        : gitBranchCreate(rest);
    if (name === null) return null;  // not a branch creation
    if (blocked()) return 'opaque';
    out.branches.push({ dir, name, via: subcmd });
    return null;
  }
  return null;
}

// ---------------------------------------------------------------- gh

const GH_MERGE_ARG = new Set(['-b', '--body', '-F', '--body-file', '-t', '--subject', '-A', '--author-email', '--match-head-commit']);
const GH_API_ARG = new Set(['-X', '--method', '-f', '--raw-field', '-F', '--field', '-H', '--header', '--input', '--hostname',
  '-q', '--jq', '-t', '--template', '--cache', '-p', '--preview']);

function parseGh(allArgs, st, env, out) {
  let repo = null, repoDyn = false;
  const envRepo = env.GH_REPO !== undefined ? env.GH_REPO : st.ghRepo;
  if (envRepo) { repo = envRepo.text; repoDyn = envRepo.dyn; }
  // -R/--repo may sit anywhere (gh --repo o/n pr merge 5, gh pr -R o/n merge 5): take it out first.
  const args = [];
  for (let j = 0; j < allArgs.length; j++) {
    const a = allArgs[j]; const t = a.text;
    if (t === '-R' || t === '--repo') { const v = allArgs[++j]; repo = v ? v.text : null; repoDyn = !v || v.dyn; continue; }
    if (t.startsWith('--repo=')) { repo = t.slice(7); repoDyn = a.dyn; continue; }
    if (t.startsWith('-R') && t.length > 2) { repo = t.slice(2); repoDyn = a.dyn; continue; }
    args.push(a);
  }
  const groupIdx = args.findIndex((a) => !a.text.startsWith('-'));
  if (groupIdx < 0) return null;
  const group = args[groupIdx];
  if (group.dyn) return 'maybe';
  let kind = null, startIdx = groupIdx + 1;
  if (group.text === 'api') kind = 'api';
  else if (group.text === 'pr') {
    const subIdx = args.findIndex((a, j) => j > groupIdx && !a.text.startsWith('-'));
    if (subIdx < 0) return null;
    if (args[subIdx].dyn) return 'maybe';
    if (args[subIdx].text !== 'merge') return null;
    kind = 'merge'; startIdx = subIdx + 1;
  }
  if (!kind) return null;
  const argSet = kind === 'api' ? GH_API_ARG : GH_MERGE_ARG;
  const pos = []; const flags = new Set(); let method = null, methodDyn = false;
  for (let j = startIdx; j < args.length; j++) {
    const a = args[j]; const t = a.text;
    if (kind === 'api' && (t === '-X' || t === '--method')) {
      const v = args[++j]; if (!v || v.dyn) methodDyn = true; else method = v.text.toUpperCase(); continue;
    }
    if (kind === 'api' && /^(-X|--method=)./.test(t)) {
      if (a.dyn) methodDyn = true; else method = t.replace(/^(-X|--method=)/, '').toUpperCase(); continue;
    }
    if (t.startsWith('-')) { flags.add(t.split('=')[0]); if (!t.includes('=') && argSet.has(t)) j++; continue; }
    pos.push(a);
  }
  if (kind === 'api') return ghApi(allArgs, pos, method, methodDyn, repo, repoDyn, st, out);
  if (allArgs.some((a) => a.udyn)) return 'opaque';
  if (flags.has('--disable-auto')) return null;
  if (st.cdOpaque || repoDyn) return 'opaque';
  let pr = null;
  if (pos.length) {
    const sel = need(pos[0]);
    const url = /^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)\/?$/.exec(sel);
    if (/^[1-9]\d*$/.test(sel)) pr = Number(sel);
    else if (url) { pr = Number(url[3]); repo = `${url[1]}/${url[2]}`; }
    else return 'opaque';  // a branch selector: Merge has no field that names it
  }
  if (repo === null && st.dir !== null) return 'opaque';  // repo would come from a cwd the hook does not have
  out.merges.push({ pr, repo, auto: flags.has('--auto'), via: 'gh-pr-merge' });
  return null;
}

function ghApi(args, pos, method, methodDyn, repo, repoDyn, st, out) {
  if (!pos.length) return null;
  if (pos[0].dyn) return 'maybe';
  const endpoint = pos[0].text;
  if (endpoint === 'graphql') {
    return args.some((a) => /mergePullRequest|enablePullRequestAutoMerge/.test(a.text)) ? 'opaque' : null;
  }
  const m = /^\/?repos\/([^/]+)\/([^/]+)\/pulls\/(\d+)\/merge\/?$/.exec(endpoint);
  if (!m) return null;
  if (methodDyn || args.some((a) => a.udyn)) return 'opaque';
  if (method !== 'PUT') return null;
  if (st.cdOpaque) return 'opaque';
  let r = `${m[1]}/${m[2]}`;
  if (m[1] === '{owner}' || m[2] === '{repo}') {
    if (repoDyn || (repo === null && st.dir !== null)) return 'opaque';
    r = repo;
  }
  out.merges.push({ pr: Number(m[3]), repo: r, auto: false, via: 'gh-api' });
  return null;
}

// ---------------------------------------------------------------- segments

function cdEffect(args, st) {
  const pos = args.filter((a) => !/^-[LPe@]+$/.test(a.text) && a.text !== '--');
  if (!pos.length || pos[0].dyn || pos[0].text === '-') return { ...st, cdOpaque: true };
  const t = pos[0].text;
  if (isAbs(t)) return { ...st, dir: t, cdOpaque: false };
  if (st.cdOpaque) return st;
  return { ...st, dir: joinDir(st.dir, t) };
}

// Returns the state after this segment (cd/export), or null when it changes nothing.
function segment(it, st, out) {
  const mentions = MENTION.test(it.raw);
  const opaque = () => { if (mentions) out.opaque.push(it.raw); return null; };
  if (it.broken) return opaque();
  const ws = it.words;
  const env = {};
  let k = 0;
  for (;;) {
    while (k < ws.length && !ws[k].quoted && KEYWORDS.has(ws[k].text)) k++;
    while (k < ws.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(ws[k].text)) {
      const eq = ws[k].text.indexOf('=');
      env[ws[k].text.slice(0, eq)] = { text: ws[k].text.slice(eq + 1), dyn: ws[k].dyn };
      k++;
    }
    const t = k < ws.length ? ws[k].text : '';
    if (ws[k] && ws[k].dyn) return opaque();
    if (t === 'command' || t === 'nohup' || t === 'builtin' || t === 'sudo') {
      k++;
      while (k < ws.length && ws[k].text.startsWith('-')) k += t === 'sudo' && /^-[ugpCDhrtUTR]$/.test(ws[k].text) ? 2 : 1;
      continue;
    }
    if (t === 'env') {
      k++;
      while (k < ws.length && ws[k].text.startsWith('-')) {
        // -C/--chdir moves the command elsewhere; -S re-splits a string into a command: unreadable.
        if (/^(-[a-zA-Z]*[CS]|--chdir|--split-string)/.test(ws[k].text)) return opaque();
        k += ws[k].text === '-u' ? 2 : 1;
      }
      continue;
    }
    if (t === 'timeout' || t === 'nice') {
      k++;
      while (k < ws.length && ws[k].text.startsWith('-')) k += /^(-s|-k|-n)$/.test(ws[k].text) ? 2 : 1;
      if (t === 'timeout') k++;  // the duration
      continue;
    }
    break;
  }
  if (k >= ws.length) return null;
  const name = ws[k].text.replace(/^.*[\\/]/, '').replace(/\.exe$/i, '');
  const args = ws.slice(k + 1);
  if (name === 'cd' || name === 'pushd') return cdEffect(args, st);
  if (name === 'popd') return { ...st, cdOpaque: true };
  if (name === 'export') {
    let next = null;
    for (const a of args) {
      if (a.text.startsWith('GH_REPO=')) next = { ...(next || st), ghRepo: { text: a.text.slice(8), dyn: a.dyn } };
      if (/^(GIT_DIR|GIT_WORK_TREE)(=|$)/.test(a.text)) next = { ...(next || st), gitDir: true };
    }
    return next;
  }
  if (name === 'unset' && args.some((a) => a.text === 'GH_REPO')) return { ...st, ghRepo: null };
  if (EXECS.has(name)) return opaque();
  let verdict = null;
  try {
    if (name === 'git') verdict = parseGit(args, st, env, out);
    else if (name === 'gh') verdict = parseGh(args, st, env, out);
  } catch (e) {
    if (!(e instanceof Opaque)) throw e;
    verdict = 'opaque';  // need() throws only inside an already-classified guarded call
  }
  if (verdict === 'opaque') out.opaque.push(it.raw);  // guarded and unreadable: listed even with no MENTION hit
  else if (verdict === 'maybe') opaque();
  return null;
}

function walk(src, out, initial) {
  const { items } = scanAt(src, 0, 'top');
  let st = initial;
  const stack = [];
  let prevSep = null;
  for (const it of items) {
    if (it.kind === 'open') { stack.push(st); st = { ...st }; prevSep = null; continue; }
    if (it.kind === 'close') { if (stack.length) st = stack.pop(); prevSep = null; continue; }
    for (const body of it.subs) walk(body, out, st);  // substitutions run, in the segment's cwd
    const next = segment(it, st, out);
    // Pipelines and background jobs run in subshells: their cd/export does not carry.
    if (next && it.sep !== '|' && it.sep !== '&' && prevSep !== '|') st = next;
    prevSep = it.sep;
  }
}

function parseCommand(cmd) {
  const out = { merges: [], pushes: [], branches: [], commits: [], opaque: [] };
  walk(String(cmd == null ? '' : cmd), out, { dir: null, cdOpaque: false, ghRepo: null, gitDir: false });
  return out;
}

module.exports = { parseCommand };
