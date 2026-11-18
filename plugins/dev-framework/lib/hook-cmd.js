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
// - R20: every opaque entry has a parallel `opaqueDirs` entry { dir, unknown }: `unknown` is true when the dir
//   the segment runs in cannot be read (a dynamic cd/pushd/-C, popd, cd -, a glob or brace in the dir,
//   GIT_DIR/--git-dir/--work-tree); `dir` is a literal -C/--chdir in the segment (joined to the cd dir), else the
//   cd dir, else null (= the hook cwd). With opts.home, a leading `~`, `~/`, `$HOME` or `${HOME}` reads as that
//   literal path (word splitting aside), so `cd ~/x` resolves like `cd /home/u/x`.
// - R25: a command word the parser does not know, followed later in the segment by `git`/`gh`, is unreadable
//   (stdbuf, winpty, flock, ...); `exec` is a transparent wrapper. A git subcommand that is not a git builtin,
//   and a gh command that is not a gh command, may be an alias: listed in `aliases` { tool, name, dir, unknown,
//   raw } for the hook to resolve (git config alias.<name> / gh alias list).
// - R22: a `gh api` endpoint loses a scheme+host prefix (and GHE's api/v3/) and a leading / before matching; an
//   endpoint naming pulls/<x>/merge that still does not match exactly is opaque for PUT or an unknown method.
// - R27: command words (git, gh, cd, export, env, the EXECS/DATA/KEYWORDS words, ...) are compared case-insensitively
//   by basename with a trailing .exe dropped (Git Bash on Windows runs GIT, Git.EXE, /usr/bin/git alike); so are git
//   subcommands and gh command groups (git PUSH can reach git-push.exe there). Folded on every platform.
// - R28: a code-running word (CODE_RUNNERS: EXECS plus interpreters and privilege/session wrappers) whose arguments
//   mention git or gh as a word is opaque with an UNKNOWN dir: the string can cd anywhere (bash -c 'cd ~/x && ...').
// - R30: a git call that carries inline config able to define an alias or redirect it (-c alias.* / include.* /
//   includeIf.* / remote.* / url.* / branch.* / push.*, any --config-env, a dynamic -c, or GIT_CONFIG_* / HOME /
//   XDG_CONFIG_HOME from the env prefix or an earlier export) is opaque (dir as known) unless its subcommand is a git
//   builtin that no guard reads; gh with GH_CONFIG_DIR (or HOME / XDG_CONFIG_HOME / APPDATA) and a non-command group
//   likewise. When the subcommand is not a builtin (an alias the hook cannot look up: its expansion may live only in
//   the injected config, git -c alias.x=... x), the opaqueDirs entry carries `any: true`: every guard reads it as
//   its own, whatever its text says.
// - R31: a relative `cd <dir>` / `pushd <dir>` (not ., .., ./x, ../x) while CDPATH is set (env prefix, export, or
//   opts.cdpath = the hook's own environment) makes the dir unknown.
// - R28c / R28d: see parseCommand: a feed (|, <, <( ), >( ), coproc) plus a runner, or a runner given a dynamic
//   argument, plus git/gh anywhere in the text, makes the whole command one row with an unknown dir.
// - R34: a write to repos/<o>/<n>/merges and GraphQL mergeBranch merge a branch with no PR: a `merges` entry with
//   pr null, via 'gh-api-branch-merge', repo null when it cannot be read.

const MENTION = new RegExp([
  String.raw`\bgh\b[\s\S]*\bpr\b[\s\S]*\bmerge\b`,
  String.raw`pulls/\S*/merge`,
  String.raw`mergePullRequest|enablePullRequestAutoMerge|mergeBranch`,
  String.raw`repos/\S*/merges\b`,  // R34: the branch-merge endpoint
  String.raw`\bgit\b[\s\S]*\b(push|commit|branch)\b`,
  String.raw`worktree\s+add`,
  String.raw`checkout\s+-[bB]`,
  String.raw`switch\s+(-[cC]\b|--create|--force-create)`,
].join('|'), 'i');  // R27: GIT push mentions push too

// Commands that run their arguments (or a script) as code: unreadable when they mention a guarded command.
const EXECS = new Set(['eval', 'xargs', 'sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'pwsh', 'powershell', 'cmd',
  'parallel', 'watch', 'ssh', 'su', 'find', 'source', '.']);
