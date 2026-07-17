#!/usr/bin/env bash
# AGP Tracker v2 — fixes efficiency metric, adds avatars, Pareto chart, playstyles
# Run from inside ~/agp-tracker :  bash update-tracker.sh
set -e
[ -f package.json ] || { echo "!! run this from inside ~/agp-tracker"; exit 1; }
echo "→ writing src/stats.js"
cat > src/stats.js << 'STATS_EOF'
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
STATS_EOF

echo "→ writing src/server.js"
cat > src/server.js << 'SERVER_EOF'
import express from 'express';
import cron from 'node-cron';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { sync } from './sync.js';
import { overview, standings, races, raceDetail, insights, pareto, styleBreakdown } from './stats.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.static(join(__dirname, '..', 'public')));

// ---- API ----
app.get('/api/overview', (req, res) => res.json(overview()));
app.get('/api/standings', (req, res) => res.json(standings()));
app.get('/api/races', (req, res) => res.json(races()));
app.get('/api/insights', (req, res) => res.json(insights()));
app.get('/api/pareto', (req, res) => res.json(pareto()));
app.get('/api/styles', (req, res) => res.json(styleBreakdown()));

app.get('/api/races/:id', (req, res) => {
  const d = raceDetail(req.params.id);
  if (!d) return res.status(404).json({ error: 'race not found' });
  res.json(d);
});

// everything in one call — what the dashboard uses
app.get('/api/all', (req, res) => {
  res.json({
    overview: overview(),
    standings: standings(),
    races: races(),
    insights: insights(),
    pareto: pareto(),
    styles: styleBreakdown()
  });
});

