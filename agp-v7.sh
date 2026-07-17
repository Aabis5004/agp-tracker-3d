#!/usr/bin/env bash
# AGP Tracker v7 — cinematic 3D galaxy (bloom, springs, trails, nebula) + clean chrome
# Run from inside ~/agp-tracker :  bash agp-v7.sh
set -e
[ -f package.json ] || { echo "!! run this from inside ~/agp-tracker"; exit 1; }
echo "-> package.json"
cat > package.json << 'PKG_EOF'
{
  "name": "agp-tracker",
  "version": "1.0.0",
  "description": "Unofficial community tracker for Agent Grand Prix (agp.onlatch.com)",
  "main": "src/server.js",
  "type": "module",
  "scripts": {
    "start": "node --no-network-family-autoselection src/server.js",
    "dev": "node --watch --no-network-family-autoselection src/server.js"
  },
  "engines": {
    "node": ">=18"
  },
  "dependencies": {
    "express": "^4.19.2",
    "better-sqlite3": "^11.3.0",
    "node-cron": "^3.0.3"
  },
  "keywords": ["agp", "agent-grand-prix", "latch", "rialo", "tracker"],
  "license": "MIT"
}
PKG_EOF
echo "-> src/agp.js"
cat > src/agp.js << 'AGP_EOF'
import { setDefaultResultOrder } from 'dns';
setDefaultResultOrder('ipv4first');

const API = process.env.AGP_API || 'https://api.agp.onlatch.com/track';
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function get(path, tries = 4) {
  let lastErr;
  for (let i = 1; i <= tries; i++) {
    try {
      const res = await fetch(`${API}${path}`, {
        headers: { accept: 'application/json' },
        signal: AbortSignal.timeout(15000)
      });
      if (!res.ok) throw new Error(`AGP API ${res.status} on ${path}`);
      return await res.json();
    } catch (e) {
      lastErr = e;
      if (i < tries) await sleep(i * 600);
    }
  }
  throw lastErr;
}

export async function fetchTracks() {
  return get('/tracks');
}

export async function fetchTrack(id) {
  return get(`/tracks/${id}`);
}

export async function fetchAll() {
  const tracks = await fetchTracks();
  const details = [];
  for (const t of tracks) {
    try {
      details.push(await fetchTrack(t.id));
      await sleep(250);
    } catch (e) {
      console.error(`  ! failed ${t.name}: ${e.message}`);
    }
  }
  return details;
}
AGP_EOF
echo "-> src/stats.js"
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
STATS_EOF
echo "-> src/server.js"
cat > src/server.js << 'SERVER_EOF'
import { setDefaultResultOrder } from 'dns';
setDefaultResultOrder('ipv4first');

import express from 'express';
import cron from 'node-cron';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { sync } from './sync.js';
import {
  overview, standings, races, raceDetail, insights,
  pareto, styleBreakdown, racerProfile
} from './stats.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.static(join(__dirname, '..', 'public')));

function snapshot() {
  return {
    overview: overview(),
    standings: standings(),
    races: races(),
    insights: insights(),
    pareto: pareto(),
    styles: styleBreakdown(),
    at: new Date().toISOString()
  };
}

// ---- REST ----
app.get('/api/overview',  (_, res) => res.json(overview()));
app.get('/api/standings', (_, res) => res.json(standings()));
app.get('/api/races',     (_, res) => res.json(races()));
app.get('/api/insights',  (_, res) => res.json(insights()));
app.get('/api/pareto',    (_, res) => res.json(pareto()));
app.get('/api/styles',    (_, res) => res.json(styleBreakdown()));
app.get('/api/all',       (_, res) => res.json(snapshot()));

app.get('/api/races/:id', (req, res) => {
  const d = raceDetail(req.params.id);
  if (!d) return res.status(404).json({ error: 'race not found' });
  res.json(d);
});

app.get('/api/racer/:login', (req, res) => {
  const p = racerProfile(req.params.login);
  if (!p) return res.status(404).json({ error: 'racer not found' });
  res.json(p);
});

app.post('/api/sync', async (_, res) => {
  try {
    const r = await sync();
    broadcast();
    res.json(r);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/health', (_, res) => res.json({ ok: true, clients: clients.size, at: new Date().toISOString() }));

// ---- SSE: server polls AGP, pushes to every browser ----
const clients = new Set();

app.get('/api/stream', (req, res) => {
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no'
  });
  res.flushHeaders?.();
  res.write(`event: data\ndata: ${JSON.stringify(snapshot())}\n\n`);
  clients.add(res);

  const ping = setInterval(() => res.write(': ping\n\n'), 25000);
  req.on('close', () => { clearInterval(ping); clients.delete(res); });
});

function broadcast() {
  if (!clients.size) return;
  const payload = `event: data\ndata: ${JSON.stringify(snapshot())}\n\n`;
  for (const c of clients) {
    try { c.write(payload); } catch { clients.delete(c); }
  }
  console.log(`[sse] pushed to ${clients.size} client(s)`);
}

// ---- boot ----
async function boot() {
  console.log('[boot] first sync…');
  try { await sync(); } catch (e) { console.error('[boot] sync failed:', e.message); }

  // fast poll while a race is live, slow otherwise
  cron.schedule('* * * * *', async () => {
    const live = races().some(r => !r.over);
    const min = new Date().getMinutes();
    if (!live && min % 2 !== 0) return;
    try {
      await sync();
      broadcast();
    } catch (e) {
      console.error('[cron] sync failed:', e.message);
    }
  });

  app.listen(PORT, () => console.log(`[boot] http://localhost:${PORT}`));
}

boot();
SERVER_EOF
echo "-> public/galaxy.js"
cat > public/galaxy.js << 'GALAXY_EOF'
/* AGP Tracker — cinematic 3D galaxy
   ES module. Bloom post-processing, spring physics, GPU instancing, light trails.
   X = questions · Y = guesses · Z = points reached */

import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

const S = 15;
const COL = {
  fin:   new THREE.Color('#c3f53c'),
  score: new THREE.Color('#4a9eff'),
  zero:  new THREE.Color('#3d4652')
};

/* ---------- spring physics (critically-damped-ish) ---------- */
class Spring {
  constructor(v = 0, k = 130, d = 16) { this.v = v; this.t = v; this.vel = 0; this.k = k; this.d = d; }
  set(t) { this.t = t; }
  jump(v) { this.v = v; this.t = v; this.vel = 0; }
  step(dt) {
    const f = -this.k * (this.v - this.t) - this.d * this.vel;
    this.vel += f * dt;
    this.v += this.vel * dt;
    return this.v;
  }
  get done() { return Math.abs(this.v - this.t) < 0.001 && Math.abs(this.vel) < 0.001; }
}
class Spring3 {
  constructor(p, k = 90, d = 15) {
    this.x = new Spring(p.x, k, d); this.y = new Spring(p.y, k, d); this.z = new Spring(p.z, k, d);
  }
  set(p) { this.x.set(p.x); this.y.set(p.y); this.z.set(p.z); }
  jump(p) { this.x.jump(p.x); this.y.jump(p.y); this.z.jump(p.z); }
  step(dt, out) { out.set(this.x.step(dt), this.y.step(dt), this.z.step(dt)); return out; }
  get done() { return this.x.done && this.y.done && this.z.done; }
}

/* ---------- module state ---------- */
let container, scene, camera, renderer, composer, bloom, raf;
let root, instMesh, nebula, starA, starB, dust, axesGrp, guideGrp, trailGrp, tagGrp;
let nodes = [], byKey = new Map();
let scale = { q: 1, g: 1, p: 1, s: 0.001 };
let selected = null, hovered = null, filterFn = () => true;
let onSelect = null, onHover = null;

const cam = {
  theta: new Spring(0.55, 60, 12),
  phi:   new Spring(1.18, 60, 12),
  dist:  new Spring(52, 55, 13),
  tx: new Spring(0, 60, 13), ty: new Spring(0, 60, 13), tz: new Spring(0, 60, 13),
  spin: true
};
let drag = null, moved = 0;
const _v = new THREE.Vector3(), _m = new THREE.Matrix4(), _q = new THREE.Quaternion();
const _s = new THREE.Vector3(), _c = new THREE.Color();

const colorFor = d => d.finished ? COL.fin : d.points > 0 ? COL.score : COL.zero;
const keyOf = d => `${d.login}::${d.race}`;

/* ---------- textures ---------- */
function softSprite(hex, soft = 0.35) {
  const c = document.createElement('canvas'); c.width = c.height = 128;
  const x = c.getContext('2d');
  const g = x.createRadialGradient(64, 64, 0, 64, 64, 64);
  g.addColorStop(0, hex.replace(')', ',1)').replace('rgb', 'rgba'));
  g.addColorStop(soft, hex.replace(')', ',0.28)').replace('rgb', 'rgba'));
  g.addColorStop(1, hex.replace(')', ',0)').replace('rgb', 'rgba'));
  x.fillStyle = g; x.fillRect(0, 0, 128, 128);
  return new THREE.CanvasTexture(c);
}

function label(text, color, px = 22, w = 7, h = 1.3) {
  const c = document.createElement('canvas'); c.width = 320; c.height = 64;
  const x = c.getContext('2d');
  x.font = `600 ${px}px ui-monospace, SFMono-Regular, monospace`;
  x.textAlign = 'center'; x.textBaseline = 'middle';
  x.shadowColor = color; x.shadowBlur = 12;
  x.fillStyle = color; x.fillText(text, 160, 32);
  const t = new THREE.CanvasTexture(c);
  t.anisotropy = 4;
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: t, transparent: true, depthTest: false }));
  s.scale.set(w, h, 1);
  return s;
}

