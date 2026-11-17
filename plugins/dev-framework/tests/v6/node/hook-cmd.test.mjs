import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { parseCommand: parseFull } = require('../../../lib/hook-cmd.js');
const here = dirname(fileURLToPath(import.meta.url));
// The older rows compare the five original fields; the R20/R25 fields (opaqueDirs, aliases) have their own tests
// below, and a length check here keeps opaqueDirs parallel to opaque for every row.
const parseCommand = (c, o) => {
  const { opaqueDirs, aliases, ...rest } = parseFull(c, o);
  assert.equal(opaqueDirs.length, rest.opaque.length, `opaqueDirs parallel to opaque: ${c}`);
  return rest;
};

const EMPTY = { merges: [], pushes: [], branches: [], commits: [], opaque: [] };
const r = (over) => ({ ...EMPTY, ...over });
const merge = (o) => ({ pr: null, repo: null, auto: false, via: 'gh-pr-merge', ...o });
const push = (o) => ({ dir: null, remote: null, refspecs: [], force: false, del: false, ...o });
const branch = (o) => ({ dir: null, ...o });
const commit = (o) => ({ dir: null, all: false, ...o });

// --- brief rows ---
test('gh pr merge with --repo', () => {
  assert.deepEqual(parseCommand('gh pr merge 12 --repo acme/api --squash'),
    r({ merges: [merge({ pr: 12, repo: 'acme/api' })] }));
});
test('cd then gh pr merge -R --auto', () => {
  assert.deepEqual(parseCommand('cd x && gh pr merge 12 -R acme/api --auto'),
    r({ merges: [merge({ pr: 12, repo: 'acme/api', auto: true })] }));
});
test('GH_REPO env assignment', () => {
  assert.deepEqual(parseCommand('GH_REPO=acme/api gh pr merge 7'),
    r({ merges: [merge({ pr: 7, repo: 'acme/api' })] }));
});
test('gh api PUT pulls/N/merge', () => {
  assert.deepEqual(parseCommand('gh api -X PUT repos/acme/api/pulls/9/merge'),
    r({ merges: [merge({ pr: 9, repo: 'acme/api', via: 'gh-api' })] }));
});
test('gh pr merge $N is opaque', () => {
  assert.deepEqual(parseCommand('gh pr merge $N --repo acme/api'),
    r({ opaque: ['gh pr merge $N --repo acme/api'] }));
});
test('gh pr view is nothing', () => {
  assert.deepEqual(parseCommand('gh pr view 12 --repo acme/api'), r({}));
});
test('git -C dir push', () => {
  assert.deepEqual(parseCommand('git -C ../api push origin t/41-x'),
    r({ pushes: [push({ dir: '../api', remote: 'origin', refspecs: ['t/41-x'] })] }));
});
test('push --force-with-lease +main', () => {
  assert.deepEqual(parseCommand('git push --force-with-lease origin +main'),
    r({ pushes: [push({ remote: 'origin', refspecs: ['+main'], force: true })] }));
});
test('push :branch deletes', () => {
  assert.deepEqual(parseCommand('git push origin :t/41-x'),
    r({ pushes: [push({ remote: 'origin', refspecs: [':t/41-x'], del: true })] }));
});
test('worktree add -b', () => {
  assert.deepEqual(parseCommand('git worktree add ../wt -b t/41-x origin/main'),
    r({ branches: [branch({ name: 't/41-x', via: 'worktree-add' })] }));
});
test('worktree add positional branch', () => {
  assert.deepEqual(parseCommand('git worktree add ../wt t/41-x'),
    r({ branches: [branch({ name: 't/41-x', via: 'worktree-add' })] }));
});
test('switch -c', () => {
  assert.deepEqual(parseCommand('git switch -c t/41-x'),
    r({ branches: [branch({ name: 't/41-x', via: 'switch' })] }));
});
test('checkout -b', () => {
  assert.deepEqual(parseCommand('git checkout -b t/41-x'),
    r({ branches: [branch({ name: 't/41-x', via: 'checkout' })] }));
});
test('quoted echo argument is nothing', () => {
  assert.deepEqual(parseCommand('echo "gh pr merge 1 --repo a/b"'), r({}));
});
test('bash -c is opaque', () => {
  assert.deepEqual(parseCommand('bash -c "gh pr merge 1 --repo a/b"'),
    r({ opaque: ['bash -c "gh pr merge 1 --repo a/b"'] }));
});
test('commit then push', () => {
  assert.deepEqual(parseCommand('git commit -m "x" && git push'),
    r({ commits: [commit({})], pushes: [push({})] }));
});