app.post('/api/sync', async (req, res) => {
  try {
    res.json(await sync());
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/health', (req, res) => res.json({ ok: true, at: new Date().toISOString() }));

// ---- boot ----
async function boot() {
  console.log('[boot] first sync…');
  try {
    await sync();
  } catch (e) {
    console.error('[boot] sync failed:', e.message);
  }

  // every 2 minutes — catches live races
  cron.schedule('*/2 * * * *', async () => {
    try {
      await sync();
    } catch (e) {
      console.error('[cron] sync failed:', e.message);
    }
  });

  app.listen(PORT, () => {
    console.log(`[boot] http://localhost:${PORT}`);
  });
}

boot();
SERVER_EOF

echo "→ writing public/index.html"
cat > public/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AGP Tracker — unofficial Agent Grand Prix stats</title>
<meta name="description" content="Independent community stats for Agent Grand Prix. Participation, playstyles, the Pareto frontier.">
<style>
  :root{
    --bg:#0a0c10; --panel:#12161d; --panel2:#171c25; --line:#232a35;
    --text:#e8ecf1; --dim:#8b95a5; --acid:#c3f53c; --blue:#4a9eff;
    --red:#ff5c5c; --amber:#ffb340; --violet:#a78bfa;
    --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--text);font-family:var(--mono);font-size:14px;line-height:1.5;padding:24px 16px}
  .wrap{max-width:1080px;margin:0 auto}
  header{border-bottom:1px solid var(--line);padding-bottom:18px;margin-bottom:22px;display:flex;justify-content:space-between;align-items:flex-end;gap:16px;flex-wrap:wrap}
  h1{font-size:24px;font-weight:700;letter-spacing:-0.5px}
  h1 span{color:var(--acid)}
  .badge{display:inline-block;font-size:9px;padding:2px 6px;border:1px solid var(--line);border-radius:99px;color:var(--dim);margin-left:6px;vertical-align:middle;letter-spacing:0.5px}
  .sub{color:var(--dim);font-size:11px;margin-top:5px}
  .sync{font-size:10px;color:var(--dim)}
  .sync b{color:var(--acid)}
  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(132px,1fr));gap:10px;margin-bottom:22px}
  .stat{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:13px}
  .stat .k{font-size:9px;color:var(--dim);text-transform:uppercase;letter-spacing:1px}
  .stat .v{font-size:22px;font-weight:700;margin-top:3px}
  .stat .n{font-size:9px;color:var(--dim);margin-top:1px}
  section{margin-bottom:26px}
  h2{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:10px}
  table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
  th{text-align:left;font-size:9px;color:var(--dim);text-transform:uppercase;letter-spacing:1px;padding:9px 11px;border-bottom:1px solid var(--line);font-weight:500}
  td{padding:9px 11px;border-bottom:1px solid var(--line);font-size:12.5px;vertical-align:middle}
  tr:last-child td{border-bottom:none}
  tbody tr:hover td{background:var(--panel2)}
  .num{text-align:right;font-variant-numeric:tabular-nums}
  .win{color:var(--acid);font-weight:700}
  .dim{color:var(--dim)}
  .ghost{color:var(--red);font-size:10px}
  .who{display:flex;align-items:center;gap:7px}
  .who img{width:20px;height:20px;border-radius:50%;background:var(--panel2);flex:none}
  .who a{color:inherit;text-decoration:none}
  .who a:hover{color:var(--blue)}
  .tag{font-size:9px;padding:1px 5px;border-radius:4px;border:1px solid;white-space:nowrap}
  .t-asker{color:var(--acid);border-color:#3f5216}
  .t-guesser{color:var(--amber);border-color:#5c4213}
  .t-balanced{color:var(--blue);border-color:#1c3c60}
  .t-ghost{color:var(--red);border-color:#5c1f1f}
  .t-spammer{color:var(--violet);border-color:#43307a}
  .pill{font-size:9px;padding:1px 5px;border-radius:4px;background:var(--panel2);border:1px solid var(--line);color:var(--dim)}
  .pill.live{color:var(--acid);border-color:var(--acid)}
  .bar{height:4px;background:var(--panel2);border-radius:2px;overflow:hidden;width:40px}
  .bar i{display:block;height:100%;background:var(--acid)}
  select{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:7px 10px;font-family:var(--mono);font-size:12px;margin-bottom:10px;width:100%;max-width:300px}
  .loading,.err{padding:40px;text-align:center;color:var(--dim);font-size:12px}
  .err{color:var(--red)}
  .insight{background:var(--panel);border-left:2px solid var(--amber);padding:9px 13px;margin-bottom:7px;font-size:12px;border-radius:0 6px 6px 0}
  .insight .t{font-size:9px;color:var(--amber);text-transform:uppercase;letter-spacing:1px;margin-bottom:2px}
  .chartbox{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px}
  .legend{display:flex;gap:14px;flex-wrap:wrap;font-size:10px;color:var(--dim);margin-top:8px}
  .legend b{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px;vertical-align:-1px}
  .styles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
  .sty{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px}
  .sty .l{font-size:12px;font-weight:700}
  .sty .r{font-size:20px;font-weight:700;margin:4px 0}
  .sty .n{font-size:9px;color:var(--dim)}
  footer{margin-top:30px;padding-top:14px;border-top:1px solid var(--line);color:var(--dim);font-size:10px;line-height:1.7}
  a{color:var(--blue);text-decoration:none}
  a:hover{text-decoration:underline}
  @media(max-width:640px){
    body{padding:14px 10px}
    td,th{padding:8px 6px;font-size:11px}
    .hide-m{display:none}
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>AGP <span>TRACKER</span><span class="badge">unofficial</span></h1>
      <div class="sub">Independent stats for Agent Grand Prix · not affiliated with Subzero Labs</div>
    </div>
    <div class="sync" id="sync"></div>
  </header>
  <div id="app"><div class="loading">loading…</div></div>
  <footer>
    Source: public AGP API · avatars via GitHub ·
    Official site: <a href="https://agp.onlatch.com" target="_blank" rel="noopener">agp.onlatch.com</a> ·
    Latch: <a href="https://onlatch.com" target="_blank" rel="noopener">onlatch.com</a><br>
    Community-built. Numbers computed independently from public race data.
  </footer>
</div>

<script>
const $ = s => document.querySelector(s);
const fmtTime = ms => {
  if(!ms) return '—';
  const s = Math.round(ms/1000);
  return s>3600 ? `${Math.floor(s/3600)}h${Math.floor(s%3600/60)}m` : s>60 ? `${Math.floor(s/60)}m${s%60}s` : `${s}s`;
};
const fmtDate = d => new Date(d).toLocaleDateString('en-US',{month:'short',day:'numeric'});
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

// GitHub avatar — logins are GitHub usernames
const avatar = login => `https://github.com/${encodeURIComponent(login)}.png?size=40`;
const ghUrl  = login => `https://github.com/${encodeURIComponent(login)}`;

const who = login => `<span class="who">
  <img src="${avatar(login)}" alt="" loading="lazy" onerror="this.style.visibility='hidden'">
  <a href="${ghUrl(login)}" target="_blank" rel="noopener">${esc(login)}</a></span>`;

let DATA = null;

async function load(){
  try{
    DATA = await (await fetch('/api/all')).json();
    render();
    $('#sync').innerHTML = `synced <b>${new Date().toLocaleTimeString()}</b>`;
  }catch(e){
    $('#app').innerHTML = `<div class="err">Couldn't load data — is the server running?<br><br>${esc(e.message)}</div>`;
  }
}

function render(){
  const {overview:o, standings:s, races:r, insights:ins, pareto:pts, styles} = DATA;

  let h = `
  <div class="stats">
    <div class="stat"><div class="k">races</div><div class="v">${o.races}</div><div class="n">all time</div></div>
    <div class="stat"><div class="k">entries</div><div class="v">${o.entries}</div><div class="n">${o.uniquePlayers} unique</div></div>
    <div class="stat"><div class="k">real racers</div><div class="v" style="color:var(--acid)">${o.participationPct}%</div><div class="n">${o.ghosts} never asked</div></div>
    <div class="stat"><div class="k">finishers</div><div class="v">${o.finishers}</div><div class="n">crossed the FIN</div></div>
    <div class="stat"><div class="k">questions</div><div class="v">${o.questions.toLocaleString()}</div><div class="n">${o.guesses.toLocaleString()} guesses</div></div>
    <div class="stat"><div class="k">spend</div><div class="v">$${o.spend.toFixed(2)}</div><div class="n">${o.guessSpendPct}% on guesses</div></div>
  </div>`;

  if(ins.length){
    h += `<section><h2>what the numbers say</h2>`;
    ins.forEach(i => h += `<div class="insight"><div class="t">${esc(i.tag)}</div>${esc(i.text)}</div>`);
    h += `</section>`;
  }

  // ---- playstyles ----
  if(styles?.length){
    h += `<section><h2>does asking or guessing win?</h2><div class="styles">`;
    styles.forEach(g=>{
      h += `<div class="sty">
        <div class="l"><span class="tag t-${g.key}">${esc(g.label)}</span></div>
        <div class="r">${g.wins} <span style="font-size:11px;color:var(--dim);font-weight:400">wins</span></div>
        <div class="n">${g.players} racers · ${g.races} entries · ${g.winRate}% win rate</div>
        <div class="n" style="margin-top:3px">${esc(g.note)}</div>
      </div>`;
    });
    h += `</div></section>`;
  }

  // ---- pareto ----
  h += `<section><h2>the frontier · questions vs time</h2>
    <div class="chartbox">
      <svg id="chart" viewBox="0 0 720 320" style="width:100%;height:auto"></svg>
      <div class="legend">
        <span><b style="background:var(--acid)"></b>finished</span>
        <span><b style="background:var(--dim)"></b>didn't finish</span>
        <span style="color:var(--dim)">· bubble size = spend · lower-left = better</span>
      </div>
    </div></section>`;

  // ---- standings ----
  h += `<section><h2>racer standings · all races</h2><table><thead>
    <tr><th>#</th><th>racer</th><th class="hide-m">style</th><th class="num">races</th><th class="num">wins</th>
    <th class="num">pts</th><th class="num">q</th><th class="num hide-m">g</th><th class="num hide-m">g:q</th>
    <th class="num">spend</th><th class="num hide-m">$/win</th></tr></thead><tbody>`;
  s.slice(0,25).forEach((p,i)=>{
    h += `<tr>
      <td class="dim">${i+1}</td>
      <td class="${p.wins?'win':''}">${who(p.login)}</td>
      <td class="hide-m"><span class="tag t-${p.style.key}">${esc(p.style.label)}</span></td>
      <td class="num dim">${p.races}</td>
      <td class="num ${p.wins?'win':'dim'}">${p.wins||'—'}</td>
      <td class="num">${p.points}</td>
      <td class="num">${p.questions||'<span class="ghost">0</span>'}</td>
      <td class="num dim hide-m">${p.guesses}</td>
      <td class="num dim hide-m">${p.gq??'—'}</td>
      <td class="num dim">$${p.spend.toFixed(2)}</td>
      <td class="num hide-m ${p.costPerWin?'win':'dim'}">${p.costPerWin?'$'+p.costPerWin.toFixed(2):'—'}</td>
    </tr>`;
  });
  h += `</tbody></table></section>`;

  // ---- races ----
  h += `<section><h2>every race</h2><table><thead>
    <tr><th>race</th><th class="hide-m">date</th><th class="hide-m">diff</th><th class="num">grid</th>
    <th class="num">real</th><th>winner</th><th class="num">spend</th></tr></thead><tbody>`;
  r.forEach(t=>{
    h += `<tr>
      <td>${esc(t.name)} ${t.over?'<span class="pill">over</span>':'<span class="pill live">live</span>'}</td>
      <td class="dim hide-m">${fmtDate(t.startsAt)}</td>
      <td class="dim hide-m">${esc(t.difficulty)}</td>
      <td class="num">${t.grid}</td>
      <td class="num"><div style="display:flex;align-items:center;gap:5px;justify-content:flex-end">
        <span>${t.active}</span><div class="bar"><i style="width:${t.participationPct}%"></i></div></div></td>
      <td class="win">${t.winner?who(t.winner):'<span class="dim">nobody</span>'}</td>
      <td class="num">$${t.spend.toFixed(2)}</td>
    </tr>`;
  });
  h += `</tbody></table></section>`;

  // ---- detail ----
  h += `<section><h2>race detail</h2>
    <select id="pick">${r.map(t=>`<option value="${t.id}">${esc(t.name)}</option>`).join('')}</select>
    <div id="detail"><div class="loading">…</div></div></section>`;

  $('#app').innerHTML = h;
  $('#pick').onchange = e => showDetail(e.target.value);
  if(r.length) showDetail(r[0].id);
  drawChart(pts||[]);
}

function drawChart(pts){
  const svg = $('#chart');
  if(!svg || !pts.length) return;
  const W=720,H=320,P={t:14,r:14,b:38,l:48};
  const iw=W-P.l-P.r, ih=H-P.t-P.b;

  const maxQ = Math.max(...pts.map(p=>p.questions), 10);
  const maxT = Math.max(...pts.map(p=>p.timeMs/60000), 1);
  const maxS = Math.max(...pts.map(p=>p.spend), 0.01);

  const x = q => P.l + (q/maxQ)*iw;
  const y = t => P.t + ih - (t/maxT)*ih;
  const rad = s => 3 + Math.sqrt(s/maxS)*7;

  let g = '';
  // grid
  for(let i=0;i<=4;i++){
    const gy = P.t + (ih/4)*i;
    const val = (maxT - (maxT/4)*i).toFixed(0);
    g += `<line x1="${P.l}" y1="${gy}" x2="${W-P.r}" y2="${gy}" stroke="#232a35" stroke-width="0.5"/>`;
    g += `<text x="${P.l-7}" y="${gy+3}" text-anchor="end" font-size="9" fill="#8b95a5" font-family="monospace">${val}m</text>`;
  }
  for(let i=0;i<=4;i++){
    const gx = P.l + (iw/4)*i;
    const val = Math.round((maxQ/4)*i);
    g += `<line x1="${gx}" y1="${P.t}" x2="${gx}" y2="${P.t+ih}" stroke="#232a35" stroke-width="0.5"/>`;
    g += `<text x="${gx}" y="${H-20}" text-anchor="middle" font-size="9" fill="#8b95a5" font-family="monospace">${val}</text>`;
  }
  g += `<text x="${P.l+iw/2}" y="${H-5}" text-anchor="middle" font-size="9" fill="#8b95a5" font-family="monospace">questions asked →</text>`;
  g += `<text x="12" y="${P.t+ih/2}" text-anchor="middle" font-size="9" fill="#8b95a5" font-family="monospace" transform="rotate(-90 12 ${P.t+ih/2})">time (min) →</text>`;

  // non-finishers first (behind)
  pts.filter(p=>!p.finished).forEach(p=>{
    g += `<circle cx="${x(p.questions).toFixed(1)}" cy="${y(p.timeMs/60000).toFixed(1)}" r="${rad(p.spend).toFixed(1)}"
      fill="#8b95a5" fill-opacity="0.22" stroke="#8b95a5" stroke-opacity="0.4" stroke-width="0.5">
      <title>${esc(p.login)} · ${p.race}\n${p.questions}q ${p.guesses}g · $${p.spend} · ${p.points}/${p.pointCount} pts</title></circle>`;
  });
  // finishers on top
  pts.filter(p=>p.finished).forEach(p=>{
    g += `<circle cx="${x(p.questions).toFixed(1)}" cy="${y(p.timeMs/60000).toFixed(1)}" r="${rad(p.spend).toFixed(1)}"
      fill="#c3f53c" fill-opacity="0.75" stroke="#c3f53c" stroke-width="1">
      <title>${esc(p.login)} · ${p.race}\nFINISHED · ${p.questions}q ${p.guesses}g · $${p.spend}</title></circle>`;
    g += `<text x="${(x(p.questions)+rad(p.spend)+4).toFixed(1)}" y="${(y(p.timeMs/60000)+3).toFixed(1)}"
      font-size="9" fill="#c3f53c" font-family="monospace">${esc(p.login)}</text>`;
  });

  svg.innerHTML = g;
}

async function showDetail(id){
  const d = await (await fetch(`/api/races/${id}`)).json();
  let h = `<table><thead><tr><th>pos</th><th>racer</th><th class="num">points</th>
    <th class="num">q</th><th class="num hide-m">g</th><th class="num hide-m">g:q</th>
    <th class="num">spend</th><th class="num hide-m">time</th></tr></thead><tbody>`;
  d.racers.forEach((r,i)=>{
    h += `<tr>
      <td class="dim">P${i+1}</td>
      <td class="${r.finished?'win':r.idle?'dim':''}">${who(r.login)}${r.idle?' <span class="ghost">never raced</span>':''}</td>
      <td class="num">${r.finished?'<span class="win">FIN</span>':r.points+'/'+d.track.point_count}</td>
      <td class="num">${r.questions}</td>
      <td class="num dim hide-m">${r.guesses}</td>
      <td class="num dim hide-m">${r.gq??'—'}</td>
      <td class="num">$${r.spend.toFixed(3)}</td>
      <td class="num dim hide-m">${r.finished?fmtTime(r.durationMs):'—'}</td>
    </tr>`;
  });
  h += `</tbody></table>`;
  $('#detail').innerHTML = h;
}

load();
setInterval(load, 120000);
</script>
</body>
</html>
HTML_EOF

echo "→ checking syntax"
node --check src/server.js && echo "   ok"
echo ""
echo "done. now run:  npm start"
