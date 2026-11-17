#!/bin/bash
# claim: create-only atomic claim of t/<n>-<slug>; loser learns who holds it; checkout untouched.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAIM="$DIR/../../bin/claim"
[ -x "$CLAIM" ] || { echo "FAIL: bin/claim missing or not executable"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/a" 2>/dev/null
echo x > "$TMP/a/f"; g -C "$TMP/a" add f; g -C "$TMP/a" commit -qm init; g -C "$TMP/a" push -q origin main
g clone -q "$TMP/origin.git" "$TMP/b" 2>/dev/null
mkdir -p "$TMP/ca/.orchestrator" "$TMP/cb/.orchestrator"
echo aaaaaaaaaaaaaaaa > "$TMP/ca/.orchestrator/lease"
echo bbbbbbbbbbbbbbbb > "$TMP/cb/.orchestrator/lease"
MAIN=$(git -C "$TMP/a" rev-parse origin/main)
HEAD_A=$(git -C "$TMP/a" rev-parse HEAD); ST_A=$(git -C "$TMP/a" status --porcelain)

# win
OUT=$("$CLAIM" 41 rate-limit --repo-dir "$TMP/a" --base main --core-dir "$TMP/ca")
[ "$(jq -r .result <<<"$OUT")" = claimed ] || { echo "FAIL: first claim: $OUT"; exit 1; }
SHA=$(jq -r .sha <<<"$OUT")
[ "$(git -C "$TMP/a" ls-remote origin refs/heads/t/41-rate-limit | cut -f1)" = "$SHA" ] || { echo "FAIL: remote ref != sha"; exit 1; }
[ "$(git -C "$TMP/a" rev-parse "$SHA^")" = "$MAIN" ] || { echo "FAIL: claim parent is not main tip"; exit 1; }
git -C "$TMP/a" log -1 --format=%B "$SHA" | grep -q '^Claim-Issue: 41$' || { echo "FAIL: Claim-Issue trailer"; exit 1; }

# lose, and learn the holder
set +e; OUT=$("$CLAIM" 41 rate-limit --repo-dir "$TMP/b" --base main --core-dir "$TMP/cb"); rc=$?; set -e
[ "$rc" -eq 3 ] || { echo "FAIL: second claim exit $rc, want 3: $OUT"; exit 1; }
[ "$(jq -r .result <<<"$OUT")" = lost ] || { echo "FAIL: second claim result: $OUT"; exit 1; }
[ "$(jq -r .heldBy.lease <<<"$OUT")" = aaaaaaaaaaaaaaaa ] || { echo "FAIL: heldBy.lease: $OUT"; exit 1; }
[ "$(jq -r .heldBy.machine <<<"$OUT")" = "$(hostname)" ] || { echo "FAIL: heldBy.machine: $OUT"; exit 1; }
# lostAt tells a sequential loss (seen at the ls-remote pre-check) from a loss at the create-only push
[ "$(jq -r .lostAt <<<"$OUT")" = precheck ] || { echo "FAIL: existing branch should be lostAt precheck: $OUT"; exit 1; }

# Review Focus 3: a branch already at the base tip
g -C "$TMP/b" push -q origin main:refs/heads/t/42-x
set +e; OUT=$("$CLAIM" 42 x --repo-dir "$TMP/a" --base main --core-dir "$TMP/ca"); rc=$?; set -e
[ "$rc" -eq 3 ] || { echo "FAIL: claim over base-tip branch exit $rc, want 3: $OUT"; exit 1; }
[ "$(jq -r .heldBy.lease <<<"$OUT")" = unknown ] || { echo "FAIL: heldBy should be unknown: $OUT"; exit 1; }
[ "$(jq -r .lostAt <<<"$OUT")" = precheck ] || { echo "FAIL: base-tip branch should be lostAt precheck: $OUT"; exit 1; }
# positive control: a plain push of a fresh claim-shaped commit fast-forwards and "succeeds"
C=$(git -C "$TMP/b" commit-tree "$MAIN^{tree}" -p "$MAIN" -m probe)
git -C "$TMP/b" push -q origin "$C:refs/heads/t/42-x" || { echo "FAIL: control: plain push should succeed (gap not reproduced)"; exit 1; }

# Same machine + same lease token + same second would build a byte-identical claim commit; the
# second push is then "[up to date]" and both callers think they won (measured). A random
# Claim-Nonce makes every claim commit unique. Two claims cannot be forced into one second from
# outside, so assert the cause (nonce present and distinct) AND run the race repeatedly with
# processes sharing one repo dir, requiring every loser to exit exactly 3.
N1=$(git -C "$TMP/a" log -1 --format=%B "$SHA" | sed -n 's/^Claim-Nonce: //p')
[[ "$N1" =~ ^[0-9a-f]{16}$ ]] || { echo "FAIL: Claim-Nonce missing or malformed: '$N1'"; exit 1; }
OUT=$("$CLAIM" 46 other --repo-dir "$TMP/a" --base main --core-dir "$TMP/ca")
N2=$(git -C "$TMP/a" log -1 --format=%B "$(jq -r .sha <<<"$OUT")" | sed -n 's/^Claim-Nonce: //p')
[ "$N1" != "$N2" ] || { echo "FAIL: nonces repeat"; exit 1; }

PUSHLOSS=0
# concurrency: exactly one of 8 wins, 7 lose cleanly with exit 3; three rounds per attempt. Every round is checked
# strictly; only the "some loser reached the push" timing condition is retried, up to 3 attempts on fresh issue numbers.
ATTEMPTS=3
for attempt in $(seq 1 "$ATTEMPTS"); do
  for round in 1 2 3; do
    N=$((attempt * 1000 + round * 100 + 43))
    rm -f "$TMP"/race.*
    for i in 1 2 3 4 5 6 7 8; do
      if [ $((i % 2)) -eq 0 ]; then r=a; c=ca; else r=b; c=cb; fi
      ( set +e; "$CLAIM" "$N" "race$round" --repo-dir "$TMP/$r" --base main --core-dir "$TMP/$c" > "$TMP/race.$i.out" 2>/dev/null; echo $? > "$TMP/race.$i.rc" ) &
    done
    wait
    WIN=$(cat "$TMP"/race.*.rc | grep -c "^0$" || true); LOSE=$(cat "$TMP"/race.*.rc | grep -c "^3$" || true)
    [ "$WIN" -eq 1 ] && [ "$LOSE" -eq 7 ] || { echo "FAIL: race $attempt.$round win=$WIN lose=$LOSE (rcs: $(cat "$TMP"/race.*.rc | tr '\n' ' '))"; exit 1; }
    # every loser says where it lost: one of the two exits (shape); push losers are counted, not required per round (timing)
    for f in "$TMP"/race.*.rc; do
      [ "$(cat "$f")" = 3 ] || continue
      LA=$(jq -r .lostAt "${f%.rc}.out")
      [ "$LA" = precheck ] || [ "$LA" = push ] || { echo "FAIL: race $attempt.$round loser lostAt '$LA' in $(cat "${f%.rc}.out")"; exit 1; }
      [ "$LA" = push ] && PUSHLOSS=$((PUSHLOSS + 1))
    done
    WSHA=$(jq -r .sha "$(grep -l '^0$' "$TMP"/race.*.rc | sed 's/\.rc$/.out/')")
    [ "$(git -C "$TMP/a" ls-remote origin "refs/heads/t/$N-race$round" | cut -f1)" = "$WSHA" ] || { echo "FAIL: race $attempt.$round remote sha != winner"; exit 1; }
  done
  echo "info: attempt $attempt: losers that reached the push (lostAt=push) so far: $PUSHLOSS" >&2
  [ "$PUSHLOSS" -ge 1 ] && break
done

[ "$PUSHLOSS" -ge 1 ] || { echo "FAIL: no loser reached the create-only push in $ATTEMPTS attempts of 3 eight-way races (lostAt=push never seen)"; exit 1; }

# bad slug
set +e; "$CLAIM" 44 Bad_Slug --repo-dir "$TMP/a" --base main >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: bad slug exit $rc, want 2"; exit 1; }

# checkout untouched
[ "$(git -C "$TMP/a" rev-parse HEAD)" = "$HEAD_A" ] || { echo "FAIL: HEAD moved"; exit 1; }
[ "$(git -C "$TMP/a" status --porcelain)" = "$ST_A" ] || { echo "FAIL: working tree changed"; exit 1; }

# Important 7: leading zeros rejected; a second slug for the same issue loses
set +e; "$CLAIM" 052 x --repo-dir "$TMP/a" --base main >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: leading-zero issue exit $rc, want 2"; exit 1; }
"$CLAIM" 52 x --repo-dir "$TMP/a" --base main >/dev/null
set +e; OUT=$("$CLAIM" 52 y --repo-dir "$TMP/b" --base main); rc=$?; set -e
[ "$rc" -eq 3 ] || { echo "FAIL: second slug for issue 52 exit $rc, want 3: $OUT"; exit 1; }

# Important 8: an option-shaped --base must be refused before it reaches git
set +e; "$CLAIM" 53 inj --repo-dir "$TMP/a" --base '--upload-pack=touch PWNED;git-upload-pack' >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: injected base exit $rc, want 2"; exit 1; }
[ ! -e "$TMP/a/PWNED" ] && [ ! -e PWNED ] || { echo "FAIL: --base executed a command"; exit 1; }

# Important 9: no git identity configured (a CI runner's default) still claims with JSON, exit 0
set +e
OUT=$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  HOME="$TMP/nohome" GIT_CONFIG_GLOBAL="$TMP/nohome/none" GIT_CONFIG_NOSYSTEM=1 \
  "$CLAIM" 54 noid --repo-dir "$TMP/a" --base main 2>/dev/null); rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$(jq -r .result <<<"$OUT")" = claimed ] || { echo "FAIL: no-identity claim exit $rc: $OUT"; exit 1; }

# Important 3: a server-side refusal with no ref on origin is a failure (1), not "lost" (3)
g init -q --bare "$TMP/hooked.git"
printf '#!/bin/sh\nexit 1\n' > "$TMP/hooked.git/hooks/pre-receive"; chmod +x "$TMP/hooked.git/hooks/pre-receive"
g clone -q "$TMP/origin.git" "$TMP/h" 2>/dev/null; g -C "$TMP/h" remote set-url origin "$TMP/hooked.git"
g -C "$TMP/h" push -q --no-verify "$TMP/hooked.git" main 2>/dev/null || { rm "$TMP/hooked.git/hooks/pre-receive"; g -C "$TMP/h" push -q origin main; printf '#!/bin/sh\nexit 1\n' > "$TMP/hooked.git/hooks/pre-receive"; chmod +x "$TMP/hooked.git/hooks/pre-receive"; }
set +e; OUT=$("$CLAIM" 55 refused --repo-dir "$TMP/h" --base main 2>/dev/null); rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: server refusal exit $rc, want 1: $OUT"; exit 1; }
echo ok