// --- ruling R1: literal cd carries, non-literal cd makes later git/gh-merge opaque ---
test('R1: literal cd sets the dir of later segments', () => {
  assert.deepEqual(parseCommand('cd ../api && git push origin main'),
    r({ pushes: [push({ dir: '../api', remote: 'origin', refspecs: ['main'] })] }));
});
test('R1: non-literal cd makes the later push opaque', () => {
  assert.deepEqual(parseCommand('cd $D && git push'), r({ opaque: ['git push'] }));
});
test('R1: cd in a later segment affects only segments after it', () => {
  assert.deepEqual(parseCommand('git commit -am x; cd ../api && git push; git -C sub commit'),
    r({ commits: [commit({ all: true }), commit({ dir: '../api/sub' })],
      pushes: [push({ dir: '../api' })] }));
});
test('R1: cd inside a subshell does not leak out', () => {
  assert.deepEqual(parseCommand('(cd ../api && git push) && git push'),
    r({ pushes: [push({ dir: '../api' }), push({})] }));
});
test('R1: an absolute -C wins over cd', () => {
  assert.deepEqual(parseCommand('cd ../api && git -C C:/x/core push'),
    r({ pushes: [push({ dir: 'C:/x/core' })] }));
});

// --- ruling R2: Commit.all ---
test('R2: commit -a / --all / -am / -ma', () => {
  assert.deepEqual(parseCommand('git commit -a -m x'), r({ commits: [commit({ all: true })] }));
  assert.deepEqual(parseCommand('git commit --all -m x'), r({ commits: [commit({ all: true })] }));
  assert.deepEqual(parseCommand('git commit -am x'), r({ commits: [commit({ all: true })] }));
  // -m takes the rest of the cluster as its argument: "-ma" is message "a", not --all
  assert.deepEqual(parseCommand('git commit -ma'), r({ commits: [commit({})] }));
});

