// Pure comparison of two machines' a9 race outputs (JSON lines). No network, no sandbox access.
// A round counts as a real race only when the loser lost at the create-only PUSH (lostAt "push"); a loser that saw the
// winner's ref at the ls-remote pre-check ("precheck") ran after the winner finished, which proves nothing about atomicity.
export const MIN_RACED = 3;

function parse(text) {
  const rows = new Map();
  for (const l of String(text).split('\n')) {
    const t = l.trim();
    if (!t.startsWith('{')) continue;
    let j; try { j = JSON.parse(t); } catch { continue; }
    if (Number.isInteger(j.round) && typeof j.result === 'string') rows.set(j.round, j);
  }
  return rows;
}

export function compareRuns(textA, textB) {
  const A = parse(textA), B = parse(textB);
  const hostsA = new Set([...A.values()].map((r) => r.machine)), hostsB = new Set([...B.values()].map((r) => r.machine));
  const sameHost = [...hostsA].some((h) => hostsB.has(h));
  if (!A.size || !B.size || sameHost) {
    const why = !A.size || !B.size ? 'a file has no round lines' : `both files come from the same hostname (${[...hostsA].join(',')}); the winner cannot be told apart`;
    return { verdict: 'ERROR', lines: [], summary: { verdict: 'ERROR', error: why } };
  }
  const rounds = [...new Set([...A.keys(), ...B.keys()])].sort((x, y) => x - y);
  const lines = []; const skews = []; let raced = 0; let failed = null;
  for (const k of rounds) {
    const a = A.get(k), b = B.get(k);
    const winners = [a, b].filter((r) => r && r.result === 'claimed');
    const loser = [a, b].find((r) => r && r.result === 'lost');
    const skewMs = a && b && Number.isFinite(a.startedAt) && Number.isFinite(b.startedAt) ? Math.abs(a.startedAt - b.startedAt) : null;
    if (skewMs !== null) skews.push(skewMs);
    const ok = winners.length === 1 && !!loser;
    const isRaced = ok && loser.lostAt === 'push';
    if (isRaced) raced++;
    if (!ok && !failed) failed = winners.length > 1 ? `round ${k}: two winners` : `round ${k}: ${winners.length} winners and ${loser ? 'a loser' : 'no clean loser'} (an error or a missing round)`;
    lines.push({ round: k, winner: winners.length === 1 ? winners[0].machine : null, winners: winners.length, skewMs, raced: isRaced });
  }
  const verdict = failed ? 'FAILED' : raced >= MIN_RACED ? 'VERIFIED' : 'INCONCLUSIVE';
  const summary = { verdict, rounds: rounds.length, raced, needRaced: MIN_RACED, maxSkewMs: skews.length ? Math.max(...skews) : null, skewsMs: skews };
  if (failed) summary.reason = failed;
  if (verdict === 'INCONCLUSIVE') summary.note = 'too few rounds reached the create-only push; rerun on a fresh issue range with synced clocks (skew above)';
  return { verdict, lines, summary };
}
