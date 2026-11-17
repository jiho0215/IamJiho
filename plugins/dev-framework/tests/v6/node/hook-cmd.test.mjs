import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { parseCommand } = require('../../../lib/hook-cmd.js');
const here = dirname(fileURLToPath(import.meta.url));

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
  assert.equal(f('git push --mirror origin').force, true);
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
test('F8: env -C/--chdir/-S are opaque; sudo -u consumes its value', () => {
  assert.equal(parseCommand('env -C ../api git push').opaque.length, 1);
  assert.equal(parseCommand('env --chdir=../api git push').opaque.length, 1);
  assert.equal(parseCommand("env -S 'git push'").opaque.length, 1);
  assert.deepEqual(parseCommand('sudo -u bob git push origin x'), r({ pushes: [push({ remote: 'origin', refspecs: ['x'] })] }));
});
test('F11: gh -R x pr merge; git --no-pager push', () => {
  assert.deepEqual(parseCommand('gh -R acme/api pr merge 12 --auto'), r({ merges: [merge({ pr: 12, repo: 'acme/api', auto: true })] }));
  assert.deepEqual(parseCommand('git --no-pager push origin t/41-x'), r({ pushes: [push({ remote: 'origin', refspecs: ['t/41-x'] })] }));
});

test('bin/hook-parse prints parseCommand as JSON', () => {
  const out = execFileSync(process.execPath, [join(here, '../../../bin/hook-parse')],
    { input: 'git -C ../api push origin t/41-x', encoding: 'utf8' });
  assert.deepEqual(JSON.parse(out), r({ pushes: [push({ dir: '../api', remote: 'origin', refspecs: ['t/41-x'] })] }));
});
