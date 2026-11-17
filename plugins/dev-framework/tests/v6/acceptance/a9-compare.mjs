// Pure comparison of two machines' a9 race outputs (JSON lines). No network, no sandbox access.
// A round counts as a real race only when the loser lost at the create-only PUSH (lostAt "push") AND the ref it lost to
// is held by the other machine (heldBy = the winner's hostname). A loser that saw the winner's ref at the ls-remote
// pre-check ("precheck") ran after the winner finished, and a loser that saw a third machine's ref lost to a leftover:
// neither proves anything about atomicity.
// The two files must describe the SAME attempt: per round, the same issue and the same branch; otherwise ERROR.
export const MIN_RACED = 3;

// -> { rows: Map(round -> line), dup: round | null }
function parse(text) {
  const rows = new Map(); let dup = null;
  for (const l of String(text).split('\n')) {
    const t = l.trim();
    if (!t.startsWith('{')) continue;
    let j; try { j = JSON.parse(t); } catch { continue; }
    if (!Number.isInteger(j.round) || typeof j.result !== 'string') continue;
    if (rows.has(j.round) && dup === null) dup = j.round;
    rows.set(j.round, j);
  }
  return { rows, dup };
}

const error = (why) => ({ verdict: 'ERROR', lines: [], summary: { verdict: 'ERROR', error: why } });

export function compareRuns(textA, textB) {
  const pa = parse(textA), pb = parse(textB);
  const A = pa.rows, B = pb.rows;
  const hostsA = new Set([...A.values()].map((r) => r.machine)), hostsB = new Set([...B.values()].map((r) => r.machine));
  const sameHost = [...hostsA].some((h) => hostsB.has(h));
  if (!A.size || !B.size) return error('a file has no round lines');
  if (sameHost) return error(`both files come from the same hostname (${[...hostsA].join(',')}); the winner cannot be told apart`);
  for (const [side, p] of [['first', pa], ['second', pb]]) {
    if (p.dup !== null) return error(`round ${p.dup} appears more than once in the ${side} file; one file must hold one attempt`);
  }
  const rounds = [...new Set([...A.keys(), ...B.keys()])].sort((x, y) => x - y);
  for (const k of rounds) {
    const a = A.get(k), b = B.get(k);
    if (!a || !b) continue;                               // a missing round is FAILED below, not ERROR
    if (a.issue !== b.issue) return error(`round ${k}: the files name different issues (${a.issue} vs ${b.issue}); not the same attempt`);
    if (a.branch !== b.branch) return error(`round ${k}: the files name different branches (${a.branch} vs ${b.branch}); not the same attempt`);
  }
  const lines = []; const skews = []; let raced = 0; let failed = null;
  for (const k of rounds) {
    const a = A.get(k), b = B.get(k);
    const winners = [a, b].filter((r) => r && r.result === 'claimed');
    const loser = [a, b].find((r) => r && r.result === 'lost');
    const skewMs = a && b && Number.isFinite(a.startedAt) && Number.isFinite(b.startedAt) ? Math.abs(a.startedAt - b.startedAt) : null;
    if (skewMs !== null) skews.push(skewMs);
    const ok = winners.length === 1 && !!loser;
    const isRaced = ok && loser.lostAt === 'push' && loser.heldBy === winners[0].machine;
    if (isRaced) raced++;
    if (!ok && !failed) {
      failed = winners.length > 1 ? `round ${k}: two winners`
        : winners.length === 0 ? `round ${k}: no winner (both machines lost; the issue range was probably reused, so the ref already existed: rerun on a fresh range)`
          : `round ${k}: one winner and no clean loser (an error or a missing round)`;
    }
    lines.push({ round: k, winner: winners.length === 1 ? winners[0].machine : null, winners: winners.length, skewMs, raced: isRaced });
  }
  const verdict = failed ? 'FAILED' : raced >= MIN_RACED ? 'VERIFIED' : 'INCONCLUSIVE';
  const summary = { verdict, rounds: rounds.length, raced, needRaced: MIN_RACED, maxSkewMs: skews.length ? Math.max(...skews) : null, skewsMs: skews };
  if (failed) summary.reason = failed;
  if (verdict === 'INCONCLUSIVE') summary.note = 'too few rounds reached the create-only push against the other machine; rerun on a fresh issue range with synced clocks (skew above)';
  return { verdict, lines, summary };
}
