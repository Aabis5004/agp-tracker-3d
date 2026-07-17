import { getTracks, getAllRacers, getRacers, getTrack } from './db.js';

const cost = (r, t) =>
  r.questions_asked * (t.question_cost || 0) + r.guess_count * (t.guess_cost || 0);

/**
 * Classify how a racer plays, based on guess-to-question ratio.
 * Guesses cost 5x a question — a high ratio means paying to skip the thinking.
 */
export function playstyle(p) {
  if (!p.active) return { key: 'ghost', label: 'Ghost', note: 'registers, never races' };
  if (p.questions < 5 && p.guesses > 10) return { key: 'spammer', label: 'Spammer', note: 'guesses blind' };
  if (p.gq === null) return { key: 'unknown', label: '—', note: '' };
  if (p.gq >= 2.5) return { key: 'guesser', label: 'Guesser', note: 'brute-forces guesses' };
  if (p.gq <= 0.5) return { key: 'asker', label: 'Asker', note: 'narrows before guessing' };
  return { key: 'balanced', label: 'Balanced', note: 'mixes both' };
}

function buildPlayers() {
  const tracks = getTracks.all();
  const byId = Object.fromEntries(tracks.map(t => [t.id, t]));
  const players = {};

  for (const r of getAllRacers.all()) {
    const t = byId[r.track_id];
    if (!t) continue;
    const p = players[r.login] ||= {
      login: r.login, races: 0, wins: 0, points: 0,
      questions: 0, guesses: 0, spend: 0, active: 0,
      bestTimeMs: null
    };
    p.races++;
    p.points += r.idx;
    p.questions += r.questions_asked;
    p.guesses += r.guess_count;
    p.spend += cost(r, t);
    if (r.finished) {
      p.wins++;
      if (!p.bestTimeMs || r.duration_ms < p.bestTimeMs) p.bestTimeMs = r.duration_ms;
    }
    if (r.questions_asked || r.guess_count) p.active++;
  }

  return Object.values(players).map(p => {
    const gq = p.questions ? +(p.guesses / p.questions).toFixed(2) : null;
    const out = {
      ...p,
      gq,
      spend: +p.spend.toFixed(3),
      costPerWin: p.wins ? +(p.spend / p.wins).toFixed(3) : null,
      winRate: p.races ? +(p.wins / p.races * 100).toFixed(0) : 0,
      spendPerRace: p.races ? +(p.spend / p.races).toFixed(3) : 0
    };
    out.style = playstyle(out);
    return out;
  });
}

export function overview() {
  const tracks = getTracks.all();
  const players = buildPlayers();
  const byId = Object.fromEntries(tracks.map(t => [t.id, t]));

  let entries = 0, ghosts = 0, finishers = 0, questions = 0, guesses = 0;
  let spend = 0, guessSpend = 0;

  for (const r of getAllRacers.all()) {
    const t = byId[r.track_id];
    if (!t) continue;
    entries++;
    questions += r.questions_asked;
    guesses += r.guess_count;
    spend += cost(r, t);
    guessSpend += r.guess_count * (t.guess_cost || 0);
    if (!r.questions_asked && !r.guess_count) ghosts++;
    if (r.finished) finishers++;
  }

  return {
    races: tracks.length,
    entries,
    uniquePlayers: players.length,
    ghosts,
    participationPct: entries ? Math.round((entries - ghosts) / entries * 100) : 0,
    finishers,
    questions,
    guesses,
    spend: +spend.toFixed(3),
    guessSpendPct: spend ? Math.round(guessSpend / spend * 100) : 0
  };
}

/** All-time standings — ranked by wins, then points, then cost per win */
export function standings() {
  return buildPlayers().sort((a, b) =>
    b.wins - a.wins ||
    b.points - a.points ||
    (a.costPerWin ?? 1e9) - (b.costPerWin ?? 1e9) ||
    a.spend - b.spend
  );
}

/** Scatter points: every real attempt, for the questions-vs-time frontier */
export function pareto() {
  const tracks = getTracks.all();
  const byId = Object.fromEntries(tracks.map(t => [t.id, t]));
  const pts = [];

  for (const r of getAllRacers.all()) {
    const t = byId[r.track_id];
    if (!t) continue;
    if (!r.questions_asked && !r.guess_count) continue;
    pts.push({
      login: r.login,
      race: t.name,
      questions: r.questions_asked,
      guesses: r.guess_count,
      timeMs: r.duration_ms,
      spend: +cost(r, t).toFixed(3),
      finished: !!r.finished,
      points: r.idx,
      pointCount: t.point_count
    });
  }
  return pts;
}

export function races() {
  return getTracks.all().map(t => {
    const rs = getRacers.all(t.id);
    const active = rs.filter(r => r.questions_asked || r.guess_count).length;
    const spend = rs.reduce((s, r) => s + cost(r, t), 0);
    return {
      id: t.id,
      name: t.name,
      difficulty: t.difficulty,
      startsAt: t.starts_at,
      over: !!t.over,
      started: !!t.started,
      grid: t.racer_count,
      active,
      participationPct: rs.length ? Math.round(active / rs.length * 100) : 0,
      winner: t.winner_login,
      pointCount: t.point_count,
      spend: +spend.toFixed(3)
    };
  });
}