/* ---------- scenery ---------- */
function makeNebula() {
  const g = new THREE.Group();
  const blobs = [
    { c: 'rgb(120,200,40)',  p: [-40, 22, -70], s: 90, o: 0.16 },
    { c: 'rgb(40,110,220)',  p: [55, -18, -85], s: 110, o: 0.14 },
    { c: 'rgb(150,90,240)',  p: [10, 45, -95], s: 80, o: 0.10 },
    { c: 'rgb(230,150,40)',  p: [-60, -35, -60], s: 70, o: 0.08 }
  ];
  blobs.forEach(b => {
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({
      map: softSprite(b.c, 0.2), transparent: true, opacity: b.o,
      depthWrite: false, depthTest: false, blending: THREE.AdditiveBlending
    }));
    sp.position.set(...b.p); sp.scale.set(b.s, b.s, 1);
    sp.userData.drift = Math.random() * 6.28;
    g.add(sp);
  });
  g.renderOrder = -10;
  return g;
}

function makeStars(n, r0, r1, size, op) {
  const pos = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const r = r0 + Math.random() * (r1 - r0);
    const th = Math.random() * Math.PI * 2, ph = Math.acos(2 * Math.random() - 1);
    pos[i*3] = r*Math.sin(ph)*Math.cos(th);
    pos[i*3+1] = r*Math.sin(ph)*Math.sin(th);
    pos[i*3+2] = r*Math.cos(ph);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  return new THREE.Points(g, new THREE.PointsMaterial({
    color: 0xffffff, size, sizeAttenuation: true, transparent: true,
    opacity: op, depthWrite: false
  }));
}

function makeDust() {
  const n = 320, pos = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    pos[i*3] = (Math.random()-0.5)*S*2.8;
    pos[i*3+1] = (Math.random()-0.5)*S*2.8;
    pos[i*3+2] = (Math.random()-0.5)*S*2.8;
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  const p = new THREE.Points(g, new THREE.PointsMaterial({
    color: 0x9fd44a, size: 0.13, transparent: true, opacity: 0.3,
    depthWrite: false, blending: THREE.AdditiveBlending
  }));
  p.userData.base = pos.slice();
  return p;
}

function fadingGrid(size, div, y, rotX, col, op) {
  const g = new THREE.GridHelper(size, div, col, col);
  g.material = new THREE.LineBasicMaterial({
    color: col, transparent: true, opacity: op, depthWrite: false
  });
  g.position.y = y;
  if (rotX) g.rotation.x = rotX;
  return g;
}

function buildAxes() {
  const g = new THREE.Group();
  const line = (a, b, c, o) => {
    const geo = new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(...a), new THREE.Vector3(...b)]);
    return new THREE.Line(geo, new THREE.LineBasicMaterial({ color: c, transparent: true, opacity: o }));
  };
  g.add(line([-S,-S,-S], [S,-S,-S], 0x8b95a5, 0.7));
  g.add(line([-S,-S,-S], [-S,S,-S], 0xffb340, 0.55));
  g.add(line([-S,-S,-S], [-S,-S,S], 0x4a9eff, 0.55));

  g.add(fadingGrid(S*2, 10, -S, 0, 0x2a3240, 0.35));
  const back = fadingGrid(S*2, 10, 0, Math.PI/2, 0x222a36, 0.22);
  back.position.set(0, 0, -S); g.add(back);
  const side = fadingGrid(S*2, 10, 0, 0, 0x222a36, 0.18);
  side.rotation.z = Math.PI/2; side.position.set(-S, 0, 0); g.add(side);

  const lx = label('questions →', '#a8b2c0', 20); lx.position.set(3, -S-2.8, -S); g.add(lx);
  const ly = label('guesses →', '#ffb340', 20);   ly.position.set(-S-3.6, 3, -S);  g.add(ly);
  const lz = label('points →', '#4a9eff', 20);    lz.position.set(-S, -S-2.8, 3);  g.add(lz);
  g.userData.labels = [lx, ly, lz];
  return g;
}

/* ---------- data mapping ---------- */
const posOf = d => new THREE.Vector3(
  -S + (d.questions / scale.q) * S * 2,
  -S + (d.guesses   / scale.g) * S * 2,
  -S + (d.points    / scale.p) * S * 2
);
const radOf = d => 0.30 + Math.sqrt(d.spend / scale.s) * 0.95;

function computeScales(pts) {
  scale.q = Math.max(...pts.map(p => p.questions), 1);
  scale.g = Math.max(...pts.map(p => p.guesses), 1);
  scale.p = Math.max(...pts.map(p => p.pointCount), 1);
  scale.s = Math.max(...pts.map(p => p.spend), 0.001);
}

/* ---------- trails ---------- */
function spawnTrail(from, to, color) {
  const pts = [];
  for (let i = 0; i <= 12; i++) pts.push(from.clone().lerp(to, i / 12));
  const geo = new THREE.BufferGeometry().setFromPoints(pts);
  const m = new THREE.LineBasicMaterial({
    color, transparent: true, opacity: 0.85, blending: THREE.AdditiveBlending, depthWrite: false
  });
  const l = new THREE.Line(geo, m);
  l.userData.life = 1;
  trailGrp.add(l);
}

/* ---------- instanced spheres ---------- */
function rebuildInstances(pts) {
  if (instMesh) { root.remove(instMesh); instMesh.geometry.dispose(); instMesh.material.dispose(); }

  const geo = new THREE.IcosahedronGeometry(1, 3);
  const mat = new THREE.MeshStandardMaterial({
    roughness: 0.28, metalness: 0.15, transparent: true, opacity: 0.96,
    emissiveIntensity: 1
  });
  instMesh = new THREE.InstancedMesh(geo, mat, Math.max(pts.length, 1));
  instMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  instMesh.count = pts.length;
  const cols = new Float32Array(Math.max(pts.length, 1) * 3);
  instMesh.instanceColor = new THREE.InstancedBufferAttribute(cols, 3);
  instMesh.frustumCulled = false;
  root.add(instMesh);
}

