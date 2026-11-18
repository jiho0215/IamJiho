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
  // R28c adds the whole-command row (a pipe, a runner and gh): the segment row and that one
  assert.deepEqual(parseCommand('echo 1 | xargs gh pr merge').opaque, ['xargs gh pr merge', 'echo 1 | xargs gh pr merge']);
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
  // R12's own row is the segment; since R28d the dynamic command word also adds the whole-command row (gh in the text)
  assert.deepEqual(parseCommand('g=gh; $g pr merge 5 --repo acme/api').opaque,
    ['$g pr merge 5 --repo acme/api', 'g=gh; $g pr merge 5 --repo acme/api']);
  assert.deepEqual(parseCommand('$(echo gh) PR MERGE 5').opaque, ['$(echo gh) PR MERGE 5']);
  assert.deepEqual(parseCommand('$g status').opaque, []);
});

// ---- plan 3 hardening (rulings R27-R31) ----
const U = (c, o) => D(c, o).map((d) => d.unknown);
test('R27/A: command words fold case and a path / .exe suffix', () => {
  const p = [push({ remote: 'origin', refspecs: ['main'] })];
  for (const c of ['GIT push origin main', 'Git.EXE push origin main', '/usr/bin/git push origin main',
    '"C:/Program Files/Git/cmd/git.exe" push origin main', 'git PUSH origin main', 'command GIT push origin main',
    'exec Git push origin main', 'ENV A=1 GIT push origin main', 'TIMEOUT 5 git push origin main']) {
    assert.deepEqual(P(c).pushes, p, c);
  }
  assert.deepEqual(P('Gh pr merge 5 --repo acme/api').merges, [merge({ pr: 5, repo: 'acme/api' })]);
  assert.deepEqual(P('GH.exe PR MERGE 5 --repo acme/api').merges, [merge({ pr: 5, repo: 'acme/api' })]);
  assert.equal(P('ECHO git push origin main').opaque.length, 0, 'DATA fold');
  assert.equal(P('STDBUF -oL GIT push origin main').opaque.length, 1, 'R25 arg check folds');
});
test('R27a/C1: shell builtins match exactly; a mis-cased or wrapped cd/export/unset changes no state', () => {
  const p = (dir) => [push({ dir, remote: 'origin', refspecs: ['main'] })];
  // bash: CD / PUSHD are "command not found": the push runs in the cwd
  assert.deepEqual(P('CD /r/elsewhere; git push origin main').pushes, p(null));
  assert.deepEqual(P('Cd /tmp || git push origin main').pushes, p(null));
  assert.deepEqual(P('PUSHD /r/elsewhere; git push origin main').pushes, p(null));
  assert.deepEqual(P('CD /r/x; git commit -m x').commits, [commit({})]);
  assert.deepEqual(P('CD /r/x; git checkout -b t/43-z').branches, [branch({ name: 't/43-z', via: 'checkout' })]);
  assert.deepEqual(P('export CDPATH=/h; UNSET CDPATH; cd api && git push origin main').opaqueDirs, [{ dir: null, unknown: true }]);
  assert.deepEqual(P('EXPORT GH_REPO=acme/api; gh pr merge 5 --squash').merges, [merge({ pr: 5 })], 'GH_REPO not set');
  assert.deepEqual(P('EXPORT GIT_DIR=/x; git push origin main').pushes, p(null), 'EXPORT sets nothing');
  assert.deepEqual(P('env export GH_REPO=acme/api; gh pr merge 5 --squash').merges, [merge({ pr: 5 })], 'env export: not found');
  assert.deepEqual(P('export CDPATH=/h; env unset CDPATH; cd api && git push origin main').opaqueDirs, [{ dir: null, unknown: true }]);
  // a wrapper in front of cd: no state change in bash; the dir is unclear (R27a)
  for (const c of ['COMMAND cd /r/elsewhere; git push origin main', 'env cd /r/elsewhere; git push origin main',
    'timeout 5 cd /r/elsewhere; git push origin main', 'stdbuf -oL cd /r/x; git push origin main']) {
    assert.deepEqual(U(c), [true], c);
  }
  // exact builtins still work
  assert.deepEqual(P('cd /r/api && git push origin main').pushes, p('/r/api'));
  assert.deepEqual(P('command cd /r/api && git push origin main').pushes, p('/r/api'));
  // EVAL is not eval: no R28 code row. (R35 reseed: EVAL is still a non-data word, maybe an alias, so the unaccounted
  // `git push` text makes the R35 backstop row, which carries `mentions`; the R28 row would not.)
  assert.deepEqual(P('EVAL "git push"').opaqueDirs, [{ dir: null, unknown: true, mentions: ['git push'] }], 'EVAL is not eval');
  assert.equal(P('eval "git push"').opaque.length, 1);
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

// ---- fix round 1 (rulings R27a, R28a; minors M1, M2) ----
test('R28a/C2: a code runner anywhere in the segment, not only the command word', () => {
  for (const c of ["stdbuf -oL bash -c 'git push origin main'", "flock /t/l bash -c 'git push origin main'",
    `winpty python -c "import os; os.system('git push origin main')"`, "stdbuf -oL bash -c 'cd ~/api && git push origin main'",
    "stdbuf -oL bash -c 'gh pr merge 5 --repo acme/api --squash'", "STDBUF -oL BASH -c 'git commit -m x'"]) {
    assert.deepEqual(U(c), [true], c);
  }
  assert.deepEqual(P('stdbuf -oL make test').opaque, [], 'no runner, no git');
  assert.deepEqual(P("winpty python -c 'print(1)'").opaque, [], 'runner without git');
  assert.deepEqual(P('git commit -m python').commits, [commit({})], 'a git argument is not a runner');
});
test('R28a/I2: a dynamic command word with a git/gh argument has an unknown dir', () => {
  assert.deepEqual(U(`"$SHELL" -c 'cd ~/api && git push origin main'`), [true]);
  assert.deepEqual(U('$X -c "gh pr merge 5"'), [true]);
  assert.deepEqual(P('$X -c "echo hi"').opaque, []);
});
test('R28a/I1: a shell or interpreter fed code on stdin', () => {
  for (const c of ["echo 'git push origin main' | bash", "printf 'git push origin main' | sh",
    "bash <<'EOF'\ngit push origin main\nEOF", "python - <<'EOF'\nimport os; os.system('git push origin main')\nEOF",
    "echo 'gh pr merge 5 --repo acme/api --squash' | bash", "git show HEAD:deploy.sh | bash", "bash < /t/git.sh",
    "bash <<< 'git push origin main'"]) {
    const x = P(c);
    assert.equal(x.opaque.length, 1, c);
    assert.equal(x.opaqueDirs[0].unknown, true, c);
    assert.equal(x.opaque[0], c, `the row text is the whole command: ${c}`);
  }
  for (const c of ['echo hi | bash', 'git status | sort', "cat <<'EOF' | bash\necho hi\nEOF", 'npm test | tail',
    'npm test 2>&1 | tail -5', 'git diff | head -5', 'git log --oneline | grep merge']) {
    assert.deepEqual(P(c).opaque, [], c);
  }
});
test('R28b/NC1: a code runner or dynamic word fed on stdin, whatever its arguments, when the text mentions git/gh', () => {
  for (const c of ["echo 'git push origin main' | bash -s x", "echo 'git push origin main' | sh -s -- x",
    "echo 'git push origin main' | bash /dev/stdin", "echo 'git push origin main' | python3 /dev/stdin",
    "echo 'cd ~/api && git push origin main' | bash -s x", "bash -s x <<< 'cd ~/api && git push origin main'",
    "source /dev/stdin <<< 'cd ~/api && git push origin main'", ". /dev/fd/0 <<< 'git push origin main'",
    "echo 'gh pr merge 5 --repo acme/api --squash' | bash -s x", "echo 'git commit -m x' | bash -s x",
    `echo 'git push origin main' | "$SHELL"`, "echo 'git push origin main' | stdbuf -oL bash -s x"]) {
    const x = P(c);
    assert.equal(x.opaque.length, 1, c);
    assert.equal(x.opaqueDirs[0].unknown, true, c);
    assert.equal(x.opaque[0], c, `the row text is the whole command: ${c}`);
  }
  // R28b's accepted cost: a runner fed data from git is a row too; it blocks only when the text names a guard's verb
  assert.deepEqual(D('git log | python summarize.py').map((d) => d.unknown), [true]);
  assert.equal(P('git log | python summarize.py').opaque[0].includes('push'), false);
});
test('R28a/I3: a git/gh alias named inside an interpreter string is an alias candidate (dir unknown)', () => {
  const a = (c) => P(c).aliases.map(({ tool, name, dir, unknown }) => ({ tool, name, dir, unknown }));
  assert.deepEqual(a("bash -c 'git p origin main'"), [{ tool: 'git', name: 'p', dir: null, unknown: true }]);
  assert.deepEqual(a(`python -c "import os; os.system('git -C /x p origin main')"`), [{ tool: 'git', name: 'p', dir: null, unknown: true }]);
  assert.deepEqual(a("echo 'gh m 5' | bash"), [{ tool: 'gh', name: 'm', dir: null, unknown: true }]);
  assert.deepEqual(a("bash -c 'git status && gh pr view 5'"), [], 'commands are not aliases');
  assert.equal(P("bash -c 'git p origin main'").aliases[0].raw, "bash -c 'git p origin main'");
});
test('M1: a bare CDPATH= assignment is a shell variable cd reads', () => {
  assert.deepEqual(U('CDPATH=/h; cd api && git push origin main'), [true]);
  assert.deepEqual(U('CDPATH=/h && cd api && git push origin main'), [true]);
  assert.deepEqual(P('CDPATH=; cd api && git push origin main').pushes[0].dir, 'api');
});
test('M2: a git path component is not the word git', () => {
  assert.deepEqual(P('python tools/git/push_stats.py').opaque, []);
  assert.deepEqual(U('python /usr/bin/git push origin main'), [true], '/usr/bin/git followed by a space still is');
});

// ---- fix round 3 (ruling R28c) ----
test('R28c/NC2: a pipe or < anywhere, a runner / eval / source / dynamic word at any depth, and git/gh: one whole-command row', () => {
  for (const c of ["(echo 'git push origin main') | bash", "echo 'git push origin main' | (bash)",
    "(echo 'cd ~/api && git push origin main') | bash -s x", "(echo 'gh pr merge 5 --repo acme/api --squash') | bash",
    "echo 'gh pr merge 5 --repo acme/api --squash' | (bash)", "echo 'git commit -m x' | (bash)",
    "echo 'git push origin main' | if true; then bash; fi", "echo 'git push origin main' | for i in 1; do bash; done",
    `echo 'git push origin main' | while read -r l; do eval "$l"; done`,
    `while read -r l; do eval "$l"; done <<< 'git push origin main'`, `echo 'git push origin main' | { "$SHELL"; }`,
    "bash < <(echo 'git push origin main')", "(echo 'git push -q origin main') | bash -s x",
    `x=$(cat <(echo 'git push origin main')); eval "$x"`, `x=$(echo 'git push origin main' | cat); eval "$x"`]) {
    const x = P(c);
    const at = x.opaque.indexOf(c);
    assert.ok(at >= 0, `whole-command row: ${c}`);
    assert.equal(x.opaqueDirs[at].unknown, true, c);
  }
  for (const c of ['npm test | tail', 'git log | grep x', 'git status && git push origin t/12-x 2>&1 | tail -3',
    "(cd sub && git status) | cat", 'git diff | head -5']) {
    assert.deepEqual(P(c).opaque, [], c);
  }
});

// ---- fix round 4 (rulings R28d, R34) ----
const wholeRow = (c) => { const x = P(c); const at = x.opaque.indexOf(c); return at >= 0 && x.opaqueDirs[at].unknown === true; };
test('R28d/NC3: output process substitution >( ... ) feeds the runner inside it', () => {
  for (const c of ["echo 'git push origin main' > >(bash)", "echo 'git push origin main' >(bash)",
    "echo 'git push origin main' 1> >(bash -s x)", "echo 'cd ~/api && git push origin main' > >(bash)",
    "echo 'gh pr merge 5 --repo acme/api --squash' > >(bash)", "echo 'git commit -m x' > >(bash)",
    "echo 'git checkout -b t/43-z' > >(bash)", "echo 'git push -q origin main' > >(bash)"]) {
    assert.ok(wholeRow(c), c);
  }
  assert.deepEqual(P('npm test > >(tee log.txt)').opaque, [], 'no git text');
  assert.deepEqual(P('git status > >(tee log.txt)').opaque, [], 'no runner');
});
test('R28d/NC3: coproc is a feed and a runner', () => {
  for (const c of [`coproc bash; echo 'git push origin main' >&"\${COPROC[1]}"`,
    `coproc bash; echo 'cd ~/api && git push origin main' >&"\${COPROC[1]}"`,
    `coproc bash; echo 'gh pr merge 5 --repo acme/api --squash' >&"\${COPROC[1]}"`,
    `coproc bash; echo 'git commit -m x' >&"\${COPROC[1]}"`,
    `coproc S { bash; }; echo 'git push origin main' >&"\${S[1]}"`,
    `coproc cat; echo 'git push origin main' >&"\${COPROC[1]}"`,
    `coproc bash; echo 'git push -q origin main' >&"\${COPROC[1]}"; exec {COPROC[1]}>&-; wait`]) {
    assert.ok(wholeRow(c), c);
  }
  assert.deepEqual(P("echo 'coproc' && git status").opaque, [], 'a quoted coproc is data');
});
test('R28d: a runner given a dynamic argument, with git/gh in the text: one whole-command row', () => {
  for (const c of [`x='git push origin main'; eval "$x"`, `x='cd ~/api && git push origin main'; eval "$x"`,
    `x='git push origin main'; bash -c "$x"`, `x='git push origin main'; "$SHELL" -c "$x"`,
    `x='git push origin main'; $x`, `x='gh pr merge 5 --repo acme/api --squash'; eval "$x"`,
    `x='git commit -m x'; eval "$x"`, `x='git checkout -b t/43-z'; eval "$x"`,
    `x='git push origin main'; source /dev/fd/3 3<<<"$x"`, `x='git push origin main'; python3 -c "$x"`,
    `f=git; eval "$f push origin main"`]) {
    assert.ok(wholeRow(c), c);
  }
  // no git/gh in the text, or no dynamic argument, or a bare {} (literal to bash): no row
  for (const c of [`x='echo hi'; eval "$x"`, 'eval "echo hi"; git status', "bash -c 'echo hi' && git status",
    "find . -name '*.orig' -exec rm {} \; && git push origin t/12-x"]) {
    assert.deepEqual(D(c).filter((d) => d.raw === c), [], c);
  }
  assert.deepEqual(P("find . -name '*.orig' -exec rm {} \; && git push origin t/12-x").pushes,
    [push({ remote: 'origin', refspecs: ['t/12-x'] })]);
});
test('R34: the branch-merge APIs are merges (REST repos/<o>/<n>/merges written to, GraphQL mergeBranch)', () => {
  const bm = (repo) => [{ pr: null, repo, auto: false, via: 'gh-api-branch-merge' }];
  for (const c of ['gh api -X POST repos/acme/api/merges -f base=main -f head=t/12-x',
    'gh api repos/acme/api/merges -f base=main -f head=t/12-x', 'gh api repos/acme/api/merges -fbase=main',
    'gh api --method=post https://api.github.com/repos/acme/api/merges -f base=main -f head=t/12-x',
    'gh api -XPOST /repos/acme/api/merges --input body.json', 'gh api -X PUT repos/acme/api/merges/ -F base=main',
    "gh api --method PATCH 'http://ghe.example/api/v3/repos/acme/api/merges?x=1' --raw-field base=main",
    'gh api -X POST REPOS/acme/api/MERGES -f base=main', 'gh api repos/acme/api/merges $ARGS']) {
    assert.deepEqual(P(c).merges, bm('acme/api'), c);
  }
  // an unquoted ? globs: the endpoint is dynamic, so the call is an opaque row naming the endpoint
  assert.equal(P('gh api -X POST repos/acme/api/merges?x=1 -f base=main').opaque.length, 1);
  assert.deepEqual(P('gh api -X POST repos/acme/core/merges -f base=main').merges, bm('acme/core'));
  assert.deepEqual(P("gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main").merges, bm(null), 'placeholder, no repo');
  assert.deepEqual(P("gh -R acme/api api -X POST 'repos/{owner}/{repo}/merges' -f base=main").merges, bm('acme/api'));
  assert.deepEqual(P(`gh api graphql -f query='mutation{mergeBranch(input:{repositoryId:"x",base:"main",head:"t"}){clientMutationId}}'`).merges,
    bm(null), 'GraphQL mergeBranch: the repo is a node id');
  const dynm = P('gh api -X "$M" repos/acme/api/merges');
  assert.deepEqual(dynm.merges, bm('acme/api'), 'an unknown method may be a write');
  assert.deepEqual(P('gh api -X POST repos/acme/api/merges/x -f base=main').opaque,
    ['gh api -X POST repos/acme/api/merges/x -f base=main'], 'names merges, does not read exactly');
  // reads are not merges
  for (const c of ['gh api repos/acme/api/merges', 'gh api -X GET repos/acme/api/merges -f per_page=1',
    'gh api repos/acme/api/pulls/5', 'gh api graphql -f query="{viewer{login}}"', 'git log --merges']) {
    const x = P(c);
    assert.deepEqual([x.merges, x.opaque], [[], []], c);
  }
  // an opaque form names the endpoint, so the merge gate's whole-word regex can see it
  assert.deepEqual(U("bash -c 'gh api -X POST repos/acme/api/merges -f base=main -f head=x'"), [true]);
  // MENTION names the endpoint and the mutation: an unreadable call (broken quote, dynamic endpoint) is still listed
  assert.deepEqual(P('gh api -X POST repos/acme/api/merges -f "base=main').opaque.length, 1, 'broken segment');
  assert.deepEqual(P(`gh api "$E" -f query='mutation{mergeBranch(input:{}){x}}'`).opaque.length, 1, 'dynamic endpoint');
});
test('fix round 4 no-regressions: heredoc commits, redirects, gh pr view, a claimed push', () => {
  const heredoc = "git commit -F - <<'EOF'\nfix: then push and merge; eval and bash and python\nEOF";
  const subst = "git commit -m \"$(cat <<'EOF'\nfix: run python, eval, then push\nEOF\n)\"";
  for (const c of [heredoc, subst, `${heredoc}\ngit push origin t/12-x`, `git add -A && ${subst} && git push origin t/12-x`]) {
    const x = P(c);
    assert.deepEqual(x.opaque, [], c);
    assert.equal(x.commits.length, 1, c);
  }
  assert.deepEqual(P('cat file > out.txt').opaque, []);
  assert.deepEqual(P('gh pr view 5 --json mergeStateStatus'), { ...r({}), opaqueDirs: [], aliases: [] });
  assert.deepEqual(P('git push origin t/12-x').pushes, [push({ remote: 'origin', refspecs: ['t/12-x'] })]);
  assert.deepEqual(P('git push origin t/12-x').opaque, []);
});

// ---- fix round 5 (rulings R28e, R34a) ----
test('R28e: the runner-code clause counts only a code-position argument that carries an expansion (NC4)', () => {
  // (a) eval/source/. : any arg that carries code; a shell's -c/-e/--eval/-Command arg; a $-bearing literal (NC4)
  for (const c of [`x='git push origin main'; eval "$x"`, `x='git push origin main'; bash -c "$x"`,
    `x='git push origin main'; "$SHELL" -c "$x"`, `V=push; bash -c "git $V origin main"`,
    `printf -v x 'git push origin main'; eval "$x"`,
    `x='cd ~/api && git push origin main'; bash -c 'eval "$1"' _ "$x"`,
    `export X='cd ~/api && git push origin main'; bash -c 'eval "$X"'`,
    `X='cd ~/api && git push origin main' bash -c 'eval "$X"'`,
    `X='cd ~/api && git push origin main' python -c 'import os; os.system(os.environ["X"])'`,
    // export form whose runner's code arg has no `$`: only the export-assignment clause catches it
    `export X='git push origin main'; python -c 'import os; os.system(os.environ["X"])'`]) {
    assert.ok(wholeRow(c), c);
  }
  // (b) a command word that is a single parameter expansion
  for (const c of [`x='git push origin main'; $x`, `set -- git push origin main; "$@"`,
    `x='git push origin main'; ${'${x}'}`, `"$EDITOR" && git push origin main`]) {
    assert.ok(wholeRow(c), c);
  }
  // a code-arg with no expansion is not the dynamic clause (bash -c with a literal git command is caught by R28a's
  // in-text listing instead, not here); a glob arg to a shell/eval does not count
  assert.deepEqual(P('eval *.sh && git push origin t/12-x').opaque, [], 'a glob arg to eval is not code');
});
test('NI1: a runner whose code position takes only a glob, a script file, or a plain arg is not a row', () => {
  // these ordinary test-then-push / test-then-commit chains must NOT produce a whole-command row (my round-4 regression)
  for (const c of ['node --test tests/*.mjs && git push origin t/12-x',
    'node --test tests/v6/node/*.test.mjs && git add -A && git commit -m x && git push origin t/12-x',
    'python -m pytest -k "$K" && git push origin t/12-x', 'python3 summarize.py *.json && git push origin t/12-x',
    'bash scripts/run.sh "$1" && git push origin t/12-x', 'npm run start -- --port "$PORT" && git push origin t/12-x',
    'find . -name "$pat" -delete && git push origin t/12-x', 'sudo -u "$USER" true && git push origin t/12-x',
    '"$REPO/scripts/test.sh" && git push origin t/12-x', 'bash -n "$f" && git commit -m x',
    'ssh "$HOST" uptime && git push origin t/12-x',
    // a non-shell runner's -c-looking flag (ssh -c cipher) is not a code flag: the shell-runner gate keeps it out
    'ssh -c "$ALGO" "$HOST" uptime && git push origin t/12-x',
    'K="run the git tests"; python -m pytest -k "$K" && git push origin t/12-x']) {
    assert.deepEqual(P(c).opaque, [], c);
  }
  // the chained git/gh calls are still read exactly
  assert.deepEqual(P('node --test tests/*.mjs && git push origin t/12-x').pushes,
    [push({ remote: 'origin', refspecs: ['t/12-x'] })]);
  assert.equal(P('node --test tests/v6/node/*.test.mjs && git add -A && git commit -m x && git push origin t/12-x').commits.length, 1);
});
test('R34a/NC5: a host-qualified GH_REPO and a combined -if flag reach the branch-merge path', () => {
  const bm = (repo) => [{ pr: null, repo, auto: false, via: 'gh-api-branch-merge' }];
  // the parser keeps GH_REPO as given; the hook applies the same host/URL normaliser as gh pr merge (fenced in the guard test)
  assert.deepEqual(P(`GH_REPO=github.com/acme/api gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main -f head=t/12-x`).merges,
    bm('github.com/acme/api'));
  assert.deepEqual(P(`GH_REPO=https://github.com/acme/api gh api -X POST 'repos/{owner}/{repo}/merges' -f base=main`).merges,
    bm('https://github.com/acme/api'));
  // R34a: a combined short cluster (-if = -i -f) is a field, so the write is detected
  assert.deepEqual(P('gh api repos/acme/api/merges -if base=main -if head=t/12-x').merges, bm('acme/api'));
  assert.deepEqual(P('gh api repos/acme/api/merges -fi base=main').merges, bm('acme/api'));
  // -i alone (no field) is still a GET: not a merge
  assert.deepEqual(P('gh api repos/acme/api/merges -i base=main').merges, []);
});

// ---- ruling R35: the unaccounted-mention backstop ----
// r35Row(c): the whole-command row (unknown dir; an R35 row carries `mentions`, the unaccounted mention texts).
const r35Row = (c) => { const x = P(c); const at = x.opaque.indexOf(c); return at >= 0 ? x.opaqueDirs[at] : undefined; };
const r35Mentions = (c) => (r35Row(c) || {}).mentions;
const PV = `printf -v x 'cd ~/api && git push origin main';`;
test('R35 fire: NC6-NC9 carry a literal guarded command into a non-data program: one whole-command row, unknown dir', () => {
  for (const c of [`${PV} bash -lc "$x"`, `${PV} bash -ec "$x"`, `${PV} bash -c"$x"`, `${PV} sudo bash -c "$x"`,
    `${PV} nohup bash -c "$x"`, `${PV} xargs bash -c "$x"`, `${PV} setsid bash -c "$x"`, `${PV} wsl bash -c "$x"`,
    `${PV} busybox sh -c "$x"`, `${PV} find . -maxdepth 0 -exec bash -c "$x" \\;`,
    `${PV} node -p "require('child_process').execSync(process.argv[1]).toString()" "$x"`,
    `${PV} perl -E 'system($ARGV[0])' "$x"`, `${PV} script -qc "$x" /dev/null`, `${PV} watch -n1 "$x"`,
    `printf -v x 'cd ~/api && git push origin main'; \${x:-}`,                                     // NC7
    `declare -x X='cd ~/api && git push origin main'; python -c 'import os; os.system(os.environ["X"])'`,  // NC8
    `typeset -x X='cd ~/api && git push origin main'; python -c 'import os; os.system(os.environ["X"])'`,
    `printf -v X 'cd ~/api && git push origin main'; export X; python -c 'import os; os.system(os.environ["X"])'`,
    `declare -x X='cd ~/api && git push origin main'; node -e 'require("child_process").execSync(process.env.X)'`,
    `${PV} python -c 'import os,sys; os.system(sys.argv[1])' "$x"`]) {                             // NC9
    const row = r35Row(c);
    assert.ok(row && row.unknown === true, c);
    assert.deepEqual(row.mentions, ["git push origin main"], c);
  }
  // NC7 array forms: one whole-command unknown row (R28e/NC4 or R35, whichever comes first)
  for (const c of ['cmd=(git push origin main); "${cmd[@]}"', 'declare -a cmd=(git push origin main); "${cmd[@]}"',
    'cmd=(cd ~/api); cd "${cmd[1]}"; x=(git push origin main); "${x[@]}"', 'cmd=(gh pr merge 5 --repo acme/api); "${cmd[@]}"']) {
    assert.equal((r35Row(c) || {}).unknown, true, c);
  }
});
test('R35 mention: where a mention may sit, and which verbs make one (per guard)', () => {
  const nd = 'npm test';  // a non-data program, so only the mention decides
  for (const [c, m] of [
    // heredoc body, $( ) body, backtick body, array literal, assignment value, path + .exe + case, a -C between,
    // a line continuation inside the run
    [`cat <<'EOF' > s.sh\ngit push origin main\nEOF\n${nd}`, 'git push origin main'],
    [`y=$(echo 'git push origin main'); ${nd}`, "git push origin main"],
    [`y=\`echo 'git push origin main'\`; ${nd}`, "git push origin main"],
    [`a=(x 'git push origin main'); ${nd}`, "git push origin main"],
    [`X='git push origin main'; ${nd}`, "git push origin main"],
    [`echo "/usr/bin/GIT.EXE  push"; ${nd}`, 'GIT.EXE  push'],
    [`echo 'git -C ~/api push'; ${nd}`, "git -C ~/api push"],
    [`echo 'git \\\npush origin main'; ${nd}`, "git   push origin main"],
    // each guard's verbs
    [`echo 'gh pr merge 5'; ${nd}`, "gh pr merge 5"], [`echo 'gh pr -R a/b merge 5'; ${nd}`, "gh pr -R a/b merge 5"],
    [`echo 'gh api -X PUT repos/a/b/pulls/5/merge'; ${nd}`, "gh api -X PUT repos/a/b/pulls/5/merge"],
    [`echo 'gh api -X POST repos/a/b/merges'; ${nd}`, "gh api -X POST repos/a/b/merges"],
    [`echo 'gh api graphql -f query=mutation{mergeBranch}'; ${nd}`, "gh api graphql -f query=mutation{mergeBranch}"],
    [`echo 'git checkout -b t/43-z'; ${nd}`, "git checkout -b t/43-z"],
    [`echo 'git checkout -qB t/43-z'; ${nd}`, "git checkout -qB t/43-z"],
    [`echo 'git switch -c t/43-z'; ${nd}`, "git switch -c t/43-z"], [`echo 'git branch t/43-z'; ${nd}`, "git branch t/43-z"],
    [`echo 'git worktree add ../w'; ${nd}`, "git worktree add ../w"], [`echo 'git commit -m x'; ${nd}`, "git commit -m x"],
  ]) assert.deepEqual(r35Mentions(c), [m], c);
  // not a mention: no guarded verb in the run, the verb in another run, a verb glued to a word (R33), not a git/gh word,
  // and the documented residuals (a verb or word that is never spelled)
  for (const c of [`echo 'git status'; ${nd}`, `echo 'gh pr view 5'; ${nd}`, `echo 'git log'; echo push; ${nd}`,
    `echo 'git pushd x'; ${nd}`, `echo 'gh pr view --json mergeStateStatus'; ${nd}`, `echo 'git branch --show-current'; ${nd}`,
    `echo 'git checkout main'; ${nd}`, `echo 'git switch main'; ${nd}`, `echo 'github push'; ${nd}`, `echo 'tools/git/push'; ${nd}`,
    `echo '.git push'; ${nd}`, `echo 'git-lfs push'; ${nd}`, `echo 'git pu""sh'; ${nd}`, `echo 'g""it push'; ${nd}`,
    `echo "git $V origin"; ${nd}`]) {
    assert.equal(r35Row(c), undefined, c);
  }
});
test('R35 accounting: a call the parser read accounts for the mention in its own command word, by position', () => {
  // read: no row (the pushes / commits / merges / branches themselves are reported as before)
  for (const c of ['npm test && git push origin t/12-x', 'npm test && gh pr merge 5 --repo acme/api --squash',
    'npm test && git checkout -b t/43-z', 'node x.js && GIT.exe commit -m x', 'npm test && env A=1 git push origin t/12-x',
    'npm test && timeout 60 git push origin t/12-x', 'npm test && git log --grep push',
    'npm test; echo "$(git push origin t/12-x)"', 'npm test; echo `git push origin t/12-x`',
    'npm test; echo `echo \\`git push origin t/12-x\\``',   // escaped backticks: the body map keeps the offsets
    'BR=$(git branch --show-current); npm test && node scripts/lint.js && git push origin t/12-x']) {  // NI2
    assert.equal(r35Row(c), undefined, c);
  }
  // the SAME text as an argument is not that call: a commit message, a --body, a rebase -x string (the stated cost)
  assert.deepEqual(r35Mentions('npm test && git commit -m "docs: explain git push flow"'), ['git push flow']);
  assert.deepEqual(r35Mentions('npm test && gh pr create --body "fix the git push docs"'), ['git push docs']);
  assert.deepEqual(r35Mentions("npm test && git rebase -x 'git push origin main' main"), ['git push origin main']);
  // positions, not counts: a read git call does not account for a mention elsewhere
  assert.deepEqual(r35Mentions(`printf -v x 'git push origin main'; git status; bash -lc "$x"`), ["git push origin main"]);
  assert.deepEqual(r35Mentions(`git push origin t/12-x; printf -v x 'git push origin main'; bash -lc "$x"`),
    ["git push origin main"]);
  // a call that is unreadable but already a row of its own accounts for itself (its R20 dir is kept)
  const x = P('git push origin "$BR" && npm test');
  assert.deepEqual(x.opaque, ['git push origin "$BR"']);
  assert.deepEqual(x.opaqueDirs, [{ dir: null, unknown: false }]);
});
test('R35 non-data: the row needs a segment, at any depth, whose command word is not git, gh or data', () => {
  for (const c of ['grep -rn "git push" docs/', "echo 'run git push later' > notes.md", 'git commit -m "docs: explain git push flow"',
    "git commit -F - <<'EOF'\ndocs: the git push flow\nEOF", "git commit -m \"$(cat <<'EOF'\ndocs: the git push flow\nEOF\n)\"",
    "gh pr create --title x --body \"$(cat <<'EOF'\nExplains git push and gh pr merge.\nEOF\n)\"",
    "printf -v x 'git push origin main'; echo \"$x\"", "x='git push origin main'", 'cmd=(git push origin main)',
    "declare -x X='git push origin main'; export Y=1", "cd sub && git commit -m 'explain git push'",
    'for f in a b; do echo "git push $f"; done', 'if git diff --quiet; then echo "git push"; fi',
    'read -r l <<< "git push origin main"', "test -n 'git push'"]) {
    assert.equal(r35Row(c), undefined, c);
  }
  for (const c of ["printf -v x 'git push origin main'; y=$(node -e 1)", "echo 'git push origin main'; (make)",
    "echo 'git push origin main' | tee notes.md", "echo 'git push origin main'; \"$EDITOR\" notes.md",
    "echo 'git push origin main'; if true; then npm test; fi", "echo 'git push origin main'; env -S 'echo x'",
    "echo 'git push origin main'; EXPORT X=1", "echo 'git push origin main'; some_alias"]) {
    assert.equal((r35Row(c) || {}).unknown, true, c);
  }
});
test('R35 scanner: an array literal is one assignment word', () => {
  assert.deepEqual(P('cmd=(git push origin main); echo "${cmd[@]}"').opaque, []);
  assert.deepEqual(P('cmd=(\n git push origin main\n); echo ok').opaque, []);
  // a $( ) inside an array literal still runs: its call is read
  assert.deepEqual(P('a=($(git push origin t/12-x)); echo ok').pushes, [push({ remote: 'origin', refspecs: ['t/12-x'] })]);
});
test('NI2: a command substitution in an assignment value is not git text carried into a runner', () => {
  for (const c of ['BR=$(git branch --show-current); npm test && node scripts/lint.js && git push origin t/12-x',
    'export BR=$(git branch --show-current); node x.js && git push origin t/12-x',
    'BR=`git branch --show-current`; node x.js && git push origin t/12-x']) {
    assert.deepEqual(P(c).opaque, [], c);
  }
  // literal git text in the value still carries (NC4 unchanged)
  assert.ok(wholeRow(`X='cd ~/api && git push origin main' bash -c 'eval "$X"'`));
});

// ---- R35 fix round 1 (C1, M2, R35a, R35b) ----
const unknownRow = (c) => (r35Row(c) || {}).unknown === true;
test('C1: the run is quote-aware relative to the mention, and a redirection never ends it', () => {
  const PY = `python -c 'import os,sys; os.system(sys.argv[1])' "$x"`;
  const NP = `node -p "require('child_process').execSync(process.argv[1]).toString()" "$x"`;
  for (const [c, m] of [
    [`printf -v x 'cd ~/api && git 2>&1 push origin main'; ${PY}`, 'git 2>&1 push origin main'],
    [`printf -v x 'cd ~/api && git -C "a;b" push origin main'; sudo bash -c "$x"`, 'git -C "a;b" push origin main'],
    [`printf -v x 'cd ~/api && git &>/dev/null push origin main'; sudo bash -c "$x"`, 'git &>/dev/null push origin main'],
    [`printf -v x 'git &>>log push origin main'; sudo bash -c "$x"`, 'git &>>log push origin main'],
    [`printf -v x 'git >| log push origin main'; sudo bash -c "$x"`, 'git >| log push origin main'],
    [`printf -v x 'git 2>/dev/null >&2 <&0 push origin main'; sudo bash -c "$x"`, 'git 2>/dev/null >&2 <&0 push origin main'],
    [`printf -v x 'gh pr --repo "acme/api|x" merge 5'; ${NP}`, 'gh pr --repo "acme/api|x" merge 5'],
    [`printf -v x 'gh pr 2>&1 merge 5 --repo acme/api'; sudo bash -c "$x"`, 'gh pr 2>&1 merge 5 --repo acme/api'],
    [`printf -v x 'git 2>&1 commit -m x'; sudo bash -c "$x"`, 'git 2>&1 commit -m x'],
    [`printf -v x 'git 2>&1 checkout -b t/43-z'; sudo bash -c "$x"`, 'git 2>&1 checkout -b t/43-z'],
    // an escaped inner quote inside an outer "..." is a quote of the inner level
    [`printf -v x "git -C \\"a;b\\" push origin main"; sudo bash -c "$x"`, 'git -C \\"a;b\\" push origin main'],
  ]) assert.deepEqual(r35Mentions(c), [m], c);
  // a terminator outside every quote opened after the mention ends the run (M1: | ; && || & newline each matter)
  for (const c of [`echo 'git log | grep push'; npm test`, `echo 'git log; echo push'; npm test`,
    `echo 'git log && echo push'; npm test`, `echo 'git log || echo push'; npm test`, `echo 'git log & echo push'; npm test`,
    `echo 'git log\necho push'; npm test`, `echo "$(git log | grep push)"; npm test`, 'echo `git log` push; npm test']) {
    assert.equal(r35Row(c), undefined, c);
  }
});
test('M2: a mention after an unquoted word-start # is a comment, not a mention', () => {
  for (const c of ['npm test && git commit -m "x" && git push origin t/12-x # git push origin main', 'npm test # git push origin main',
    "npm test\n# git push origin main\necho ok"]) {
    assert.equal(r35Row(c), undefined, c);
  }
  // a # inside a word or a quote is not a comment
  for (const c of [`echo "# x git push origin main"; npm test`, `x=a#b; echo 'git push origin main'; npm test`,
    `echo a#'git push origin main'; npm test`]) {
    assert.ok(unknownRow(c), c);
  }
  // a heredoc body is read as its own script: an apostrophe in it does not swallow what follows
  assert.ok(unknownRow("git commit -F - <<'EOF'\ndon't forget\nEOF\nnpm test && echo 'git push origin main'"));
  // ... so a comment after it is still a comment (without the heredoc rule the apostrophe would hide the #)
  assert.equal(r35Row("git commit -F - <<'EOF'\ndon't forget\nEOF\nnpm test # git push origin main"), undefined);
});
test('R35a: a data word that evaluates a subscript or indirection runs its $( ) / ` / ${!', () => {
  for (const c of [`printf -v 'a[$(cd ~/api && git push origin main)]' x`, `declare -i w='r[$(cd ~/api && git push origin main)]'`,
    `read -r 'b[$(cd ~/api && git push origin main)]' <<< x`, `test -v 'c[$(cd ~/api && git push origin main)]'`,
    `test -v 'c[\`git push origin main\`]'`, `printf -v 'a[$(gh pr merge 5 --repo acme/api)]' x`,
    `declare -i w='r[$(git commit -m x)]'`, `printf -v 'a[$(git checkout -b t/43-z)]' x`,
    `x='a[$(cd ~/api && git push origin main)]'; echo "\${!x}"`, `declare -n r='a[$(git push origin main)]'; echo "$r"`,
    `local -rn r='a[$(git push origin main)]'`, `unset 'a[$(git push origin main)]'`,
    // only the ${! clause sees this one (git is data; its argument holds no $( )
    `x='a[$(cd ~/api && git push origin main)]'; git log "\${!x}"`,
    // only the -n clause sees this one (the nameref's own argument holds no $( )
    `declare -n r=x; x='a[$(cd ~/api && git push origin main)]'; echo "$r"`]) {
    assert.ok(unknownRow(c), c);
  }
  // plain values stay data
  for (const c of [`declare -i w=3; echo 'git push origin main'`, `cd sub && echo 'git push origin main'`,
    `export X=1; echo 'git push origin main'`, `export X="$(git rev-parse HEAD)"; git push origin t/12-x`]) {
    assert.equal(r35Row(c), undefined, c);
  }
  // an export whose value runs a substitution is not a plain value (R35a), so it is non-data beside a loose mention
  assert.ok(unknownRow(`export X="$(git rev-parse HEAD)"; echo 'git push later'`));
});
test('R35b: a git call that runs text is non-data and does not account for that text', () => {
  for (const c of [`git rebase -x 'git push origin main' main`, `git rebase -ix 'git push origin main' main`,
    `git rebase --exec='git push origin main' main`, `git rebase --exec 'git push origin main' main`,
    `git submodule foreach 'git push origin main'`, `GIT_SSH_COMMAND='sh -c "cd ~/api && git push origin main"' git fetch origin`,
    `GIT_EDITOR='git push origin main;' git commit`, `git -c core.sshCommand='sh -c "git push origin main"' fetch origin`,
    `git -c core.pager='git push origin main' log`, `git --config-env=core.editor=E commit; E='git push origin main'`,
    `git bisect run sh -c 'git push origin main'`, `git filter-branch --tree-filter 'git push origin main' HEAD`,
    `export GIT_SSH_COMMAND='sh -c "git push origin main"'; git fetch origin`]) {
    assert.ok(unknownRow(c), c);
  }
  // no guarded mention: still nothing; a non-running -c key is data
  for (const c of [`git rebase -x 'npm test' main`, `git submodule foreach 'git status'`, `git -c color.ui=never log --grep push`,
    `GIT_AUTHOR_NAME=bot git commit -m 'git push docs'`]) {
    assert.equal(r35Row(c), undefined, c);
  }
});