export function raceDetail(id) {
  const t = getTrack.get(id);
  if (!t) return null;
  const rs = getRacers.all(id)
    .map(r => ({
      login: r.login,
      points: r.idx,
      finished: !!r.finished,
      questions: r.questions_asked,
      guesses: r.guess_count,
      gq: r.questions_asked ? +(r.guess_count / r.questions_asked).toFixed(2) : null,
      spend: +cost(r, t).toFixed(3),
      durationMs: r.duration_ms,
      idle: !r.questions_asked && !r.guess_count
    }))
    .sort((a, b) =>
      b.finished - a.finished || b.points - a.points || a.durationMs - b.durationMs
    );
  return { track: { ...t, over: !!t.over, started: !!t.started }, racers: rs };
}

/** Style breakdown: does asking or guessing actually win? */
export function styleBreakdown() {
  const s = standings().filter(p => p.active);
  const groups = {};
  for (const p of s) {
    const k = p.style.key;
    const g = groups[k] ||= {
      key: k, label: p.style.label, note: p.style.note,
      players: 0, wins: 0, races: 0, spend: 0
    };
    g.players++;
    g.wins += p.wins;
    g.races += p.races;
    g.spend += p.spend;
  }
  return Object.values(groups).map(g => ({
    ...g,
    spend: +g.spend.toFixed(2),
    winRate: g.races ? +(g.wins / g.races * 100).toFixed(0) : 0
  })).sort((a, b) => b.wins - a.wins);
}

/** Auto-written takeaways */
export function insights() {
  const o = overview();
  const s = standings();
  const out = [];

  // headline: opposite strategies, same podium
  const winners = s.filter(p => p.wins > 0 && p.gq !== null);
  if (winners.length >= 2) {
    const asker = [...winners].sort((a, b) => a.gq - b.gq)[0];
    const guesser = [...winners].sort((a, b) => b.gq - a.gq)[0];
    if (asker.login !== guesser.login && guesser.gq >= asker.gq * 2) {
      out.push({
        tag: 'the split',
        text: `Two ways to win. ${asker.login} asks — ${asker.gq} guesses per question, ${asker.wins} wins. ${guesser.login} guesses — ${guesser.gq} per question, ${guesser.wins} wins. Same podium, opposite strategy.`
      });
    }
  }

  const cheapest = winners.filter(p => p.costPerWin).sort((a, b) => a.costPerWin - b.costPerWin)[0];
  if (cheapest) {
    out.push({
      tag: 'efficiency',
      text: `${cheapest.login} wins cheapest — $${cheapest.costPerWin.toFixed(2)} per win across ${cheapest.races} races.`
    });
  }

  const burned = s.filter(p => !p.wins && p.spend > 0).sort((a, b) => b.spend - a.spend)[0];
  if (burned) {
    out.push({
      tag: 'burned',
      text: `${burned.login} spent $${burned.spend.toFixed(2)} over ${burned.races} races for zero wins — most money lost on the grid.`
    });
  }

  if (o.guessSpendPct >= 40) {
    out.push({
      tag: 'where the money goes',
      text: `${o.guessSpendPct}% of all spend is guesses, not questions. The field pays 5× to skip the thinking.`
    });
  }

  if (o.ghosts) {
    const serial = s.filter(p => !p.active && p.races >= 3).length;
    out.push({
      tag: 'ghosts',
      text: `${100 - o.participationPct}% of entries never ask a single question — ${o.ghosts} of ${o.entries}.` +
            (serial ? ` ${serial} racers have entered 3+ times and never played once.` : '')
    });
  }

  return out;
}

/** Every race a given racer has entered, newest first */
export function racerHistory(login) {
  const tracks = getTracks.all();
  const byId = Object.fromEntries(tracks.map(t => [t.id, t]));
  const out = [];
  for (const r of getAllRacers.all()) {
    if (r.login !== login) continue;
    const t = byId[r.track_id];
    if (!t) continue;
    out.push({
      race: t.name,
      raceId: t.id,
      date: t.starts_at,
      difficulty: t.difficulty,
      points: r.idx,
      pointCount: t.point_count,
      finished: !!r.finished,
      questions: r.questions_asked,
      guesses: r.guess_count,
      gq: r.questions_asked ? +(r.guess_count / r.questions_asked).toFixed(2) : null,
      spend: +cost(r, t).toFixed(3),
      won: t.winner_login === login
    });
  }
  return out.sort((a, b) => new Date(b.date) - new Date(a.date));
}

/** Full profile for one racer: totals + history */
export function racerProfile(login) {
  const p = standings().find(x => x.login === login);
  if (!p) return null;
  const history = racerHistory(login);
  const qSpend = history.reduce((s, h) => s + h.questions * 0.001, 0);
  return {
    ...p,
    history,
    firstSeen: history.length ? history[history.length - 1].date : null,
    lastSeen: history.length ? history[0].date : null,
    questionSpend: +qSpend.toFixed(3),
    guessSpend: +(p.spend - qSpend).toFixed(3),
    // accuracy: points earned per guess made
    accuracy: p.guesses ? +(p.points / p.guesses * 100).toFixed(1) : null,
    bestFinish: history.find(h => h.finished) || null
  };
}