const KEYWORDS = new Set(['{', '}', '!', 'if', 'then', 'else', 'elif', 'do', 'while', 'until', 'time']);
// Commands whose arguments are data, never run: a `git push` among their words is text (echo git push).
const DATA = new Set(['echo', 'printf', 'grep', 'egrep', 'fgrep', 'rg', 'man', 'which', 'type', 'help', 'ls', 'cat',
  'test', '[', '[[', 'true', 'false', 'read', 'local', 'declare', 'typeset', 'readonly', 'alias', 'unalias', 'hash']);
// git builtins and the usual non-builtin main commands: never aliases (git ignores an alias that hides a command).
const GIT_COMMANDS = new Set(('add am annotate apply archive backfill bisect blame branch bugreport bundle cat-file ' +
  'check-attr check-ignore check-mailmap check-ref-format checkout checkout-index cherry cherry-pick clean clone ' +
  'column commit commit-graph commit-tree config count-objects credential describe diagnose diff diff-files ' +
  'diff-index diff-tree difftool fast-export fast-import fetch fetch-pack for-each-ref for-each-repo format-patch ' +
  'fsck gc grep hash-object help hook index-pack init interpret-trailers log ls-files ls-remote ls-tree maintenance ' +
  'merge merge-base merge-file merge-tree mktag mktree multi-pack-index mv name-rev notes pack-objects pack-refs ' +
  'patch-id prune pull push range-diff read-tree rebase reflog refs remote repack replace replay rerere reset ' +
  'restore rev-list rev-parse revert rm shortlog show show-branch show-ref sparse-checkout stage stash status ' +
  'stripspace submodule switch symbolic-ref tag update-index update-ref var verify-commit verify-tag version ' +
  'whatchanged worktree write-tree lfs gui citool mergetool filter-branch request-pull subtree send-email svn p4 ' +
  'instaweb gitk').split(' '));
const GH_COMMANDS = new Set(('auth browse codespace cs gist issue org pr project release repo cache run workflow co ' +
  'agent-task alias api attestation completion config copilot extension ext extensions gpg-key label licenses ' +
  'preview ruleset rs search secret ssh-key status variable help version').split(' '));
const base = (t) => t.replace(/^.*[\\/]/, '').replace(/\.exe$/i, '');
// R27: how a command word is compared: basename, no .exe, lower case.
const cmdName = (t) => base(t).toLowerCase();
// R27a: shell builtins and keywords are dispatched by bash case-sensitively (CD is "command not found"), so they match
// only exactly as written; external programs (git, gh, python, env, stdbuf, ...) fold as above.
const SHELL_BUILTINS = new Set(['cd', 'pushd', 'popd', 'export', 'unset', 'command', 'builtin', 'exec', 'eval', 'source',
  '.', 'alias', 'declare', 'local', 'readonly', 'typeset']);
const NOT_A_COMMAND = '\u0000';  // prefix of a mis-cased builtin: matches no set, so it is an unknown word
function wordName(text) {
  if (SHELL_BUILTINS.has(text) || KEYWORDS.has(text)) return text;
  const n = cmdName(text);
  return SHELL_BUILTINS.has(n) || KEYWORDS.has(n) ? NOT_A_COMMAND + text : n;
}
// R28: words that run code given as arguments or a script; EXECS plus these.
const CODE_RUNNERS = new Set([...EXECS, 'script', 'python', 'python3', 'py', 'perl', 'ruby', 'node', 'deno', 'bun', 'php',
  'lua', 'osascript', 'busybox', 'nohup', 'setsid', 'sudo', 'doas', 'runuser', 'chroot', 'unbuffer', 'expect', 'tclsh',
  'wsl', 'start']);
const isCodeRunner = (name) => CODE_RUNNERS.has(name) || /^(python|pypy)[0-9.]*$/.test(name);
// R28e: a shell or interpreter whose `-c`/`-e`/`--eval`/`-Command` argument is run as code (bash -c '…', python -c
// '…', perl -e '…', pwsh -Command '…'). eval/source/. (handled apart) run any argument as code.
const SHELL_RUNNERS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'pwsh', 'powershell', 'python', 'python3',
  'py', 'perl', 'ruby', 'node', 'deno', 'bun', 'php', 'lua', 'osascript', 'tclsh', 'expect']);