function syncNodes(pts, first) {
  computeScales(pts);
  const want = new Map(pts.map(d => [keyOf(d), d]));

  // drop gone
  nodes = nodes.filter(n => {
    if (want.has(keyOf(n.data))) return true;
    byKey.delete(keyOf(n.data));
    return false;
  });

  for (const [k, d] of want) {
    const target = posOf(d);
    const r = radOf(d);
    const ex = byKey.get(k);

    if (ex) {
      const old = ex.pos.clone();
      if (old.distanceTo(target) > 0.12 && !first) spawnTrail(old, target, colorFor(d));
      ex.data = d;
      ex.sp.set(target);
      ex.rad.set(r);
      ex.baseColor = colorFor(d);
      continue;
    }

    const n = {
      data: d,
      sp: new Spring3(first ? target : new THREE.Vector3(target.x, -S - 8, target.z), 80, 14),
      rad: new Spring(0.001, 110, 15),
      vis: new Spring(1, 90, 16),
      bright: new Spring(1, 120, 16),
      pos: target.clone(),
      baseColor: colorFor(d),
      phase: Math.random() * 6.28,
      curR: 0.001
    };
    n.sp.set(target);
    n.rad.set(r);
    byKey.set(k, n);
    nodes.push(n);
  }

  rebuildInstances(nodes.map(n => n.data));

  // winner tags
  tagGrp.clear();
  nodes.filter(n => n.data.finished).forEach(n => {
    const sp = label(n.data.login, '#c3f53c', 21, 6.4, 1.2);
    sp.userData.node = n;
    tagGrp.add(sp);
  });
}

/* ---------- guides ---------- */
function drawGuides(n) {
  guideGrp.clear();
  if (!n) return;
  const p = n.pos, c = n.baseColor;
  const mk = (a, b, o = 0.7) => {
    const geo = new THREE.BufferGeometry().setFromPoints([a, b]);
    const l = new THREE.Line(geo, new THREE.LineDashedMaterial({
      color: c, transparent: true, opacity: o, dashSize: 0.45, gapSize: 0.3,
      blending: THREE.AdditiveBlending, depthWrite: false
    }));
    l.computeLineDistances();
    return l;
  };
  const floor = new THREE.Vector3(p.x, -S, p.z);
  guideGrp.add(mk(p, floor));
  guideGrp.add(mk(floor, new THREE.Vector3(p.x, -S, -S), 0.45));
  guideGrp.add(mk(floor, new THREE.Vector3(-S, -S, p.z), 0.45));
  guideGrp.add(mk(p, new THREE.Vector3(-S, p.y, p.z), 0.35));

  const ring = new THREE.Mesh(
    new THREE.RingGeometry(0.9, 1.05, 48),
    new THREE.MeshBasicMaterial({ color: c, transparent: true, opacity: 0.5, side: THREE.DoubleSide,
      blending: THREE.AdditiveBlending, depthWrite: false })
  );
  ring.position.copy(floor); ring.rotation.x = -Math.PI / 2;
  ring.userData.ring = true;
  guideGrp.add(ring);
}

/* ---------- camera ---------- */
function applyCam(dt) {
  const th = cam.theta.step(dt), ph = cam.phi.step(dt), di = cam.dist.step(dt);
  const tx = cam.tx.step(dt), ty = cam.ty.step(dt), tz = cam.tz.step(dt);
  camera.position.set(
    tx + di * Math.sin(ph) * Math.sin(th),
    ty + di * Math.cos(ph),
    tz + di * Math.sin(ph) * Math.cos(th)
  );
  camera.lookAt(tx, ty, tz);
}

function bindControls(el) {
  const ray = new THREE.Raycaster();
  const m = new THREE.Vector2();

  const pick = e => {
    if (!instMesh) return null;
    const r = el.getBoundingClientRect();
    m.x = ((e.clientX - r.left) / r.width) * 2 - 1;
    m.y = -((e.clientY - r.top) / r.height) * 2 + 1;
    ray.setFromCamera(m, camera);
    const hit = ray.intersectObject(instMesh)[0];
    if (!hit || hit.instanceId == null) return null;
    const n = nodes[hit.instanceId];
    return (n && n.vis.v > 0.4) ? n : null;
  };

  el.addEventListener('contextmenu', e => e.preventDefault());

  el.addEventListener('pointerdown', e => {
    el.setPointerCapture(e.pointerId);
    drag = { x: e.clientX, y: e.clientY, pan: e.button === 2 || e.shiftKey };
    moved = 0; cam.spin = false;
    el.style.cursor = drag.pan ? 'move' : 'grabbing';
  });

  el.addEventListener('pointerup', e => {
    try { el.releasePointerCapture(e.pointerId); } catch {}
    if (drag && moved < 6 && !drag.pan) {
      const n = pick(e);
      API.focus(n);
      onSelect?.(n ? n.data : null);
    }
    drag = null;
    el.style.cursor = 'grab';
  });

  el.addEventListener('pointermove', e => {
    if (drag) {
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      moved += Math.abs(dx) + Math.abs(dy);
      if (drag.pan) {
        const right = new THREE.Vector3(), up = new THREE.Vector3();
        camera.matrix.extractBasis(right, up, _v);
        const k = cam.dist.v * 0.0015;
        cam.tx.jump(cam.tx.v - right.x * dx * k + up.x * dy * k);
        cam.ty.jump(cam.ty.v - right.y * dx * k + up.y * dy * k);
        cam.tz.jump(cam.tz.v - right.z * dx * k + up.z * dy * k);
      } else {
        cam.theta.jump(cam.theta.v - dx * 0.006);
        cam.phi.jump(Math.max(0.14, Math.min(Math.PI - 0.14, cam.phi.v - dy * 0.005)));
      }
      drag.x = e.clientX; drag.y = e.clientY;
      return;
    }
    const n = pick(e);
    if (n !== hovered) { hovered = n; el.style.cursor = n ? 'pointer' : 'grab'; }
    onHover?.(n ? n.data : null, e);
  });

  el.addEventListener('pointerleave', () => { hovered = null; onHover?.(null); });

  el.addEventListener('wheel', e => {
    e.preventDefault();
    cam.dist.set(Math.max(13, Math.min(120, cam.dist.t * (1 + e.deltaY * 0.0012))));
  }, { passive: false });

  let pinch = 0;
  el.addEventListener('touchmove', e => {
    if (e.touches.length === 2) {
      const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX,
                           e.touches[0].clientY - e.touches[1].clientY);
      if (pinch) cam.dist.set(Math.max(13, Math.min(120, cam.dist.t * (pinch / d))));
      pinch = d;
    }
  }, { passive: true });
  el.addEventListener('touchend', () => { pinch = 0; });
}