// --- extra guard rows ---
test('push force/delete flag spellings', () => {
  const f = (c) => parseCommand(c).pushes[0];
  assert.equal(f('git push -f origin x').force, true);
  assert.equal(f('git push -uf origin x').force, true);
  assert.equal(f('git push --force origin x').force, true);
  assert.equal(f('git push --force-with-lease=x:abc origin x').force, true);
  assert.equal(f('git push --force-if-includes origin x').force, false);
  assert.equal(f('git push --delete origin x').del, true);
  assert.equal(f('git push -d origin x').del, true);
  assert.equal(f('git push origin x').force, false);
  assert.equal(f('git push origin +main').force, true);  // the + alone, no force flag
});
test('R1: cd in a pipeline or a background job does not carry', () => {
  assert.deepEqual(parseCommand('true | cd ../api; git push'), r({ pushes: [push({})] }));
  assert.deepEqual(parseCommand('cd ../api | true; git push'), r({ pushes: [push({})] }));
  assert.deepEqual(parseCommand('cd ../api & git push'), r({ pushes: [push({})] }));
});
test('push option arguments are not refspecs', () => {
  assert.deepEqual(parseCommand('git push -o ci.skip origin HEAD:refs/heads/t/1-a'),
    r({ pushes: [push({ remote: 'origin', refspecs: ['HEAD:refs/heads/t/1-a'] })] }));
  assert.deepEqual(parseCommand('git push --repo=upstream'), r({ pushes: [push({ remote: 'upstream' })] }));
  // git: a positional <repository> takes precedence over --repo
  assert.deepEqual(parseCommand('git push --repo upstream origin x'),
    r({ pushes: [push({ remote: 'origin', refspecs: ['x'] })] }));
  assert.deepEqual(parseCommand('git -c http.x=1 push -u origin t/1-a 2>&1 | tail -3'),
    r({ pushes: [push({ remote: 'origin', refspecs: ['t/1-a'] })] }));
});
test('push with $VAR refspec is opaque', () => {
  assert.deepEqual(parseCommand('git push origin "$B"'), r({ opaque: ['git push origin "$B"'] }));
});
test('quoted $MSG in commit message is fine; unquoted $X is not', () => {
  assert.deepEqual(parseCommand('git commit -m "$MSG"'), r({ commits: [commit({})] }));
  assert.deepEqual(parseCommand('git commit $FLAGS'), r({ opaque: ['git commit $FLAGS'] }));
});
test('heredoc commit message (the common form) parses; body text is not a command', () => {
  const cmd = 'git commit -m "$(cat <<\'EOF\'\nfix: don\'t git push here\n\nbody; gh pr merge 3\nEOF\n)" && git push origin t/1-a';
  assert.deepEqual(parseCommand(cmd),
    r({ commits: [commit({})], pushes: [push({ remote: 'origin', refspecs: ['t/1-a'] })] }));
});
test('command substitution runs its body: the merge inside is seen', () => {
  assert.deepEqual(parseCommand('echo $(gh pr merge 5 --repo acme/api)'),
    r({ merges: [merge({ pr: 5, repo: 'acme/api' })] }));
  assert.deepEqual(parseCommand('echo `git push origin x`'),
    r({ pushes: [push({ remote: 'origin', refspecs: ['x'] })] }));
});
test('eval / xargs / sh -c are opaque when they mention a guarded command', () => {
  assert.equal(parseCommand('eval "git push"').opaque.length, 1);
  assert.equal(parseCommand('echo 1 | xargs gh pr merge').opaque.length, 1);
  assert.equal(parseCommand("sh -c 'git commit -m x'").opaque.length, 1);
  assert.deepEqual(parseCommand('bash -c "ls"'), r({}));
});
test('separators: ; || | newline & and quoted separators', () => {
  assert.equal(parseCommand('true; git push').pushes.length, 1);
  assert.equal(parseCommand('false || git push').pushes.length, 1);
  assert.equal(parseCommand('ls\ngit push').pushes.length, 1);
  assert.equal(parseCommand('sleep 1 & git push').pushes.length, 1);
  assert.deepEqual(parseCommand('echo "a && git push"'), r({}));
  assert.deepEqual(parseCommand("echo 'x; git push'"), r({}));
  assert.deepEqual(parseCommand('echo a\\;git push'), r({}));
});
test('wrappers and keywords before the command', () => {
  assert.equal(parseCommand('time git push').pushes.length, 1);
  assert.equal(parseCommand('env GH_REPO=acme/api gh pr merge 3').merges[0].repo, 'acme/api');
  assert.equal(parseCommand('if git push; then echo ok; fi').pushes.length, 1);
});
test('export GH_REPO carries to later gh segments', () => {
  assert.deepEqual(parseCommand('export GH_REPO=acme/api; gh pr merge 4'),
    r({ merges: [merge({ pr: 4, repo: 'acme/api' })] }));
});
test('gh pr merge URL, --repo=, no selector, branch selector, --disable-auto', () => {
  assert.deepEqual(parseCommand('gh pr merge https://github.com/acme/api/pull/31 --merge'),
    r({ merges: [merge({ pr: 31, repo: 'acme/api' })] }));
  assert.deepEqual(parseCommand('gh pr merge --repo=acme/api 8'), r({ merges: [merge({ pr: 8, repo: 'acme/api' })] }));
  assert.deepEqual(parseCommand('gh pr merge --squash'), r({ merges: [merge({})] }));
  assert.deepEqual(parseCommand('gh pr merge t/41-x'), r({ opaque: ['gh pr merge t/41-x'] }));
  assert.deepEqual(parseCommand('gh pr merge 3 --disable-auto'), r({}));
});
test('gh pr merge after a literal cd with no repo is opaque (Merge has no dir)', () => {
  assert.deepEqual(parseCommand('cd ../api && gh pr merge 3'), r({ opaque: ['gh pr merge 3'] }));
});
test('gh pr merge with an unquoted $VAR flag is opaque (word splitting can add --repo)', () => {
  assert.deepEqual(parseCommand('gh pr merge 3 --repo acme/api $EXTRA'), r({ opaque: ['gh pr merge 3 --repo acme/api $EXTRA'] }));
});
test('gh api: GET is not a merge, graphql merge mutation is opaque', () => {
  assert.deepEqual(parseCommand('gh api repos/acme/api/pulls/9/merge'), r({}));
  assert.deepEqual(parseCommand('gh api --method put /repos/acme/api/pulls/9/merge'),
    r({ merges: [merge({ pr: 9, repo: 'acme/api', via: 'gh-api' })] }));
  assert.equal(parseCommand("gh api graphql -f query='mutation { mergePullRequest(input:{}) { clientMutationId } }'").opaque.length, 1);
});
test('git branch creates; branch -d / list do not', () => {
  assert.deepEqual(parseCommand('git branch t/41-x origin/main'),
    r({ branches: [branch({ name: 't/41-x', via: 'branch' })] }));
  assert.deepEqual(parseCommand('git branch -D t/41-x'), r({}));
  assert.deepEqual(parseCommand('git branch'), r({}));
  assert.deepEqual(parseCommand('git branch --show-current'), r({}));
});
test('worktree add: --detach has no branch; bare path names basename', () => {
  assert.deepEqual(parseCommand('git worktree add --detach ../wt origin/main'), r({}));
  assert.deepEqual(parseCommand('git -C ../api worktree add ../t-41'),
    r({ branches: [branch({ dir: '../api', name: 't-41', via: 'worktree-add' })] }));
});
test('unclosed quote that mentions a guarded command is opaque', () => {
  assert.equal(parseCommand('echo "x && git push').opaque.length, 1);
});
test('comments are ignored', () => {
  assert.deepEqual(parseCommand('ls # git push'), r({}));
});