const isShellRunner = (name) => SHELL_RUNNERS.has(name) || /^(python|pypy)[0-9.]*$/.test(name);
const CODE_FLAG = /^(-c|-e|--eval|--command|-Command)$/;
// R28e: a word that carries code the shell will expand — an expansion ($x, ${x}, `…`, $(…)) in it, OR a literal
// string holding a `$` that an inner `eval`/`-c` shell expands (NC4: bash -c 'eval "$X"'). A plain glob (*.json) has
// no `$`/backtick, so it never counts; nor does a bare data word.
const carriesCode = (w) => /[$`]/.test(w.text);
// R28e clause (b): a command word that is a single parameter expansion ($x, "$x", ${x}, "$@", $*) — word-splitting
// it can produce any command. A path that merely contains an expansion ("$REPO/scripts/test.sh") is the script-file
// residual and does not count.
const isParamExpWord = (w) => w.dyn && /^\$(\{[A-Za-z_@*][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*|[@*])$/.test(w.text);
// R28e clause (a): does the runner `name`, with the words `rest` after it, get code through an expansion or a
// $-bearing literal in its code position?
function runnerHasDynCode(name, rest) {
  if (name === 'eval' || name === 'source' || name === '.') return rest.some(carriesCode);
  if (!isShellRunner(name)) return false;  // sudo/ssh/find/start/nohup take no inline-code flag we read
  for (let j = 0; j < rest.length; j++) {
    if (CODE_FLAG.test(rest[j].text)) return !!rest[j + 1] && carriesCode(rest[j + 1]);
  }
  return false;
}
// R28: git or gh named as a word (git.exe too; .git, github, git-lfs and a path component like tools/git/x are not it).
const GIT_WORD = /(^|[^\w.-])(git|gh)(\.exe)?(?![\w/-])/i;
// R28a (I3): `git [global options] <sub>` / `gh [-R x] <group>` written inside an interpreter string.
const GIT_IN_TEXT = /(?:^|[^\w.\/-])git(?:\.exe)?((?:\s+-[cC]\s+\S+|\s+--?[A-Za-z][\w-]*(?:=\S*)?)*)\s+([A-Za-z][\w-]*)/gi;
const GH_IN_TEXT = /(?:^|[^\w.\/-])gh(?:\.exe)?((?:\s+(?:-R|--repo)\s+\S+)*)\s+([A-Za-z][\w-]*)/gi;
// R30: environment that changes which git config (and so which aliases) a call reads.
const GIT_CONFIG_ENV = /^(GIT_CONFIG|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_\w*|GIT_CONFIG_VALUE_\w*|GIT_CONFIG_PARAMETERS|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|HOME|XDG_CONFIG_HOME)$/;
const GH_CONFIG_ENV = /^(GH_CONFIG_DIR|HOME|XDG_CONFIG_HOME|APPDATA)$/;
// R30: -c keys that can define an alias, pull in more config, or redirect where a guarded call goes.
const GIT_CONFIG_KEY_RISK = /^(alias|include|includeif|remote|url|branch|push)\./i;
// git subcommands some guard reads; a call to one of them under injected config is never read exactly.
const GIT_GUARDED = new Set(['push', 'commit', 'worktree', 'checkout', 'switch', 'branch']);

// ---------------------------------------------------------------- scanner

function scanAt(s, start, mode, opts = {}) {
  const home = typeof opts.home === 'string' && opts.home !== '' ? opts.home : null;
  const items = [];
  const n = s.length;
  let i = start, depth = 0, broken = false, segBroken = false, segStdin = false, fed = false;
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
    if (words.length || raw) items.push({ kind: 'seg', words, subs, raw, sep, broken: segBroken, stdin: segStdin });
    words = []; subs = []; segBroken = false; segStdin = false;
  };
  const sub = (from) => {  // scan a $( … ) / <( … ) body starting at `from`; returns the index after ')'
    const r = scanAt(s, from, 'subst', opts);
    if (r.broken) markBroken();
    // (a body's own pipes / < reach out._fed when walk() re-scans the body, so r.fed is not needed here)
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
    // $HOME / ${HOME} with a known home is that literal path (unquoted only when it cannot split).
    const homeOk = home && (inDq || !/\s/.test(home));
    if (c === '{') {
      const j = s.indexOf('}', k + 2);
      const end = j < 0 ? n : j + 1;
      if (j < 0) markBroken();
      if (homeOk && s.slice(k + 2, j) === 'HOME') { ww.text += home; return end; }
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
    if (m && m[0] === 'HOME' && homeOk) { ww.text += home; return k + 5; }
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
      fed = true;  // R28c: a pipe anywhere
      endSeg('|', i); i += s[i + 1] === '&' ? 2 : 1; segStart = i; continue;
    }
    if (c === '(' && !word) { endSeg(null, i); items.push({ kind: 'open' }); depth++; i++; segStart = i; continue; }
    if (c === ')') {
      if (mode === 'subst' && depth === 0) { endSeg(null, i); return { items, end: i + 1, broken, fed }; }
      endSeg(null, i); if (depth > 0) depth--; items.push({ kind: 'close' }); i++; segStart = i; continue;
    }
    if (c === '<' || c === '>') {
      if (s[i + 1] === '(') {  // process substitution: it runs
        fed = true;  // R28c / R28d: <( ... ) feeds a command; so does >( ... ) (its body reads the outer output)
        const end = sub(i + 2); const ww = w();
        ww.text += s.slice(i, end); ww.dyn = true; ww.udyn = true; i = end; continue;
      }
      if (word && /^\d+$/.test(word.text) && !word.quoted && !word.dyn) word = null; else endWord();
      if (c === '<') { segStdin = true; fed = true; }  // R28a: a heredoc, here-string or `< file` feeds the command's stdin
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
    if (c === '~' && ww.text === '' && !ww.quoted) {              // tilde expansion
      const nx = s[i + 1];
      if (home && (nx === undefined || /[/\s;&|()<>]/.test(nx))) { ww.text += home; i++; continue; }
      ww.dyn = true;                                              // ~user, or no home given
    }
    if (c === '*' || c === '?' || c === '[') { ww.dyn = true; ww.udyn = true; }  // globbing
    if (c === '{') ww.brace = true;                               // brace expansion (unless a bare { group)
    ww.text += c; i++;
  }
  endSeg(null, n);
  if (mode === 'subst') markBroken();
  return { items, end: n, broken, fed };
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
function parseGit(args, st, env, out, raw) {
  let i = 0, dir = st.dir, dirDyn = false;
  let gitDir = st.gitDir || env.GIT_DIR !== undefined || env.GIT_WORK_TREE !== undefined;
  // R30: config from the environment (prefix or an earlier export) can define aliases or redirect the call
  let injected = !!st.gitConfig || Object.keys(env).some((k) => GIT_CONFIG_ENV.test(k));
  while (i < args.length) {
    const t = args[i].text;
    if (args[i].dyn) return 'maybe';  // values of value-taking options are skipped below, never seen here
    if (!t.startsWith('-')) break;
    const eq = t.indexOf('='); const name = eq < 0 ? t : t.slice(0, eq);
    if (GIT_GLOBAL_VALUE.has(name)) {
      const v = eq < 0 ? args[i + 1] : { text: t.slice(eq + 1), dyn: args[i].dyn };
      if (name === '-C') { if (!v || v.dyn) dirDyn = true; else dir = joinDir(dir, v.text); }
      if (/^--(git-dir|work-tree|namespace)$/.test(name)) gitDir = true;
      if (name === '--config-env') injected = true;
      if (name === '-c' && (!v || v.dyn || GIT_CONFIG_KEY_RISK.test(v.text))) injected = true;
      i += eq < 0 ? 2 : 1; continue;
    }
    if (GIT_GLOBAL_FLAG.test(t)) { i++; continue; }
    return 'maybe';  // an unknown global option may take a value we would misread as the subcommand
  }
  const subcmd = args[i] ? args[i].text.toLowerCase() : '';  // R27: git PUSH can reach git-push.exe on Windows
  const rest = args.slice(i + 1);
  const blocked = () => gitDir || dirDyn || st.cdOpaque;
  // R30: under injected config, an alias candidate or a guarded verb cannot be read exactly
  if (injected && subcmd !== '' && !GIT_COMMANDS.has(subcmd)) return 'opaque-any';  // an alias the hook cannot read
  if (injected && GIT_GUARDED.has(subcmd)) return 'opaque';
  if (args[i] && !args[i].dyn && subcmd !== '' && !GIT_COMMANDS.has(subcmd)) {
    // R25: may be an alias (alias.<name> in the repo's or the global git config); the hook resolves it.
    out.aliases.push({ tool: 'git', name: args[i].text, dir, unknown: !!blocked(), raw });
    return null;
  }
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

function parseGh(allArgs, st, env, out, raw) {
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
  const gname = group.text.toLowerCase();  // R27
  if (!GH_COMMANDS.has(gname)) {
    // R30: aliases from another gh config dir cannot be looked up by the hook
    if (st.ghConfig || Object.keys(env).some((k) => GH_CONFIG_ENV.test(k))) return 'opaque-any';
    // R25: may be a gh alias (gh alias set m 'pr merge'); the hook resolves it with `gh alias list`.
    out.aliases.push({ tool: 'gh', name: group.text, dir: st.dir, unknown: !!st.cdOpaque, raw });
    return null;
  }
  let kind = null, startIdx = groupIdx + 1;
  if (gname === 'api') kind = 'api';
  else if (gname === 'pr') {
    const subIdx = args.findIndex((a, j) => j > groupIdx && !a.text.startsWith('-'));
    if (subIdx < 0) return null;
    if (args[subIdx].dyn) return 'maybe';
    if (args[subIdx].text.toLowerCase() !== 'merge') return null;
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
  if (kind === 'api') return ghApi(allArgs, pos, flags, method, methodDyn, repo, repoDyn, st, out);
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

function ghApi(args, pos, flags, method, methodDyn, repo, repoDyn, st, out) {
  if (!pos.length) return null;
  if (pos[0].dyn) return 'maybe';
  // R22: gh takes a full URL as the endpoint too; drop scheme+host (any host), GHE's api/v3/, and a leading /.
  const endpoint = pos[0].text.replace(/^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^/]*/, '').replace(/^\/+/, '')
    .replace(/^api\/v3\//, '');
  const branchMerge = (r) => out.merges.push({ pr: null, repo: r, auto: false, via: 'gh-api-branch-merge' });
  if (endpoint === 'graphql' || endpoint === 'api/graphql') {
    // R34: mergeBranch merges one branch into another with no PR; its repo is a node id the hook cannot read
    if (args.some((a) => /mergeBranch/.test(a.text))) branchMerge(null);
    return args.some((a) => /mergePullRequest|enablePullRequestAutoMerge/.test(a.text)) ? 'opaque' : null;
  }
  // R34: a write to repos/<o>/<n>/merges merges a branch with no PR. gh api sends GET unless -X names another method
  // or a field / --input is given (then POST); an unknown method or an unquoted dynamic word may be a write.
  const path = endpoint.replace(/[?#].*$/, '');
  if (/(^|\/)merges(\/|$)/i.test(path)) {
    // R34a: a field (-f/-F/--raw-field/--field/--input) makes `gh api` POST. Split a combined short cluster first, so
    // `-if` (that is -i -f) counts as a field just like `-f`.
    const fields = [...flags].some((f) => /^--(raw-field|field|input)$/.test(f.split('=')[0])
      || (/^-[A-Za-z]/.test(f) && !f.startsWith('--') && /[fF]/.test(f.slice(1))));
    const write = methodDyn || args.some((a) => a.udyn) || (method !== null ? !/^(GET|HEAD)$/.test(method) : fields);
    if (!write) return null;
    const bm = /^repos\/([^/]+)\/([^/]+)\/merges\/?$/i.exec(path);
    if (!bm) return 'opaque';  // names the merges endpoint yet does not read exactly
    branchMerge(bm[1] === '{owner}' || bm[2] === '{repo}' ? (repoDyn ? null : repo) : `${bm[1]}/${bm[2]}`);
    return null;
  }
  const m = /^repos\/([^/]+)\/([^/]+)\/pulls\/(\d+)\/merge\/?$/.exec(endpoint);
  if (!m) {
    // names a merge endpoint yet does not read exactly (extra path, a fragment): a PUT or an unknown method blocks
    if (/pulls\/[^/]*\/merge/.test(endpoint) && (methodDyn || method === 'PUT')) return 'opaque';
    return null;
  }
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

function cdEffect(args, st, env) {
  const pos = args.filter((a) => !/^-[LPe@]+$/.test(a.text) && a.text !== '--');
  if (!pos.length || pos[0].dyn || pos[0].text === '-') return { ...st, cdOpaque: true };
  const t = pos[0].text;
  if (isAbs(t)) return { ...st, dir: t, cdOpaque: false };
  // R31: with CDPATH set, a relative dir (not ., .., ./x, ../x) may resolve under any CDPATH entry
  const cdpath = env.CDPATH !== undefined ? env.CDPATH.dyn || env.CDPATH.text !== '' : st.cdpath;
  if (cdpath && !/^\.\.?([\\/]|$)/.test(t)) return { ...st, cdOpaque: true };
  if (st.cdOpaque) return st;
  return { ...st, dir: joinDir(st.dir, t) };
}

// R20: where an unreadable segment runs. `unknown` when its dir cannot be read; else `dir` is a literal -C /
// --chdir found among its words (joined to the cd dir), else the cd dir (null = the hook cwd).
function segDir(ws, st, env) {
  let dir = st.dir;
  let unknown = !!st.cdOpaque || !!st.gitDir || env.GIT_DIR !== undefined || env.GIT_WORK_TREE !== undefined;
  for (let j = 0; j < ws.length; j++) {
    const t = ws[j].text;
    if (t === '-C' || t === '--chdir') {
      const v = ws[j + 1];
      if (!v || v.dyn) unknown = true; else dir = joinDir(st.dir, v.text);
      j++; continue;
    }
    if (t.startsWith('--chdir=')) { if (ws[j].dyn) unknown = true; else dir = joinDir(st.dir, t.slice(8)); continue; }
    if (/^--(git-dir|work-tree)(=|$)/.test(t)) unknown = true;
  }
  return { dir, unknown };
}

// R28a (I3): every `git <sub>` / `gh <group>` written inside an interpreter string whose sub/group is not a command is
// an alias candidate with an unknown dir (the hook resolves it from its cwd: repo + global config / gh alias list).
function aliasesInText(text, raw, out) {
  const seen = new Set(out.aliases.map((a) => `${a.tool}:${a.name}:${a.raw}`));
  const add = (tool, name) => {
    const key = `${tool}:${name}:${raw}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.aliases.push({ tool, name, dir: null, unknown: true, raw });
  };
  for (const m of String(text).matchAll(GIT_IN_TEXT)) if (!GIT_COMMANDS.has(m[2].toLowerCase())) add('git', m[2]);
  for (const m of String(text).matchAll(GH_IN_TEXT)) if (!GH_COMMANDS.has(m[2].toLowerCase())) add('gh', m[2]);
}