/* ---------- loop ---------- */
let t = 0, last = performance.now();
function animate() {
  raf = requestAnimationFrame(animate);
  const now = performance.now();
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now; t += dt;

  if (cam.spin && !drag) cam.theta.jump(cam.theta.v + dt * 0.075);
  applyCam(dt);

  starA.rotation.y += dt * 0.008;
  starB.rotation.y -= dt * 0.004;
  starB.rotation.x += dt * 0.002;

  nebula.children.forEach((s, i) => {
    s.position.x += Math.sin(t * 0.06 + s.userData.drift) * 0.012;
    s.position.y += Math.cos(t * 0.05 + s.userData.drift) * 0.009;
  });

  const dp = dust.geometry.attributes.position, base = dust.userData.base;
  for (let i = 0; i < dp.count; i++) {
    dp.array[i*3+1] = base[i*3+1] + Math.sin(t * 0.35 + i * 0.7) * 0.55;
    dp.array[i*3]   = base[i*3]   + Math.cos(t * 0.28 + i * 0.5) * 0.4;
  }
  dp.needsUpdate = true;

  // trails fade
  for (let i = trailGrp.children.length - 1; i >= 0; i--) {
    const l = trailGrp.children[i];
    l.userData.life -= dt * 1.4;
    if (l.userData.life <= 0) { trailGrp.remove(l); l.geometry.dispose(); l.material.dispose(); }
    else l.material.opacity = l.userData.life * 0.85;
  }

  // nodes
  if (instMesh) {
    const anySel = !!selected;
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i];
      n.sp.step(dt, n.pos);

      const pass = filterFn(n.data);
      n.vis.set(pass ? 1 : 0);
      n.vis.step(dt);

      const isSel = selected === n, isHov = hovered === n;
      const dim = anySel && !isSel;
      n.bright.set(isSel ? 3.2 : isHov ? 2.1 : dim ? 0.25 : (n.data.finished ? 1.5 : n.data.points > 0 ? 0.85 : 0.4));
      n.bright.step(dt);

      // idle breathe + float
      const breathe = 1 + Math.sin(t * 1.5 + n.phase) * (n.data.finished ? 0.05 : 0.03);
      const float = Math.sin(t * 0.8 + n.phase) * 0.09;
      const mult = (isSel ? 1.85 : isHov ? 1.35 : 1) * breathe;

      n.rad.step(dt);
      n.curR = Math.max(0.0001, n.rad.v * mult * n.vis.v);

      _v.set(n.pos.x, n.pos.y + float, n.pos.z);
      _m.compose(_v, _q.identity(), _s.setScalar(n.curR));
      instMesh.setMatrixAt(i, _m);

      _c.copy(n.baseColor).multiplyScalar(n.bright.v * (0.25 + n.vis.v * 0.75));
      instMesh.setColorAt(i, _c);
    }
    instMesh.instanceMatrix.needsUpdate = true;
    if (instMesh.instanceColor) instMesh.instanceColor.needsUpdate = true;
  }

  // tags follow
  tagGrp.children.forEach(sp => {
    const n = sp.userData.node;
    if (!n) return;
    sp.position.set(n.pos.x, n.pos.y + n.curR + 1.25, n.pos.z);
    sp.material.opacity = n.vis.v * (selected && selected !== n ? 0.12 : 0.95);
  });

  // guides follow selection
  if (selected) {
    if (!selected.sp.done) drawGuides(selected);
    guideGrp.children.forEach(c => {
      if (c.userData.ring) {
        const s = 1 + Math.sin(t * 2.4) * 0.12;
        c.scale.setScalar(s);
        c.material.opacity = 0.35 + Math.sin(t * 2.4) * 0.15;
      }
    });
  }
  guideGrp.visible = !!selected && selected.vis.v > 0.5;

  // axis labels face camera & fade by angle
  axesGrp.userData.labels?.forEach(l => {
    const d = camera.position.distanceTo(l.position);
    l.material.opacity = THREE.MathUtils.clamp(1.4 - d / 90, 0.25, 1);
  });

  composer.render();
}

/* ---------- init ---------- */
function init(el, pts, handlers = {}) {
  container = el;
  onSelect = handlers.onSelect; onHover = handlers.onHover;
  if (raf) cancelAnimationFrame(raf);
  el.innerHTML = '';

  const W = el.clientWidth, H = el.clientHeight || 520;

  scene = new THREE.Scene();
  scene.fog = new THREE.FogExp2(0x070910, 0.0055);

  camera = new THREE.PerspectiveCamera(48, W / H, 0.1, 600);

  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'high-performance' });
  renderer.setSize(W, H);
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  el.appendChild(renderer.domElement);
  renderer.domElement.style.cursor = 'grab';

  composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  bloom = new UnrealBloomPass(new THREE.Vector2(W, H), 0.62, 0.5, 0.22);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  scene.add(new THREE.AmbientLight(0xffffff, 0.42));
  const l1 = new THREE.PointLight(0xc3f53c, 90, 160, 2); l1.position.set(24, 28, 30); scene.add(l1);
  const l2 = new THREE.PointLight(0x4a9eff, 60, 160, 2); l2.position.set(-28, -16, -24); scene.add(l2);
  const l3 = new THREE.PointLight(0xa78bfa, 35, 140, 2); l3.position.set(-12, 26, -20); scene.add(l3);

  nebula = makeNebula(); scene.add(nebula);
  starA = makeStars(1600, 80, 170, 0.55, 0.55); scene.add(starA);
  starB = makeStars(900, 45, 90, 0.3, 0.3);     scene.add(starB);

  root = new THREE.Group(); scene.add(root);
  dust = makeDust(); root.add(dust);
  axesGrp = buildAxes(); root.add(axesGrp);
  guideGrp = new THREE.Group(); root.add(guideGrp);
  trailGrp = new THREE.Group(); root.add(trailGrp);
  tagGrp = new THREE.Group(); root.add(tagGrp);

  nodes = []; byKey.clear();
  syncNodes(pts, true);
  bindControls(renderer.domElement);
  last = performance.now();
  animate();

  // cinematic entry
  cam.dist.jump(140); cam.dist.set(52);
  cam.phi.jump(0.45); cam.phi.set(1.18);

  return API;
}

/* ---------- api ---------- */
const API = {
  init,
  update(pts) { syncNodes(pts, false); },
  setFilter(fn) { filterFn = fn || (() => true); },
  focus(n) {
    selected = n || null;
    drawGuides(selected);
    if (selected) {
      cam.tx.set(selected.pos.x); cam.ty.set(selected.pos.y); cam.tz.set(selected.pos.z);
      cam.dist.set(Math.min(cam.dist.t, 30));
      cam.spin = false;
    }
  },
  select(pred) {
    const n = pred ? nodes.find(x => pred(x.data)) : null;
    API.focus(n);
    return n ? n.data : null;
  },
  clearSelection() { selected = null; drawGuides(null); },
  reset() {
    cam.theta.set(0.55); cam.phi.set(1.18); cam.dist.set(52);
    cam.tx.set(0); cam.ty.set(0); cam.tz.set(0);
    cam.spin = true; selected = null; drawGuides(null);
  },
  toggleSpin() { cam.spin = !cam.spin; return cam.spin; },
  resize() {
    if (!container || !renderer) return;
    const w = container.clientWidth, h = container.clientHeight || 520;
    camera.aspect = w / h; camera.updateProjectionMatrix();
    renderer.setSize(w, h); composer.setSize(w, h);
    bloom.resolution.set(w, h);
  },
  count() { return nodes.filter(n => filterFn(n.data)).length; },
  dispose() { if (raf) cancelAnimationFrame(raf); }
};