// --- fix round 1 (review): every probed command gets a row ---
test('F1: -R/--repo before pr or between pr and merge', () => {
  const m5 = r({ merges: [merge({ pr: 5, repo: 'acme/api' })] });
  assert.deepEqual(parseCommand('gh --repo acme/api pr merge 5'), m5);
  assert.deepEqual(parseCommand('gh -R acme/api pr merge 5'), m5);
  assert.deepEqual(parseCommand('gh pr --repo acme/api merge 5'), m5);
  assert.deepEqual(parseCommand('gh --repo=acme/api pr merge 5'), m5);
  assert.deepEqual(parseCommand('gh -Racme/api pr merge 5'), m5);
  assert.deepEqual(parseCommand('gh -R acme/api pr view 5'), r({}));
});
test('F2: an unreadable guarded call is opaque even when the raw text misses MENTION', () => {
  assert.deepEqual(parseCommand('git checkout -q -b "$B"'), r({ opaque: ['git checkout -q -b "$B"'] }));
  assert.deepEqual(parseCommand('git switch -q -c $B'), r({ opaque: ['git switch -q -c $B'] }));
  assert.deepEqual(parseCommand('cd $D && git checkout -q -b t/41-x'), r({ opaque: ['git checkout -q -b t/41-x'] }));
  // not a branch creation: still nothing, even after an unreadable cd
  assert.deepEqual(parseCommand('cd $D && git checkout main'), r({}));
  assert.deepEqual(parseCommand('git checkout "$B"'), r({}));
});
test('F3: stuck short flags', () => {
  assert.deepEqual(parseCommand('git checkout -bt/41-x'), r({ branches: [branch({ name: 't/41-x', via: 'checkout' })] }));
  assert.deepEqual(parseCommand('git switch -ct/41-x'), r({ branches: [branch({ name: 't/41-x', via: 'switch' })] }));
  assert.deepEqual(parseCommand('git checkout -qb t/41-x'), r({ branches: [branch({ name: 't/41-x', via: 'checkout' })] }));
  assert.deepEqual(parseCommand('git worktree add -bt/41-x ../wt'), r({ branches: [branch({ name: 't/41-x', via: 'worktree-add' })] }));
  assert.deepEqual(parseCommand('git worktree add -fB t/41-x ../wt'), r({ branches: [branch({ name: 't/41-x', via: 'worktree-add' })] }));
});
test('F4: git branch copy/move creates the new name', () => {
  assert.deepEqual(parseCommand('git branch -c main t/41-x'), r({ branches: [branch({ name: 't/41-x', via: 'branch' })] }));
  assert.deepEqual(parseCommand('git branch -M t/41-x'), r({ branches: [branch({ name: 't/41-x', via: 'branch' })] }));
  assert.deepEqual(parseCommand('git branch --move old t/41-x'), r({ branches: [branch({ name: 't/41-x', via: 'branch' })] }));
});
test('F5: push --all/--branches is opaque; --tags names refs/tags/*', () => {
  assert.deepEqual(parseCommand('git push --all origin'), r({ opaque: ['git push --all origin'] }));
  assert.deepEqual(parseCommand('git push --branches origin'), r({ opaque: ['git push --branches origin'] }));
  // ruling R8
  assert.deepEqual(parseCommand('git push --mirror origin'), r({ opaque: ['git push --mirror origin'] }));
  assert.deepEqual(parseCommand('git push --mirror'), r({ opaque: ['git push --mirror'] }));
  assert.deepEqual(parseCommand('git push --tags origin'), r({ pushes: [push({ remote: 'origin', refspecs: ['refs/tags/*'] })] }));
});
test('F6: GIT_DIR / GIT_WORK_TREE make a guarded git call opaque', () => {
  assert.deepEqual(parseCommand('GIT_DIR=../x/.git git push origin main'), r({ opaque: ['GIT_DIR=../x/.git git push origin main'] }));
  assert.deepEqual(parseCommand('GIT_WORK_TREE=../x git commit -m y'), r({ opaque: ['GIT_WORK_TREE=../x git commit -m y'] }));
  assert.deepEqual(parseCommand('export GIT_DIR=../x/.git; git push'), r({ opaque: ['git push'] }));
  assert.deepEqual(parseCommand('git --git-dir=../x/.git push'), r({ opaque: ['git --git-dir=../x/.git push'] }));
});
test('F7: global options that take a value; unknown ones are opaque', () => {
  assert.deepEqual(parseCommand('git --attr-source HEAD push origin main'),
    r({ pushes: [push({ remote: 'origin', refspecs: ['main'] })] }));
  assert.deepEqual(parseCommand('git --exec-path=/x push origin main'),
    r({ pushes: [push({ remote: 'origin', refspecs: ['main'] })] }));
  assert.deepEqual(parseCommand('git --frobnicate HEAD push origin main'), r({ opaque: ['git --frobnicate HEAD push origin main'] }));
  assert.deepEqual(parseCommand('git --frobnicate HEAD status'), r({}));
});
test('F8: env -C/--chdir/-S are opaque; sudo runs its arguments (R28: opaque, sudo -D moves the dir)', () => {
  assert.equal(parseCommand('env -C ../api git push').opaque.length, 1);
  assert.equal(parseCommand('env --chdir=../api git push').opaque.length, 1);
  assert.equal(parseCommand("env -S 'git push'").opaque.length, 1);
  // was read exactly before R28; sudo is a CODE_RUNNER now (sudo -D <dir> / -s / -i were misread as the cwd)
  assert.deepEqual(parseCommand('sudo -u bob git push origin x'), r({ opaque: ['sudo -u bob git push origin x'] }));
});
test('F11: gh -R x pr merge; git --no-pager push', () => {
  assert.deepEqual(parseCommand('gh -R acme/api pr merge 12 --auto'), r({ merges: [merge({ pr: 12, repo: 'acme/api', auto: true })] }));
  assert.deepEqual(parseCommand('git --no-pager push origin t/41-x'), r({ pushes: [push({ remote: 'origin', refspecs: ['t/41-x'] })] }));
});