// Returns the state after this segment (cd/export), or null when it changes nothing. ctx: { text, piped } = the whole
// command text this segment belongs to, and whether a pipe feeds this segment's stdin.
function segment(it, st, out, ctx) {
  const mentions = MENTION.test(it.raw);
  const env = {};
  // unknown: the dir cannot be read (R28); any: the call may be anything, so every guard reads it as its own (R30);
  // raw: the text the guards match their verb against (default: the segment).
  const list = (unknown, any, raw) => {
    const d = segDir(it.words, st, env);
    out.opaque.push(raw === undefined ? it.raw : raw);
    out.opaqueDirs.push({ ...d, ...(unknown ? { unknown: true } : {}), ...(any ? { any: true } : {}) });
    return null;
  };
  // R28 / R28a: code that may run git/gh from any dir; its git/gh aliases are resolved too (I3)
  const listCode = (raw, text) => { aliasesInText(text, raw, out); return list(true, false, raw); };
  const opaque = () => (mentions ? list() : null);
  const ws = it.words;
  // R28d: `coproc` starts a command that reads what is later written to ${NAME[1]}: a feed and a runner at once
  let k0 = 0;
  while (k0 < ws.length && !ws[k0].quoted && KEYWORDS.has(ws[k0].text)) k0++;
  if (ws[k0] && !ws[k0].quoted && ws[k0].text === 'coproc') { out._fed = true; out._runner = true; }
  if (it.broken) return opaque();
  let k = 0, wrapped = false;
  for (;;) {
    while (k < ws.length && !ws[k].quoted && KEYWORDS.has(ws[k].text)) k++;  // R27a: keywords as written
    while (k < ws.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(ws[k].text)) {
      const eq = ws[k].text.indexOf('=');
      env[ws[k].text.slice(0, eq)] = { text: ws[k].text.slice(eq + 1), dyn: ws[k].dyn };
      // NC4: a prefix assignment whose value is itself a git command (cd ~/x && git push) carries the git text to a
      // runner in the same command through the environment, bypassing the dynamic-code clauses.
      if (MENTION.test(ws[k].text.slice(eq + 1))) out._assignGit = true;
      k++;
    }
    const t = k < ws.length ? wordName(ws[k].text) : '';
    if (ws[k] && ws[k].dyn) {
      const rest = ws.slice(k + 1);
      // R28e clause (b): a command word that is a single parameter expansion ($x, "$x") may word-split into any
      // command (set -- git push ...; "$@"); a path with an expansion ("$REPO/scripts/x") is the script-file residual.
      if (isParamExpWord(ws[k])) out._dynRunner = true;
      // R28a (I2): a dynamic command word may be any code runner ("$SHELL" -c '...'): mentioning git/gh, dir unknown
      if (rest.some((w) => GIT_WORD.test(w.text))) return listCode(it.raw, rest.map((w) => w.text).join(' '));
      out._runner = true;  // R28c: a dynamic command word may be a code runner fed on stdin (whole-command pass)
      // R12: a dynamic command word (g=gh; $g pr merge) hides the program: listed whenever a later word is a
      // verb we guard, even with no MENTION hit.
      if (rest.some((w) => /^(merge|push|commit|checkout|switch|worktree|branch)$/i.test(w.text))) return list();
      return opaque();
    }
    if (t === 'command' || t === 'builtin') {  // run the builtin itself: its state change applies
      k++;
      while (k < ws.length && ws[k].text.startsWith('-')) k++;
      continue;
    }
    if (t === 'exec') {  // exec [-cl] [-a name] cmd: runs cmd in place of the shell, arguments as given
      k++; wrapped = true;
      while (k < ws.length && ws[k].text.startsWith('-')) k += ws[k].text === '-a' ? 2 : 1;
      continue;
    }
    if (t === 'env') {
      k++; wrapped = true;
      while (k < ws.length && ws[k].text.startsWith('-')) {
        // -C/--chdir moves the command elsewhere; -S re-splits a string into a command: unreadable.
        if (/^(-[a-zA-Z]*[CS]|--chdir|--split-string)/.test(ws[k].text)) return opaque();
        k += ws[k].text === '-u' ? 2 : 1;
      }
      continue;
    }
    if (t === 'timeout' || t === 'nice') {
      k++; wrapped = true;
      while (k < ws.length && ws[k].text.startsWith('-')) k += /^(-s|-k|-n)$/.test(ws[k].text) ? 2 : 1;
      if (t === 'timeout') k++;  // the duration
      continue;
    }
    break;
  }
  if (k >= ws.length) {
    // M1: a bare CDPATH=... is a shell variable, and cd reads it exported or not
    if (env.CDPATH !== undefined) return { ...st, cdpath: env.CDPATH.dyn || env.CDPATH.text !== '' };
    return null;
  }
  const name = wordName(ws[k].text);
  const args = ws.slice(k + 1);
  // R27a: cd/pushd/popd/export/unset change the shell's state only as the segment's own builtin. Behind a wrapper
  // (env, timeout, nice, exec) the program is not found and nothing changes; a cd there still makes the dir unclear.
  if (name === 'cd' || name === 'pushd') return wrapped ? { ...st, cdOpaque: true } : cdEffect(args, st, env);
  if (name === 'popd') return { ...st, cdOpaque: true };
  if (name === 'export') {
    if (wrapped) return null;
    let next = null;
    for (const a of args) {
      const eq = a.text.indexOf('='); const v = eq < 0 ? null : a.text.slice(eq + 1);
      const key = eq < 0 ? a.text : a.text.slice(0, eq);
      if (key === 'GH_REPO' && v !== null) next = { ...(next || st), ghRepo: { text: v, dyn: a.dyn } };
      if (key === 'GIT_DIR' || key === 'GIT_WORK_TREE') next = { ...(next || st), gitDir: true };
      if (GIT_CONFIG_ENV.test(key)) next = { ...(next || st), gitConfig: true };
      if (GH_CONFIG_ENV.test(key)) next = { ...(next || st), ghConfig: true };
      if (key === 'CDPATH' && v !== null) next = { ...(next || st), cdpath: a.dyn || v !== '' };
      // NC4: an exported git command carries into a runner through the environment (export X='...git push...')
      if (v !== null && MENTION.test(v)) out._assignGit = true;
    }
    return next;
  }
  if (name === 'unset') {
    if (wrapped) return null;
    let next = null;
    if (args.some((a) => a.text === 'GH_REPO')) next = { ...st, ghRepo: null };
    if (args.some((a) => a.text === 'CDPATH')) next = { ...(next || st), cdpath: false };
    return next;
  }
  if (name !== 'git' && name !== 'gh' && !DATA.has(name)) {
    const all = ws.slice(k);
    // R28a: ANY word may be the code runner (stdbuf -oL bash -c '...', winpty python -c '...')
    const ri = all.findIndex((w) => !w.dyn && isCodeRunner(wordName(w.text)));
    if (ri >= 0) {
      out._runner = true;  // R28c: seen at any depth; the whole-command pass in parseCommand decides
      // R28e clause (a): only a code-position argument of the runner counts (eval/source/. any arg; a shell's -c arg),
      // and only when it carries an expansion or a $-bearing literal — not a glob or a plain script-file argument.
      if (runnerHasDynCode(wordName(all[ri].text), all.slice(ri + 1))) out._dynRunner = true;
      if (args.some((a) => GIT_WORD.test(a.text))) return listCode(it.raw, args.map((a) => a.text).join(' '));
      if (ri === 0) return EXECS.has(name) ? opaque() : null;
    }
    // R27a: a wrapper whose target is cd/pushd/popd (stdbuf cd x, COMMAND cd x): the shell's dir is not changed,
    // but what the author meant is unclear: later dirs are unknown.
    if (args.some((a) => !a.dyn && /^(cd|pushd|popd)$/.test(a.text))) return { ...st, cdOpaque: true };
    // R25: an unknown command word (stdbuf -oL, winpty, flock f, ...) followed by git/gh may run it: unreadable.
    if (args.some((a) => !a.dyn && /^(git|gh)$/.test(cmdName(a.text)))) return opaque();
    return null;
  }
  if (name !== 'git' && name !== 'gh') return null;  // DATA
  let verdict = null;
  try {
    if (name === 'git') verdict = parseGit(args, st, env, out, it.raw);
    else verdict = parseGh(args, st, env, out, it.raw);
  } catch (e) {
    if (!(e instanceof Opaque)) throw e;
    verdict = 'opaque';  // need() throws only inside an already-classified guarded call
  }
  if (verdict === 'opaque') list();  // guarded and unreadable: listed even with no MENTION hit
  else if (verdict === 'opaque-any') list(false, true);
  else if (verdict === 'maybe') opaque();
  return null;
}