window.AGP3D = API;
window.dispatchEvent(new Event('agp3d-ready'));
GALAXY_EOF
echo "-> public/index.html"
cat > public/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AGP Tracker — Agent Grand Prix analytics</title>
<meta name="description" content="Independent real-time analytics for Agent Grand Prix. Strategy galaxy, playstyles, spend analysis.">
<style>
  :root{
    --bg:#080a0e; --panel:#11151c; --panel2:#161b24; --line:#222935;
    --text:#e8ecf1; --dim:#8b95a5; --dim2:#5b6470;
    --acid:#c3f53c; --blue:#4a9eff; --red:#ff5c5c; --amber:#ffb340; --violet:#a78bfa;
    --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
    --r:10px;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html{scroll-behavior:smooth}
  body{background:var(--bg);color:var(--text);font-family:var(--mono);font-size:14px;line-height:1.5;padding:22px 16px;
    background-image:radial-gradient(ellipse 90% 60% at 50% -10%, rgba(195,245,60,.05), transparent 70%)}
  .wrap{max-width:1180px;margin:0 auto}

  header{border-bottom:1px solid var(--line);padding-bottom:14px;margin-bottom:16px;
    display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap}
  h1{font-size:23px;font-weight:700;letter-spacing:-0.5px}
  h1 span{color:var(--acid)}
  .badge{display:inline-block;font-size:9px;padding:2px 6px;border:1px solid var(--line);border-radius:99px;color:var(--dim);margin-left:6px;vertical-align:middle}
  .sub{color:var(--dim);font-size:11px;margin-top:4px}
  .hd-r{display:flex;align-items:center;gap:9px}
  .conn{display:flex;align-items:center;gap:6px;font-size:10px;color:var(--dim)}
  .dot{width:6px;height:6px;border-radius:50%;background:var(--dim2)}
  .dot.on{background:var(--acid);box-shadow:0 0 8px var(--acid);animation:pulse 2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
  button{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:7px;
    padding:6px 11px;font-family:var(--mono);font-size:11px;cursor:pointer;transition:.15s}
  button:hover{border-color:var(--acid);color:var(--acid)}
  button:disabled{opacity:.45;cursor:wait}
  button.on{border-color:var(--acid);color:var(--acid);background:rgba(195,245,60,.08)}

  .note{background:var(--panel);border:1px solid var(--line);border-left:2px solid var(--blue);
    border-radius:0 8px 8px 0;padding:9px 13px;font-size:11.5px;color:var(--dim);margin-bottom:16px}
  .note b{color:var(--text)}
  .note.live{border-left-color:var(--acid)}

  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(128px,1fr));gap:9px;margin-bottom:20px}
  .stat{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:12px;transition:.2s}
  .stat:hover{border-color:#2e3846;transform:translateY(-1px)}
  .stat .k{font-size:9px;color:var(--dim);text-transform:uppercase;letter-spacing:1px}
  .stat .v{font-size:21px;font-weight:700;margin-top:3px;font-variant-numeric:tabular-nums}
  .stat .n{font-size:9px;color:var(--dim);margin-top:1px}

  section{margin-bottom:24px}
  h2{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:4px}
  .h2sub{font-size:11px;color:var(--dim);margin-bottom:10px;line-height:1.65;max-width:820px}

  /* ---- galaxy ---- */
  .gwrap{position:relative;border:1px solid var(--line);border-radius:14px;overflow:hidden;
    background:radial-gradient(ellipse at 50% 45%, #121926 0%, #080a0e 72%)}
  #galaxy{width:100%;height:520px}
  #galaxy canvas{display:block}
  .gbar{position:absolute;top:12px;left:12px;right:12px;display:flex;gap:8px;align-items:center;
    flex-wrap:wrap;z-index:6;pointer-events:none}
  .gbar > *{pointer-events:auto}
  .glass{background:rgba(8,10,14,.72);backdrop-filter:blur(12px);border:1px solid var(--line);border-radius:8px}
  .search{display:flex;align-items:center;gap:6px;padding:5px 9px}
  .search input{background:none;border:none;color:var(--text);font-family:var(--mono);font-size:11px;width:120px;outline:none}
  .search input::placeholder{color:var(--dim2)}
  .chips{display:flex;gap:5px}
  .chip{font-size:10px;padding:5px 9px;border-radius:7px;cursor:pointer;border:1px solid var(--line);
    background:rgba(8,10,14,.72);backdrop-filter:blur(12px);color:var(--dim);transition:.15s;white-space:nowrap}
  .chip:hover{color:var(--text)}
  .chip.on{color:var(--bg);font-weight:700}
  .chip.on.c-fin{background:var(--acid);border-color:var(--acid)}
  .chip.on.c-sc{background:var(--blue);border-color:var(--blue)}
  .chip.on.c-ze{background:var(--dim2);border-color:var(--dim2);color:var(--text)}
  .gright{margin-left:auto;display:flex;gap:6px}
  .gright button{background:rgba(8,10,14,.72);backdrop-filter:blur(12px)}
  .hint{position:absolute;bottom:12px;left:14px;font-size:10px;color:var(--dim2);z-index:4;pointer-events:none}
  .glegend{position:absolute;bottom:12px;right:14px;display:flex;gap:12px;font-size:10px;color:var(--dim);z-index:4;pointer-events:none;flex-wrap:wrap;justify-content:flex-end}
  .glegend b{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:4px;vertical-align:-1px}

  /* timeline */
  .tl{position:absolute;bottom:34px;left:14px;right:14px;z-index:5;display:flex;align-items:center;gap:9px;
    padding:7px 11px;opacity:0;transform:translateY(6px);transition:.2s;pointer-events:none}
  .tl.on{opacity:1;transform:none;pointer-events:auto}
  .tl input[type=range]{flex:1;accent-color:var(--acid);height:3px;cursor:pointer}
  .tl .lbl{font-size:10px;color:var(--acid);min-width:130px;white-space:nowrap}
  .tl button{padding:3px 8px;font-size:10px}

  /* hover tip */
  #htip{position:fixed;pointer-events:none;z-index:60;background:rgba(8,10,14,.94);border:1px solid var(--acid);
    border-radius:7px;padding:6px 9px;font-size:10.5px;opacity:0;transition:opacity .12s;white-space:nowrap}
  #htip b{color:var(--acid)}

  /* draggable card */
  .card{position:fixed;width:296px;background:rgba(11,14,20,.93);backdrop-filter:blur(16px);
    border:1px solid var(--acid);border-radius:12px;z-index:50;opacity:0;transform:scale(.96);
    transition:opacity .18s, transform .18s;pointer-events:none;
    box-shadow:0 18px 50px rgba(0,0,0,.75), 0 0 0 1px rgba(195,245,60,.08)}
  .card.on{opacity:1;transform:none;pointer-events:auto}
  .card .grab{padding:9px 11px;border-bottom:1px solid var(--line);cursor:grab;display:flex;align-items:center;gap:8px}
  .card .grab:active{cursor:grabbing}
  .card .grab img{width:26px;height:26px;border-radius:50%;flex:none;background:var(--panel2)}
  .card .grab .nm{flex:1;min-width:0}
  .card .grab a{color:var(--acid);font-weight:700;font-size:12.5px;text-decoration:none;display:block;
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .card .grab .st{font-size:9px;color:var(--dim)}
  .card .x{cursor:pointer;color:var(--dim);font-size:15px;line-height:1;padding:0 2px}
  .card .x:hover{color:var(--red)}
  .card .bd{padding:10px 11px;max-height:min(58vh,460px);overflow-y:auto}
  .card .bd::-webkit-scrollbar{width:5px}
  .card .bd::-webkit-scrollbar-thumb{background:var(--line);border-radius:3px}
  .row{display:flex;justify-content:space-between;gap:10px;padding:2.5px 0;font-size:11px;color:var(--dim)}
  .row span:last-child{color:var(--text);font-weight:600;text-align:right}
  .grp{font-size:9px;color:var(--dim2);text-transform:uppercase;letter-spacing:1px;margin:10px 0 4px;
    padding-top:8px;border-top:1px solid var(--line)}
  .grp:first-child{margin-top:0;padding-top:0;border-top:none}
  .mini{height:3px;background:var(--panel2);border-radius:2px;overflow:hidden;margin:5px 0 2px}
  .mini i{display:block;height:100%;background:var(--acid);transition:width .4s}
  .split{display:flex;height:5px;border-radius:3px;overflow:hidden;margin:5px 0 3px}
  .split i{height:100%}
  .hrow{display:flex;justify-content:space-between;gap:8px;font-size:10px;padding:4px 6px;border-radius:5px;
    background:var(--panel);margin-bottom:3px;cursor:pointer;transition:.12s;border:1px solid transparent}
  .hrow:hover{border-color:var(--line);background:var(--panel2)}
  .hrow .w{color:var(--acid);font-weight:700}
  .hrow .d{color:var(--dim)}

  table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:var(--r);overflow:hidden}
  th{text-align:left;font-size:9px;color:var(--dim);text-transform:uppercase;letter-spacing:1px;
    padding:9px 11px;border-bottom:1px solid var(--line);font-weight:500}
  td{padding:8px 11px;border-bottom:1px solid var(--line);font-size:12.5px;vertical-align:middle}
  tr:last-child td{border-bottom:none}
  tbody tr{cursor:pointer;transition:.1s}
  tbody tr:hover td{background:var(--panel2)}
  .num{text-align:right;font-variant-numeric:tabular-nums}
  .win{color:var(--acid);font-weight:700}
  .dim{color:var(--dim)}
  .ghost{color:var(--red);font-size:10px}
  .who{display:flex;align-items:center;gap:7px}
  .who img{width:19px;height:19px;border-radius:50%;background:var(--panel2);flex:none}
  .tag{font-size:9px;padding:1px 5px;border-radius:4px;border:1px solid;white-space:nowrap}
  .t-asker{color:var(--acid);border-color:#3f5216}
  .t-guesser{color:var(--amber);border-color:#5c4213}
  .t-balanced{color:var(--blue);border-color:#1c3c60}
  .t-ghost{color:var(--red);border-color:#5c1f1f}
  .t-spammer{color:var(--violet);border-color:#43307a}
  .pill{font-size:9px;padding:1px 5px;border-radius:4px;background:var(--panel2);border:1px solid var(--line);color:var(--dim)}
  .pill.live{color:var(--acid);border-color:var(--acid)}
  .bar{height:4px;background:var(--panel2);border-radius:2px;overflow:hidden;width:38px}
  .bar i{display:block;height:100%;background:var(--acid)}
  select{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;
    padding:7px 10px;font-family:var(--mono);font-size:12px;margin-bottom:10px;width:100%;max-width:290px}
  .loading,.err{padding:40px;text-align:center;color:var(--dim);font-size:12px}
  .err{color:var(--red)}
  .insight{background:var(--panel);border-left:2px solid var(--amber);padding:9px 13px;margin-bottom:6px;
    font-size:12px;border-radius:0 6px 6px 0}
  .insight .t{font-size:9px;color:var(--amber);text-transform:uppercase;letter-spacing:1px;margin-bottom:2px}
  .styles{display:grid;grid-template-columns:repeat(auto-fit,minmax(148px,1fr));gap:9px}
  .sty{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:11px}
  .sty .r{font-size:19px;font-weight:700;margin:5px 0 2px}
  .sty .n{font-size:9px;color:var(--dim)}
  a{color:var(--blue);text-decoration:none}
  a:hover{text-decoration:underline}
  @media(max-width:700px){
    body{padding:12px 9px}
    #galaxy{height:390px}
    td,th{padding:7px 6px;font-size:11px}
    .hide-m{display:none}
    .card{width:calc(100vw - 24px);left:12px!important;right:12px}
    .glegend{display:none}
    .gbar{gap:5px}
    .search input{width:80px}
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>AGP <span>TRACKER</span><span class="badge" title="Community project. Not affiliated with Subzero Labs.">unofficial</span></h1>
    </div>
    <div class="hd-r">
      <div class="conn"><span class="dot" id="dot"></span><span id="conn">connecting…</span></div>
      <button id="refresh">↻ sync</button>
    </div>
  </header>
  <div id="app"><div class="loading">loading…</div></div>
</div>
<div id="htip"></div>
<div class="card" id="card">
  <div class="grab" id="grab"></div>
  <div class="bd" id="cardbd"></div>
</div>

<script type="importmap">
{
  "imports": {
    "three": "https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js",
    "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"
  }
}
</script>
<script type="module" src="/galaxy.js"></script>
<script>
const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fmtTime = ms => { if(!ms) return '—'; const s=Math.round(ms/1000);
  return s>3600?`${Math.floor(s/3600)}h${Math.floor(s%3600/60)}m`:s>60?`${Math.floor(s/60)}m${s%60}s`:`${s}s`; };
const fmtDate = d => new Date(d).toLocaleDateString('en-US',{month:'short',day:'numeric'});
const ago = d => { const n=Math.floor((Date.now()-new Date(d))/864e5);
  return n===0?'today':n===1?'yesterday':`${n} days ago`; };
const avatar = l => `https://github.com/${encodeURIComponent(l)}.png?size=48`;
const ghUrl  = l => `https://github.com/${encodeURIComponent(l)}`;
const who = l => `<span class="who"><img src="${avatar(l)}" alt="" loading="lazy"
  onerror="this.style.visibility='hidden'">${esc(l)}</span>`;

let DATA=null, GAL=null, ES=null, BUILT=false;
const F = { fin:true, sc:true, ze:true, q:'', race:null };

// ---------- data ----------
function connect(){
  if(ES) ES.close();
  ES = new EventSource('/api/stream');
  ES.addEventListener('data', e => {
    DATA = JSON.parse(e.data);
    paint();
    $('#dot').classList.add('on');
    $('#conn').textContent = 'live';
  });
  ES.onerror = () => {
    $('#dot').classList.remove('on');
    $('#conn').textContent = 'reconnecting…';
    setTimeout(() => { if(ES.readyState === 2) connect(); }, 4000);
  };
}

async function forceSync(){
  const b = $('#refresh');
  b.disabled = true; b.textContent = '↻ syncing…';
  try{ await fetch('/api/sync',{method:'POST'}); }catch{}
  b.disabled = false; b.textContent = '↻ sync';
}

// ---------- render ----------
function paint(){
  if(!DATA) return;
  if(!BUILT){ build(); BUILT = true; }
  else { refresh(); }
}

function build(){
  const {overview:o, races:r} = DATA;
  const live = r.filter(x=>!x.over).length, last = r[0];

  let h = '';
  h += live
    ? `<div class="note live"><b>${live} race live.</b> Streaming updates in real time.</div>`
    : last ? `<div class="note"><b>No race running.</b> Last was <b>${esc(last.name)}</b>, ${ago(last.startsAt)}. New circuits appear here automatically.</div>` : '';

  h += `<div class="stats" id="stats"></div>`;
  h += `<section><h2>what the numbers say</h2><div id="ins"></div></section>`;

  h += `<section><h2>the strategy galaxy</h2>
    <div class="h2sub">Every attempt is a star. <b style="color:var(--text)">X</b> = questions ·
      <b style="color:var(--amber)">Y</b> = guesses · <b style="color:var(--blue)">Z</b> = points reached ·
      size = USDC spent. Guesses cost 5× a question, so stars high on Y paid to skip the thinking.
      <b style="color:var(--acid)">Drag to orbit · right-drag or shift-drag to pan · scroll to zoom · click a star for full data.</b>
    </div>
    <div class="gwrap">
      <div id="galaxy"></div>
      <div class="gbar">
        <div class="glass search">
          <span style="color:var(--dim2)">⌕</span>
          <input id="q" placeholder="search racer…" autocomplete="off">
        </div>
        <div class="chips">
          <span class="chip c-fin on" data-f="fin">finished</span>
          <span class="chip c-sc on" data-f="sc">scored</span>
          <span class="chip c-ze on" data-f="ze">zero</span>
        </div>
        <div class="gright">
          <button id="g-tl">⏱ timeline</button>
          <button id="g-spin">⏸</button>
          <button id="g-reset">⌖</button>
        </div>
      </div>
      <div class="tl glass" id="tl">
        <button id="tl-play">▶</button>
        <input type="range" id="tl-r" min="0" max="0" value="0">
        <span class="lbl" id="tl-l"></span>
        <button id="tl-all">all</button>
      </div>
      <div class="hint" id="hint"></div>
      <div class="glegend">
        <span><b style="background:var(--acid)"></b>finished</span>
        <span><b style="background:#4a9eff"></b>scored</span>
        <span><b style="background:#5b6470"></b>zero points</span>
      </div>
    </div></section>`;

  h += `<section><h2>does asking or guessing win?</h2>
    <div class="h2sub">Racers grouped by guess-to-question ratio, and how often each style wins.</div>
    <div class="styles" id="styles"></div></section>`;

  h += `<section><h2>racer standings</h2>
    <div class="h2sub">Click any row to fly to them in the galaxy. <b style="color:var(--text)">g:q</b> = guesses per question.</div>
    <table><thead><tr><th>#</th><th>racer</th><th class="hide-m">style</th>
      <th class="num">races</th><th class="num">wins</th><th class="num">pts</th>
      <th class="num">q</th><th class="num hide-m">g</th><th class="num hide-m">g:q</th>
      <th class="num">spend</th><th class="num hide-m">$/win</th></tr></thead>
      <tbody id="stand"></tbody></table></section>`;

  h += `<section><h2>every race</h2>
    <div class="h2sub"><b style="color:var(--text)">real</b> = how many on the grid actually asked something.</div>
    <table><thead><tr><th>race</th><th class="hide-m">date</th><th class="hide-m">diff</th>
      <th class="num">grid</th><th class="num">real</th><th>winner</th><th class="num">spend</th></tr></thead>
      <tbody id="racelist"></tbody></table></section>`;

  h += `<section><h2>race detail</h2>
    <select id="pick"></select><div id="detail"></div></section>`;

  $('#app').innerHTML = h;

  const boot3d = () => {
    GAL = window.AGP3D.init($('#galaxy'), DATA.pareto, {
      onSelect: d => d ? openCard(d) : closeCard(),
      onHover:  (d,e) => hoverTip(d,e)
    });
    applyFilter();
  };
  if(window.AGP3D) boot3d(); else window.addEventListener('agp3d-ready', boot3d, {once:true});
  window.addEventListener('resize', () => GAL && GAL.resize());

  wire();
  refresh();
}

function refresh(){
  const {overview:o, standings:s, races:r, insights:ins, styles, pareto:pts} = DATA;

  $('#stats').innerHTML = `
    <div class="stat"><div class="k">races</div><div class="v">${o.races}</div><div class="n">all time</div></div>
    <div class="stat"><div class="k">entries</div><div class="v">${o.entries}</div><div class="n">${o.uniquePlayers} unique</div></div>
    <div class="stat"><div class="k">real racers</div><div class="v" style="color:var(--acid)">${o.participationPct}%</div><div class="n">${o.ghosts} never asked</div></div>
    <div class="stat"><div class="k">finishers</div><div class="v">${o.finishers}</div><div class="n">crossed the FIN</div></div>
    <div class="stat"><div class="k">questions</div><div class="v">${o.questions.toLocaleString()}</div><div class="n">${o.guesses.toLocaleString()} guesses</div></div>
    <div class="stat"><div class="k">spend</div><div class="v">$${o.spend.toFixed(2)}</div><div class="n">${o.guessSpendPct}% on guesses</div></div>`;

  $('#ins').innerHTML = ins.map(i =>
    `<div class="insight"><div class="t">${esc(i.tag)}</div>${esc(i.text)}</div>`).join('');

  $('#styles').innerHTML = (styles||[]).map(g =>
    `<div class="sty"><div><span class="tag t-${g.key}">${esc(g.label)}</span></div>
      <div class="r">${g.wins} <span style="font-size:11px;color:var(--dim);font-weight:400">wins</span></div>
      <div class="n">${g.players} racers · ${g.races} entries · ${g.winRate}% win rate</div>
      <div class="n" style="margin-top:3px">${esc(g.note)}</div></div>`).join('');

  $('#stand').innerHTML = s.slice(0,30).map((p,i) =>
    `<tr data-login="${esc(p.login)}">
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
    </tr>`).join('');
  $('#stand').querySelectorAll('tr').forEach(tr =>
    tr.onclick = () => flyTo(tr.dataset.login));

  $('#racelist').innerHTML = r.map(t =>
    `<tr data-race="${t.id}">
      <td>${esc(t.name)} ${t.over?'<span class="pill">over</span>':'<span class="pill live">live</span>'}</td>
      <td class="dim hide-m">${fmtDate(t.startsAt)}</td>
      <td class="dim hide-m">${esc(t.difficulty)}</td>
      <td class="num">${t.grid}</td>
      <td class="num"><div style="display:flex;align-items:center;gap:5px;justify-content:flex-end">
        <span>${t.active}</span><div class="bar"><i style="width:${t.participationPct}%"></i></div></div></td>
      <td class="win">${t.winner?who(t.winner):'<span class="dim">nobody</span>'}</td>
      <td class="num">$${t.spend.toFixed(2)}</td></tr>`).join('');
  $('#racelist').querySelectorAll('tr').forEach(tr =>
    tr.onclick = () => { $('#pick').value = tr.dataset.race; showDetail(tr.dataset.race); 
      document.querySelector('#pick').scrollIntoView({block:'center'}); });

  const pick = $('#pick');
  const cur = pick.value;
  pick.innerHTML = r.map(t => `<option value="${t.id}">${esc(t.name)}</option>`).join('');
  if(cur && r.some(t=>t.id===cur)) pick.value = cur;
  showDetail(pick.value);

  // timeline range
  const tlr = $('#tl-r');
  tlr.max = r.length - 1;

  if(GAL){ GAL.update(pts); applyFilter(); }
}

// ---------- filters ----------
function applyFilter(){
  if(!GAL) return;
  const q = F.q.toLowerCase();
  GAL.setFilter(d => {
    if(F.race && d.race !== F.race) return false;
    if(q && !d.login.toLowerCase().includes(q)) return false;
    if(d.finished) return F.fin;
    if(d.points > 0) return F.sc;
    return F.ze;
  });
  const n = GAL.count();
  $('#hint').textContent = `${n} of ${DATA.pareto.length} stars${F.race?' · '+F.race:''}`;
}

function wire(){
  $('#q').oninput = e => { F.q = e.target.value.trim(); applyFilter(); };
  document.querySelectorAll('.chip').forEach(c => c.onclick = () => {
    F[c.dataset.f] = !F[c.dataset.f];
    c.classList.toggle('on', F[c.dataset.f]);
    applyFilter();
  });

  const spin = $('#g-spin');
  spin.onclick = () => { if(GAL) spin.textContent = GAL.toggleSpin() ? '⏸' : '▶'; };
  $('#g-reset').onclick = () => { if(GAL) GAL.reset(); closeCard(); };

  // timeline
  const tl = $('#tl'), tlr = $('#tl-r'), tll = $('#tl-l'), tlp = $('#tl-play');
  let playing = null;
  $('#g-tl').onclick = () => {
    const on = tl.classList.toggle('on');
    $('#g-tl').classList.toggle('on', on);
    if(!on){ F.race = null; applyFilter(); stop(); }
    else setRace(+tlr.value);
  };
  const setRace = i => {
    const r = DATA.races[DATA.races.length-1-i];
    if(!r) return;
    F.race = r.name;
    tll.textContent = `${fmtDate(r.startsAt)} · ${r.name}`;
    tlr.value = i;
    applyFilter();
  };
  tlr.oninput = e => setRace(+e.target.value);
  const stop = () => { if(playing){ clearInterval(playing); playing=null; tlp.textContent='▶'; } };
  tlp.onclick = () => {
    if(playing) return stop();
    tlp.textContent = '⏸';
    playing = setInterval(() => {
      let i = +tlr.value + 1;
      if(i > +tlr.max) i = 0;
      setRace(i);
    }, 1600);
  };
  $('#tl-all').onclick = () => { stop(); F.race = null; tll.textContent='all races'; applyFilter(); };

  $('#pick').onchange = e => showDetail(e.target.value);
  $('#refresh').onclick = forceSync;
  makeDraggable();
}

// ---------- hover ----------
function hoverTip(d, e){
  const t = $('#htip');
  if(!d){ t.style.opacity = 0; return; }
  const gq = d.questions ? (d.guesses/d.questions).toFixed(2) : '—';
  t.innerHTML = `<b>${esc(d.login)}</b> · ${d.finished?'FIN':d.points+'/'+d.pointCount} · ${d.questions}q ${d.guesses}g · $${d.spend.toFixed(3)}`;
  t.style.left = (e.clientX + 14) + 'px';
  t.style.top  = (e.clientY - 28) + 'px';
  t.style.opacity = 1;
}

// ---------- card ----------
async function openCard(d){
  const c = $('#card');
  if(!c.dataset.placed){
    const g = $('#galaxy').getBoundingClientRect();
    c.style.left = (g.left + 14) + 'px';
    c.style.top  = (g.top + 58) + 'px';
    c.dataset.placed = '1';
  }
  c.classList.add('on');

  $('#grab').innerHTML = `<img src="${avatar(d.login)}" alt="" onerror="this.style.visibility='hidden'">
    <span class="nm"><a href="${ghUrl(d.login)}" target="_blank" rel="noopener">${esc(d.login)}</a>
    <span class="st">loading…</span></span><span class="x" onclick="closeCard()">×</span>`;

  const qC = d.questions * 0.001, gC = d.spend - qC;
  const pct = d.finished ? 100 : Math.round(d.points / d.pointCount * 100);
  const gq = d.questions ? (d.guesses/d.questions).toFixed(2) : '—';

  $('#cardbd').innerHTML = `
    <div class="grp">this attempt · ${esc(d.race)}</div>
    <div class="row"><span>result</span><span style="color:${d.finished?'var(--acid)':'var(--text)'}">${d.finished?'FINISHED':d.points+'/'+d.pointCount+' pts'}</span></div>
    <div class="mini"><i style="width:${pct}%"></i></div>
    <div class="row"><span>questions</span><span>${d.questions}</span></div>
    <div class="row"><span>guesses</span><span>${d.guesses}</span></div>
    <div class="row"><span>g:q ratio</span><span>${gq}</span></div>
    <div class="grp">spend split</div>
    <div class="split">
      <i style="background:var(--acid);width:${d.spend?qC/d.spend*100:0}%"></i>
      <i style="background:var(--amber);width:${d.spend?gC/d.spend*100:0}%"></i></div>
    <div class="row"><span style="color:var(--acid)">questions</span><span>$${qC.toFixed(3)}</span></div>
    <div class="row"><span style="color:var(--amber)">guesses</span><span>$${gC.toFixed(3)}</span></div>
    <div class="row"><span>total</span><span>$${d.spend.toFixed(3)}</span></div>
    <div id="prof"><div class="grp">career</div><div class="row"><span>loading…</span><span></span></div></div>`;

  try{
    const p = await (await fetch(`/api/racer/${encodeURIComponent(d.login)}`)).json();
    $('#grab').querySelector('.st').innerHTML =
      `<span class="tag t-${p.style.key}">${esc(p.style.label)}</span> · ${p.races} races`;
    $('#prof').innerHTML = `
      <div class="grp">career</div>
      <div class="row"><span>races</span><span>${p.races}</span></div>
      <div class="row"><span>wins</span><span style="color:${p.wins?'var(--acid)':'var(--dim)'}">${p.wins} (${p.winRate}%)</span></div>
      <div class="row"><span>total points</span><span>${p.points}</span></div>
      <div class="row"><span>questions / guesses</span><span>${p.questions} / ${p.guesses}</span></div>
      <div class="row"><span>guess accuracy</span><span>${p.accuracy!==null?p.accuracy+'%':'—'}</span></div>
      <div class="row"><span>total spend</span><span>$${p.spend.toFixed(3)}</span></div>
      ${p.costPerWin?`<div class="row"><span>cost per win</span><span style="color:var(--acid)">$${p.costPerWin.toFixed(3)}</span></div>`:''}
      <div class="row"><span>first seen</span><span>${p.firstSeen?fmtDate(p.firstSeen):'—'}</span></div>
      <div class="grp">race history</div>
      ${p.history.map(hh=>`<div class="hrow" data-r="${esc(hh.race)}">
        <span class="${hh.finished?'w':''}">${hh.finished?'🏁 ':''}${esc(hh.race)}</span>
        <span class="d">${hh.points}/${hh.pointCount} · ${hh.questions}q · $${hh.spend.toFixed(2)}</span>
      </div>`).join('')}`;
    $('#prof').querySelectorAll('.hrow').forEach(el =>
      el.onclick = () => { F.race = el.dataset.r; $('#tl').classList.add('on'); $('#g-tl').classList.add('on'); applyFilter(); });
  }catch{}
}
function closeCard(){ $('#card').classList.remove('on'); GAL && GAL.clearSelection(); }

function flyTo(login){
  if(!GAL) return;
  const d = GAL.select(x => x.login === login);
  if(d) openCard(d);
}

function makeDraggable(){
  const c = $('#card'), h = $('#grab');
  let dr = null;
  h.addEventListener('pointerdown', e => {
    if(e.target.classList.contains('x') || e.target.tagName === 'A') return;
    h.setPointerCapture(e.pointerId);
    const r = c.getBoundingClientRect();
    dr = { dx: e.clientX - r.left, dy: e.clientY - r.top };
  });
  h.addEventListener('pointermove', e => {
    if(!dr) return;
    c.style.left = Math.max(6, Math.min(innerWidth - c.offsetWidth - 6, e.clientX - dr.dx)) + 'px';
    c.style.top  = Math.max(6, Math.min(innerHeight - 60, e.clientY - dr.dy)) + 'px';
  });
  h.addEventListener('pointerup', e => { dr = null; h.releasePointerCapture(e.pointerId); });
}

async function showDetail(id){
  if(!id) return;
  const d = await (await fetch(`/api/races/${id}`)).json();
  $('#detail').innerHTML = `<table><thead><tr><th>pos</th><th>racer</th><th class="num">points</th>
    <th class="num">q</th><th class="num hide-m">g</th><th class="num hide-m">g:q</th>
    <th class="num">spend</th><th class="num hide-m">time</th></tr></thead><tbody>` +
    d.racers.map((r,i)=>`<tr data-login="${esc(r.login)}">
      <td class="dim">P${i+1}</td>
      <td class="${r.finished?'win':r.idle?'dim':''}">${who(r.login)}${r.idle?' <span class="ghost">never raced</span>':''}</td>
      <td class="num">${r.finished?'<span class="win">FIN</span>':r.points+'/'+d.track.point_count}</td>
      <td class="num">${r.questions}</td>
      <td class="num dim hide-m">${r.guesses}</td>
      <td class="num dim hide-m">${r.gq??'—'}</td>
      <td class="num">$${r.spend.toFixed(3)}</td>
      <td class="num dim hide-m">${r.finished?fmtTime(r.durationMs):'—'}</td></tr>`).join('') +
    `</tbody></table>`;
  $('#detail').querySelectorAll('tr').forEach(tr => tr.onclick = () => flyTo(tr.dataset.login));
}

// boot
fetch('/api/all').then(r=>r.json()).then(d=>{ DATA=d; paint(); connect(); })
  .catch(e => $('#app').innerHTML = `<div class="err">Couldn't load — is the server running?<br><br>${esc(e.message)}</div>`);
</script>
</body>
</html>
HTML_EOF
echo "-> syntax check"
node --check src/server.js
node --check src/agp.js
node --input-type=module --check < public/galaxy.js
echo ""
echo "=== verifying v7 landed ==="
grep -q "UnrealBloomPass" public/galaxy.js && echo "  [ok] bloom"      || echo "  [FAIL] bloom"
grep -q "importmap"       public/index.html && echo "  [ok] importmap" || echo "  [FAIL] importmap"
grep -q "api/stream"      src/server.js     && echo "  [ok] SSE"       || echo "  [FAIL] SSE"
grep -q "STRATEGY GALAXY\|strategy galaxy" public/index.html && echo "  [ok] galaxy section" || echo "  [FAIL] galaxy section"
grep -q "<footer>"        public/index.html && echo "  [FAIL] footer still there" || echo "  [ok] footer gone"
echo ""
echo "done. run:  npm start     then hard-refresh the browser (Ctrl+Shift+R)"