test('bin/hook-parse prints parseCommand as JSON', () => {
  const out = execFileSync(process.execPath, [join(here, '../../../bin/hook-parse')],
    { input: 'git -C ../api push origin t/41-x', encoding: 'utf8' });
  assert.deepEqual(JSON.parse(out), { ...r({ pushes: [push({ dir: '../api', remote: 'origin', refspecs: ['t/41-x'] })] }),
    opaqueDirs: [], aliases: [] });
  const home = execFileSync(process.execPath, [join(here, '../../../bin/hook-parse')],
    { input: 'cd ~/api && git push origin main', encoding: 'utf8', env: { ...process.env, DEVFW_PARSE_HOME: 'C:/H' } });
  assert.equal(JSON.parse(home).pushes[0].dir, 'C:/H/api', 'hook-parse passes DEVFW_PARSE_HOME as home');
});

// ---- final-review fixes ----
const P = (c, o) => parseFull(c, o);
const D = (c, o) => { const x = P(c, o); return x.opaque.map((raw, i) => ({ raw, ...x.opaqueDirs[i] })); };
test('R20/C1: a dir the parser cannot read is reported unknown, per opaque entry', () => {
  for (const c of ['cd $D && git push origin main', 'pushd $D && git push origin main', 'popd && git push origin main',
    'cd - && git push origin main', 'cd /r/ap* && git push origin main', 'cd /r/{a,b} && git push origin main',
    'git -C "$D" push origin main', 'git -C ~/api push origin main', 'cd ~/api && git push origin main',
    'cd ~bob/api && git push origin main', 'GIT_DIR=/x/.git git push origin main', 'git --git-dir=/x/.git push origin main',
    'cd $D && git checkout -b t/4-x', 'cd $D && git commit -m x', 'cd $D && eval "git push"']) {
    const d = D(c);
    assert.equal(d.length, 1, `one opaque entry: ${c}`);
    assert.equal(d[0].unknown, true, `unknown dir: ${c}`);
  }
});
test('R20/C1: a readable dir is not unknown; a literal -C in an opaque segment is its dir', () => {
  assert.deepEqual(D('cd /r/api && git push $R main'), [{ raw: 'git push $R main', dir: '/r/api', unknown: false }]);
  assert.deepEqual(D('git push $R main'), [{ raw: 'git push $R main', dir: null, unknown: false }]);
  // R28 reseed: xargs is a CODE_RUNNER (its git dir is unknown since R28), so the literal-dir fence uses stdbuf (R25 only)
  assert.deepEqual(D('stdbuf -oL git -C /r/api push origin < f'), [{ raw: 'stdbuf -oL git -C /r/api push origin < f', dir: '/r/api', unknown: false }]);
  assert.deepEqual(D('cd /r && stdbuf -oL git -C api push'), [{ raw: 'stdbuf -oL git -C api push', dir: '/r/api', unknown: false }]);
  assert.deepEqual(D('env --chdir=/r/api git push origin main'), [{ raw: 'env --chdir=/r/api git push origin main', dir: '/r/api', unknown: false }]);
});
test('R20: with a home, ~ and $HOME read as that literal path; ~user and quoted ~ do not', () => {
  const o = { home: '/h/u' };
  assert.equal(P('cd ~/api && git push origin main', o).pushes[0].dir, '/h/u/api');
  assert.equal(P('cd ~ && git push origin main', o).pushes[0].dir, '/h/u');
  assert.equal(P('git -C ~/api push origin main', o).pushes[0].dir, '/h/u/api');
  assert.equal(P('cd $HOME/api && git push origin main', o).pushes[0].dir, '/h/u/api');
  assert.equal(P('cd "${HOME}/api" && git push origin main', o).pushes[0].dir, '/h/u/api');
  assert.equal(D('cd ~bob/api && git push origin main', o)[0].unknown, true);
  assert.equal(D('cd "~/api" && git push origin main', o).length, 0, 'a quoted ~ is a literal dir named ~');
  assert.equal(P('cd "~/api" && git push origin main', o).pushes[0].dir, '~/api');
  assert.equal(D('cd $HOME/api && git push origin main', { home: '/h/a b' })[0].unknown, true, 'unquoted $HOME with a space splits');
});
test('R20: exec is a transparent wrapper', () => {
  assert.deepEqual(P('exec git -C /r/api push origin main').pushes, [push({ dir: '/r/api', remote: 'origin', refspecs: ['main'] })]);
  assert.deepEqual(P('exec -a x git push origin main').pushes, [push({ remote: 'origin', refspecs: ['main'] })]);
});
test('R25/I4: an unknown wrapper before git/gh is opaque; data commands are not', () => {
  for (const c of ['stdbuf -oL git -C /r/api push origin main', 'winpty gh pr merge 5 --repo acme/api',
    'flock /tmp/l git push origin main', 'ionice -c3 git commit -m x', 'unbuffer git checkout -b t/4-x']) {
    assert.equal(P(c).opaque.length, 1, c);
  }
  for (const c of ['echo git push origin main', 'grep -n git push.log', 'stdbuf -oL make push']) {
    assert.equal(P(c).opaque.length, 0, c);
  }
});
test('R25/I4: non-builtin git / gh subcommands are alias candidates; builtins are not', () => {
  assert.deepEqual(P('cd /r/api && git p origin main').aliases, [{ tool: 'git', name: 'p', dir: '/r/api', unknown: false, raw: 'git p origin main' }]);
  assert.deepEqual(P('cd $D && git p origin main').aliases, [{ tool: 'git', name: 'p', dir: null, unknown: true, raw: 'git p origin main' }]);
  assert.deepEqual(P('gh m 5').aliases, [{ tool: 'gh', name: 'm', dir: null, unknown: false, raw: 'gh m 5' }]);
  assert.deepEqual(P('git status && git log && gh pr view 5 && gh issue list').aliases, []);
});
test('R22/C3: gh api endpoints as full URLs are normalised before matching', () => {
  const m = [merge({ pr: 5, repo: 'acme/api', via: 'gh-api' })];
  assert.deepEqual(P('gh api -X PUT https://api.github.com/repos/acme/api/pulls/5/merge').merges, m);
  assert.deepEqual(P('gh api -X PUT http://ghe.example/api/v3/repos/acme/api/pulls/5/merge').merges, m);
  assert.deepEqual(P('gh api -X PUT //repos/acme/api/pulls/5/merge').merges, m);
  assert.equal(P('gh api -X PUT https://api.github.com/repos/acme/api/pulls/5/merge/x').opaque.length, 1, 'merge endpoint not exact + PUT');
  assert.equal(P('gh api https://api.github.com/repos/acme/api/pulls/5/merge').opaque.length, 0, 'GET is a status read');
});

