import { fetchAll } from './agp.js';
import db, { upsertTrack, upsertRacer, insertSnapshot } from './db.js';

/**
 * Pull every race from the AGP API into our DB.
 * Live races also get a snapshot row so we can chart progress over time.
 */
export async function sync() {
  const now = new Date().toISOString();
  const details = await fetchAll();

  const run = db.transaction((details) => {
    for (const d of details) {
      const t = d.track;

      upsertTrack.run({
        id: t.id,
        name: t.name,
        difficulty: t.difficulty,
        point_count: t.pointCount,
        starts_at: t.startsAt,
        started: t.started ? 1 : 0,
        over: t.over ? 1 : 0,
        racer_count: t.racerCount,
        winner_login: t.winnerLogin,
        question_cost: t.questionCostUsd,
        guess_cost: t.guessCostUsd,
        max_racers: t.maxRacers,
        created_at: t.createdAt,
        now
      });

      for (const r of d.racers) {
        const row = {
          track_id: t.id,
          login: r.login,
          idx: r.idx,
          point_count: r.pointCount,
          finished: r.finished ? 1 : 0,
          duration_ms: r.durationMs,
          questions_asked: r.questionsAsked,
          guess_count: r.guessCount,
          now
        };
        upsertRacer.run(row);

        // only snapshot live races — finished ones never change
        if (!t.over) insertSnapshot.run(row);
      }
    }
  });

  run(details);

  const live = details.filter(d => !d.track.over).length;
  console.log(`[sync] ${details.length} races (${live} live) @ ${now}`);
  return { races: details.length, live, at: now };
}