function walk(src, out, initial, opts) {
  const { items, fed } = scanAt(src, 0, 'top', opts);
  if (fed) out._fed = true;  // R28c: a pipe or < redirection anywhere (substitution bodies included)
  let st = initial;
  const stack = [];
  let prevSep = null;
  for (const it of items) {
    if (it.kind === 'open') { stack.push(st); st = { ...st }; prevSep = null; continue; }
    if (it.kind === 'close') { if (stack.length) st = stack.pop(); prevSep = null; continue; }
    for (const body of it.subs) walk(body, out, st, opts);  // substitutions run, in the segment's cwd
    const next = segment(it, st, out, { text: src, piped: prevSep === '|' });
    // Pipelines and background jobs run in subshells: their cd/export does not carry.
    if (next && it.sep !== '|' && it.sep !== '&' && prevSep !== '|') st = next;
    prevSep = it.sep;
  }
}

// parseCommand(cmd, { home, cdpath }): home (optional) is the literal path `~` and $HOME stand for; cdpath (optional)
// is true when the hook's own environment has a non-empty CDPATH (R31).
function parseCommand(cmd, opts = {}) {
  const out = { merges: [], pushes: [], branches: [], commits: [], opaque: [], opaqueDirs: [], aliases: [] };
  const o = opts || {};
  const text = String(cmd == null ? '' : cmd);
  walk(text, out,
    { dir: null, cdOpaque: false, ghRepo: null, gitDir: false, gitConfig: false, ghConfig: false, cdpath: !!o.cdpath }, o);
  // R28c (NC1, NC2): a pipe or a < redirection (heredoc, here-string, file, process substitution) anywhere, a code
  // runner / eval / source / . / dynamic command word at any depth, and git/gh in the text: some runner may read its
  // code from that stdin, inside a subshell, loop or if as well, so the whole command is one row with an unknown dir.
  // No nesting or argument tracking (rulings R28b, R28c). R28d/R28e: >( ... ) and coproc feed too (coproc also runs);
  // and with no feed, a runner whose code-position argument carries an expansion or a $-bearing literal (eval "$x",
  // bash -c 'eval "$X"'), a command word that is a single parameter expansion ($x), or (NC4) any runner together with
  // an assignment whose value is itself a git command, make the same one whole-command row.
  const fedRunner = ((out._fed && out._runner) || out._dynRunner || (out._runner && out._assignGit))
    && GIT_WORD.test(text);
  delete out._fed; delete out._runner; delete out._dynRunner; delete out._assignGit;
  if (fedRunner) {
    const at = out.opaque.indexOf(text);  // a one-segment command may already be a row with this text: make it unknown
    if (at >= 0) out.opaqueDirs[at] = { ...out.opaqueDirs[at], unknown: true };
    else { out.opaque.push(text); out.opaqueDirs.push({ dir: null, unknown: true }); }
    aliasesInText(text, text, out);
  }
  return out;
}

// R29: the command names an alias step may resolve to (the hook walks alias chains with these).
module.exports = { parseCommand, GIT_COMMANDS: [...GIT_COMMANDS], GH_COMMANDS: [...GH_COMMANDS] };