test('R12: dynamic command word with a guarded verb is opaque without a MENTION hit', () => {
  assert.deepEqual(parseCommand('g=gh; $g pr merge 5 --repo acme/api').opaque, ['$g pr merge 5 --repo acme/api']);
  assert.deepEqual(parseCommand('$(echo gh) PR MERGE 5').opaque, ['$(echo gh) PR MERGE 5']);
  assert.deepEqual(parseCommand('$g status').opaque, []);
});

// ---- plan 3 hardening (rulings R27-R31) ----
const U = (c, o) => D(c, o).map((d) => d.unknown);
test('R27/A: command words fold case and a path / .exe suffix', () => {
  const p = [push({ remote: 'origin', refspecs: ['main'] })];
  for (const c of ['GIT push origin main', 'Git.EXE push origin main', '/usr/bin/git push origin main',
    '"C:/Program Files/Git/cmd/git.exe" push origin main', 'git PUSH origin main', 'COMMAND GIT push origin main',
    'EXEC Git push origin main', 'ENV A=1 GIT push origin main', 'TIMEOUT 5 git push origin main']) {
    assert.deepEqual(P(c).pushes, p, c);
  }
  assert.deepEqual(P('Gh pr merge 5 --repo acme/api').merges, [merge({ pr: 5, repo: 'acme/api' })]);
  assert.deepEqual(P('GH.exe PR MERGE 5 --repo acme/api').merges, [merge({ pr: 5, repo: 'acme/api' })]);
  assert.deepEqual(P('CD /r/api && GIT push origin main').pushes, [push({ dir: '/r/api', remote: 'origin', refspecs: ['main'] })]);
  assert.equal(P('EVAL "git push"').opaque.length, 1, 'EXECS fold');
  assert.equal(P('ECHO git push origin main').opaque.length, 0, 'DATA fold');
  assert.equal(P('STDBUF -oL GIT push origin main').opaque.length, 1, 'R25 arg check folds');
  assert.deepEqual(P('EXPORT GIT_DIR=/x; git push origin main').opaque, ['git push origin main'], 'export folds');
  // no-regression: a plain builtin in any case is still nothing
  assert.deepEqual(P('Git status'), { ...r({}), opaqueDirs: [], aliases: [] });
});
test('R28/B: a code-running word whose arguments mention git/gh is opaque with an unknown dir', () => {
  for (const c of ["script -qc 'git push origin main'", `python -c "import os; os.system('git push origin main')"`,
    `perl -e 'system("git push origin main")'`, "bash -c 'cd ~/api && git push origin main'",
    `node -e "require('child_process').execSync('GIT.exe push origin main')"`, 'sudo -u bob git push origin x',
    'nohup git push origin main', 'wsl git push origin main', `python3.12 -c 'import os; os.system("gh pr merge 5")'`,
    'xargs git -C /r/api push origin < f', 'eval "git push"', `Python -c 'x("git commit")'`]) {
    assert.deepEqual(U(c), [true], c);
  }
  assert.deepEqual(U("bash -c 'cd ~/api && git push origin main'", { home: '/h/u' }), [true], 'even with a home');
  // no-regression: no git/gh word -> nothing; .git and github are not the word git
  for (const c of ['python -c "print(1)"', 'python script.py push', "node -e 'console.log(1)'", 'find . -name .git',
    "python -c 'import github'"]) {
    assert.deepEqual(P(c).opaque, [], c);
  }
});
test('R30/D: inline alias / include config makes a git call opaque unless it is a harmless builtin', () => {
  for (const c of ['git -c alias.x=push x origin main', 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0=push git x origin main',
    `GIT_CONFIG_PARAMETERS="'alias.x'='push'" git x origin main`, 'git --config-env=alias.x=V x origin main',
    'git --config-env alias.x=V x origin main', 'git -c ALIAS.x=push x origin main', 'git -c include.path=/t/c push origin main',
    'git -c includeIf.onbranch:main.path=/t/c commit -m x', 'export GIT_CONFIG_COUNT=1; git x origin main',
    'GIT_CONFIG_GLOBAL=/t/c git x', 'GIT_CONFIG_SYSTEM=/t/c git push origin main', 'GIT_CONFIG=/t/c git x',
    'env GIT_CONFIG_PARAMETERS=x git x origin main', 'git -c "$K" x origin main', 'HOME=/t git x origin main',
    'git -c remote.origin.url=https://github.com/acme/api push origin main']) {
    const x = P(c);
    assert.equal(x.opaque.length, 1, c);
    assert.equal(x.opaqueDirs[0].unknown, false, `dir as known: ${c}`);
    assert.deepEqual(x.aliases, [], `not an alias candidate: ${c}`);
    assert.deepEqual(x.pushes, [], `not read as a push: ${c}`);
  }
  assert.deepEqual(D('cd /r/api && git -c alias.x=push x origin main')[0].dir, '/r/api');
  // an alias the hook cannot read is every guard's business (any); a guarded builtin is matched by its own verb
  assert.equal(P('GIT_CONFIG_GLOBAL=/t/c git x origin main').opaqueDirs[0].any, true, 'any: alias from injected config');
  assert.equal(P('git -c include.path=/t/c push origin main').opaqueDirs[0].any, undefined, 'guarded builtin: not any');
  assert.equal(P('GH_CONFIG_DIR=/t gh m 5').opaqueDirs[0].any, true, 'any: gh alias from another config dir');
  // no-regression
  assert.deepEqual(P('git -c color.ui=never status'), { ...r({}), opaqueDirs: [], aliases: [] });
  assert.deepEqual(P('GIT_CONFIG_COUNT=1 git log'), { ...r({}), opaqueDirs: [], aliases: [] });
  assert.deepEqual(P('git -c color.ui=never push origin t/12-x').pushes, [push({ remote: 'origin', refspecs: ['t/12-x'] })]);
  assert.deepEqual(P('git -c user.name=t commit -m x').commits, [commit({})]);
  assert.deepEqual(P('git push origin t/12-x').pushes, [push({ remote: 'origin', refspecs: ['t/12-x'] })]);
  assert.deepEqual(P('git commit -m x').commits, [commit({})]);
  // gh: a config dir from the environment hides which aliases exist
  assert.equal(P('GH_CONFIG_DIR=/t gh m 5').opaque.length, 1);
  assert.deepEqual(P('GH_CONFIG_DIR=/t gh m 5').aliases, []);
});
test('R31/E: a relative cd while CDPATH is set has an unknown dir', () => {
  for (const [c, o] of [['CDPATH=/r cd api && git push origin main'], ['export CDPATH=/r; cd api && git push origin main'],
    ['cd api && git push origin main', { cdpath: true }], ['pushd api && git push origin main', { cdpath: true }],
    ['CDPATH=$X cd api && git push origin main']]) {
    assert.deepEqual(U(c, o), [true], c);
  }
  const at = (c, o) => P(c, o).pushes.map((p) => p.dir);
  assert.deepEqual(at('cd api && git push origin main'), ['api'], 'no CDPATH: relative to the cwd');
  assert.deepEqual(at('cd /r/api && git push origin main', { cdpath: true }), ['/r/api'], 'absolute: CDPATH unused');
  assert.deepEqual(at('cd ./api && git push origin main', { cdpath: true }), ['./api'], './: CDPATH unused');
  assert.deepEqual(at('cd ../api && git push origin main', { cdpath: true }), ['../api'], '../: CDPATH unused');
  assert.deepEqual(at('unset CDPATH; cd api && git push origin main', { cdpath: true }), ['api'], 'unset CDPATH');
  assert.deepEqual(at('CDPATH= cd api && git push origin main'), ['api'], 'empty CDPATH');
  const out = execFileSync(process.execPath, [join(here, '../../../bin/hook-parse')],
    { input: 'cd api && git push origin main', encoding: 'utf8', env: { ...process.env, CDPATH: '/r' } });
  assert.deepEqual(JSON.parse(out).opaqueDirs, [{ dir: null, unknown: true }], 'hook-parse reads the hook CDPATH');
});
test('R29/C: hook-parse lists the git and gh command names when there is an alias candidate', () => {
  const run = (input) => JSON.parse(execFileSync(process.execPath, [join(here, '../../../bin/hook-parse')], { input, encoding: 'utf8' }));
  const a = run('git q origin main');
  assert.ok(a.gitCommands.includes('push') && a.gitCommands.includes('status'), 'git commands');
  assert.ok(a.ghCommands.includes('pr') && a.ghCommands.includes('api'), 'gh commands');
  assert.equal(run('git status').gitCommands, undefined, 'only with an alias candidate');
});
