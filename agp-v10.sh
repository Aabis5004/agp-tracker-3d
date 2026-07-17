#!/usr/bin/env bash
# AGP Tracker v10 — the GLOBE. Fibonacci lattice = mathematically even spread, no clumping.
# Run from inside ~/agp-tracker :  bash agp-v10.sh
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
/* AGP Tracker — the globe
   Every racer is a star on the sphere.
   Latitude = rank (winners north, ghosts south) · evenly spread by Fibonacci lattice
   so nothing can ever clump, regardless of how skewed the data is.
   Size = spend · colour = result · height = points reached */

import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

const R = 10;                       // globe radius
const COL = {
  fin:   new THREE.Color('#c3f53c'),
  score: new THREE.Color('#4a9eff'),
  zero:  new THREE.Color('#5d6878')
};

/* ---------- springs ---------- */
class Spring {
  constructor(v = 0, k = 120, d = 15) { this.v = v; this.t = v; this.vel = 0; this.k = k; this.d = d; }
  set(t) { this.t = t; }
  jump(v) { this.v = v; this.t = v; this.vel = 0; }
  step(dt) {
    this.vel += (-this.k * (this.v - this.t) - this.d * this.vel) * dt;
    this.v += this.vel * dt;
    return this.v;
  }
  get done() { return Math.abs(this.v - this.t) < 0.002 && Math.abs(this.vel) < 0.002; }
}

/* ---------- state ---------- */
let container, scene, camera, renderer, composer, bloom, raf;
let globe, shell, atmo, matrix, grat, orbs, tagGrp, arcGrp, halo, starfield;
let nodes = [], byKey = new Map();
let selected = null, hovered = null, filterFn = () => true;
let onSelect = null, onHover = null, running = true;
let maxSpend = 0.001;

const rot = { y: new Spring(0.4, 45, 11), x: new Spring(0.18, 45, 11) };
const dist = new Spring(30, 50, 12);
let spin = true, drag = null, moved = 0;

const _v = new THREE.Vector3(), _m = new THREE.Matrix4(), _q = new THREE.Quaternion();
const _s = new THREE.Vector3(), _c = new THREE.Color();

const colorFor = d => d.finished ? COL.fin : d.points > 0 ? COL.score : COL.zero;
const keyOf = d => `${d.login}::${d.race}`;

/* ---------- sprites ---------- */
function label(text, color, px = 19) {
  const c = document.createElement('canvas'); c.width = 320; c.height = 64;
  const x = c.getContext('2d');
  x.font = `600 ${px}px 'JetBrains Mono', ui-monospace, monospace`;
  x.textAlign = 'center'; x.textBaseline = 'middle';
  x.shadowColor = color; x.shadowBlur = 16;
  x.fillStyle = color; x.fillText(text, 160, 32);
  const t = new THREE.CanvasTexture(c); t.anisotropy = 4;
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: t, transparent: true, depthTest: false }));
  s.scale.set(5.6, 1.12, 1);
  return s;
}

/* ---------- Fibonacci lattice: guarantees even spread ---------- */
function fib(i, n) {
  const y = n === 1 ? 0 : 1 - (i / (n - 1)) * 2;      // 1 → -1
  const r = Math.sqrt(Math.max(0, 1 - y * y));
  const th = Math.PI * (3 - Math.sqrt(5)) * i;         // golden angle
  return new THREE.Vector3(Math.cos(th) * r, y, Math.sin(th) * r);
}

/* ---------- globe shell ---------- */
function buildShell() {
  const g = new THREE.Group();

  // solid core so back-side stars are occluded
  const core = new THREE.Mesh(
    new THREE.SphereGeometry(R * 0.985, 64, 64),
    new THREE.MeshStandardMaterial({
      color: 0x070b12, roughness: 0.85, metalness: 0.1,
      transparent: true, opacity: 0.92
    })
  );
  g.add(core);

  // dot matrix surface
  const n = 3200, pos = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const p = fib(i, n).multiplyScalar(R * 1.002);
    pos[i*3] = p.x; pos[i*3+1] = p.y; pos[i*3+2] = p.z;
  }
  const mg = new THREE.BufferGeometry();
  mg.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  matrix = new THREE.Points(mg, new THREE.PointsMaterial({
    color: 0x2f4a5e, size: 0.075, sizeAttenuation: true,
    transparent: true, opacity: 0.55, depthWrite: false
  }));
  g.add(matrix);

  // graticule
  grat = new THREE.Group();
  const gm = new THREE.LineBasicMaterial({ color: 0x1f4058, transparent: true, opacity: 0.3 });
  for (let i = 1; i < 8; i++) {
    const lat = (i / 8) * Math.PI - Math.PI / 2;
    const r = Math.cos(lat) * R * 1.004, y = Math.sin(lat) * R * 1.004;
    const pts = [];
    for (let a = 0; a <= 96; a++) {
      const th = (a / 96) * Math.PI * 2;
      pts.push(new THREE.Vector3(Math.cos(th) * r, y, Math.sin(th) * r));
    }
    grat.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), gm));
  }
  for (let i = 0; i < 12; i++) {
    const th = (i / 12) * Math.PI * 2;
    const pts = [];
    for (let a = 0; a <= 64; a++) {
      const ph = (a / 64) * Math.PI - Math.PI / 2;
      pts.push(new THREE.Vector3(
        Math.cos(ph) * Math.cos(th) * R * 1.004,
        Math.sin(ph) * R * 1.004,
        Math.cos(ph) * Math.sin(th) * R * 1.004
      ));
    }
    grat.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), gm));
  }
  g.add(grat);
  return g;
}

/* ---------- atmosphere (fresnel rim) ---------- */
function buildAtmo() {
  return new THREE.Mesh(
    new THREE.SphereGeometry(R * 1.16, 64, 64),
    new THREE.ShaderMaterial({
      transparent: true, side: THREE.BackSide, depthWrite: false,
      blending: THREE.AdditiveBlending,
      uniforms: { uCol: { value: new THREE.Color('#8fe03a') } },
      vertexShader: `
        varying vec3 vN;
        void main(){
          vN = normalize(normalMatrix * normal);
          gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0);
        }`,
      fragmentShader: `
        uniform vec3 uCol;
        varying vec3 vN;
        void main(){
          float i = pow(0.58 - dot(vN, vec3(0.0,0.0,1.0)), 3.2);
          gl_FragColor = vec4(uCol, 1.0) * clamp(i, 0.0, 1.0) * 0.85;
        }`
    })
  );
}

function buildHalo() {
  const c = document.createElement('canvas'); c.width = c.height = 256;
  const x = c.getContext('2d');
  const g = x.createRadialGradient(128, 128, 60, 128, 128, 128);
  g.addColorStop(0, 'rgba(140,220,60,0.30)');
  g.addColorStop(0.55, 'rgba(74,158,255,0.10)');
  g.addColorStop(1, 'rgba(0,0,0,0)');
  x.fillStyle = g; x.fillRect(0, 0, 256, 256);
  const s = new THREE.Sprite(new THREE.SpriteMaterial({
    map: new THREE.CanvasTexture(c), transparent: true, opacity: 0.9,
    depthWrite: false, depthTest: false, blending: THREE.AdditiveBlending
  }));
  s.scale.set(R * 4.4, R * 4.4, 1);
  s.renderOrder = -5;
  return s;
}

function buildStars() {
  const n = 2200, pos = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const r = 90 + Math.random() * 150;
    const th = Math.random() * Math.PI * 2, ph = Math.acos(2 * Math.random() - 1);
    pos[i*3] = r*Math.sin(ph)*Math.cos(th);
    pos[i*3+1] = r*Math.sin(ph)*Math.sin(th);
    pos[i*3+2] = r*Math.cos(ph);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  return new THREE.Points(g, new THREE.PointsMaterial({
    color: 0xffffff, size: 0.42, sizeAttenuation: true,
    transparent: true, opacity: 0.5, depthWrite: false
  }));
}

/* ---------- layout: rank → latitude, Fibonacci → even spread ---------- */
function layout(pts) {
  maxSpend = Math.max(...pts.map(p => p.spend), 0.001);

  // best first → they land near the north pole
  const sorted = [...pts].sort((a, b) =>
    (b.finished - a.finished) ||
    (b.points - a.points) ||
    (b.questions - a.questions) ||
    a.login.localeCompare(b.login)
  );

  const n = sorted.length;
  const out = new Map();
  sorted.forEach((d, i) => {
    const dir = fib(i, n);
    // lift off the surface by points reached
    const lift = R * (1.035 + (d.pointCount ? d.points / d.pointCount : 0) * 0.16);
    out.set(keyOf(d), { dir, pos: dir.clone().multiplyScalar(lift) });
  });
  return out;
}

const radOf = d => 0.13 + Math.sqrt(d.spend / maxSpend) * 0.42;

/* ---------- orbs ---------- */
function rebuild(count) {
  if (orbs) { globe.remove(orbs); orbs.geometry.dispose(); orbs.material.dispose(); }
  const geo = new THREE.IcosahedronGeometry(1, 3);
  const mat = new THREE.MeshStandardMaterial({
    roughness: 0.25, metalness: 0.1,
    emissive: new THREE.Color(0xffffff), emissiveIntensity: 0.001,
    transparent: true, opacity: 0.98
  });
  orbs = new THREE.InstancedMesh(geo, mat, Math.max(count, 1));
  orbs.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  orbs.count = count;
  orbs.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(Math.max(count, 1) * 3), 3);
  orbs.frustumCulled = false;
  globe.add(orbs);
}

function syncNodes(pts, first) {
  const L = layout(pts);
  const want = new Map(pts.map(d => [keyOf(d), d]));

  nodes = nodes.filter(n => {
    if (want.has(keyOf(n.data))) return true;
    byKey.delete(keyOf(n.data));
    return false;
  });

  for (const [k, d] of want) {
    const { dir, pos } = L.get(k);
    const r = radOf(d);
    const ex = byKey.get(k);
    if (ex) {
      ex.data = d; ex.dir = dir; ex.home = pos;
      ex.rad.set(r); ex.baseColor = colorFor(d);
      continue;
    }
    const n = {
      data: d, dir, home: pos,
      pos: first ? pos.clone() : dir.clone().multiplyScalar(R * 0.2),
      rise: new Spring(first ? 1 : 0, 60, 13),
      rad: new Spring(0.0001, 95, 14),
      vis: new Spring(1, 85, 15),
      bright: new Spring(1, 105, 15),
      phase: Math.random() * 6.28,
      curR: 0.0001
    };
    n.rise.set(1); n.rad.set(r);
    byKey.set(k, n); nodes.push(n);
  }

  // ordering must match instance index
  nodes.sort((a, b) =>
    (b.data.finished - a.data.finished) ||
    (b.data.points - a.data.points) ||
    (b.data.questions - a.data.questions) ||
    a.data.login.localeCompare(b.data.login)
  );

  rebuild(nodes.length);

  tagGrp.clear();
  nodes.filter(n => n.data.finished).forEach(n => {
    const sp = label(n.data.login, '#c3f53c');
    sp.userData.node = n;
    tagGrp.add(sp);
  });
}

/* ---------- arcs: link the selected racer to the rest of their race ---------- */
function drawArcs(node) {
  arcGrp.clear();
  if (!node) return;
  const peers = nodes.filter(n => n !== node && n.data.race === node.data.race && n.vis.v > 0.4);
  const col = node.baseColor;
  peers.forEach(p => {
    const a = node.pos.clone(), b = p.pos.clone();
    const mid = a.clone().add(b).multiplyScalar(0.5);
    mid.normalize().multiplyScalar(R * (1.1 + a.distanceTo(b) / (R * 5)));
    const curve = new THREE.QuadraticBezierCurve3(a, mid, b);
    const g = new THREE.BufferGeometry().setFromPoints(curve.getPoints(28));
    const l = new THREE.Line(g, new THREE.LineBasicMaterial({
      color: col, transparent: true, opacity: 0.32,
      blending: THREE.AdditiveBlending, depthWrite: false
    }));
    arcGrp.add(l);
  });
}

/* ---------- controls: drag spins the globe itself ---------- */
function bindControls(el) {
  const ray = new THREE.Raycaster();
  const m = new THREE.Vector2();

  const pick = e => {
    if (!orbs) return null;
    const r = el.getBoundingClientRect();
    m.x = ((e.clientX - r.left) / r.width) * 2 - 1;
    m.y = -((e.clientY - r.top) / r.height) * 2 + 1;
    ray.setFromCamera(m, camera);
    const hits = ray.intersectObject(orbs);
    for (const h of hits) {
      const n = nodes[h.instanceId];
      if (n && n.vis.v > 0.4) return n;
    }
    return null;
  };

  el.addEventListener('contextmenu', e => e.preventDefault());
  el.addEventListener('pointerdown', e => {
    el.setPointerCapture(e.pointerId);
    drag = { x: e.clientX, y: e.clientY };
    moved = 0; spin = false;
    el.style.cursor = 'grabbing';
  });
  el.addEventListener('pointerup', e => {
    try { el.releasePointerCapture(e.pointerId); } catch {}
    if (drag && moved < 6) {
      const n = pick(e);
      API.focus(n);
      onSelect?.(n ? n.data : null);
    }
    drag = null; el.style.cursor = 'grab';
  });
  el.addEventListener('pointermove', e => {
    if (drag) {
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      moved += Math.abs(dx) + Math.abs(dy);
      rot.y.jump(rot.y.v + dx * 0.0062);
      rot.x.jump(Math.max(-1.35, Math.min(1.35, rot.x.v + dy * 0.0046)));
      drag.x = e.clientX; drag.y = e.clientY;
      return;
    }
    const n = pick(e);
    if (n !== hovered) { hovered = n; el.style.cursor = n ? 'pointer' : 'grab'; }
    onHover?.(n ? n.data : null, e);
  });
  el.addEventListener('pointerleave', () => { hovered = null; onHover?.(null); });

  // plain wheel scrolls the page; modifier zooms
  el.addEventListener('wheel', e => {
    if (!(e.ctrlKey || e.metaKey || e.shiftKey)) return;
    e.preventDefault();
    dist.set(Math.max(15, Math.min(70, dist.t * (1 + e.deltaY * 0.0013))));
  }, { passive: false });

  let pinch = 0;
  el.addEventListener('touchmove', e => {
    if (e.touches.length === 2) {
      const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX,
                           e.touches[0].clientY - e.touches[1].clientY);
      if (pinch) dist.set(Math.max(15, Math.min(70, dist.t * (pinch / d))));
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
  last = now;
  if (!running) return;
  t += dt;

  if (spin && !drag) rot.y.jump(rot.y.v + dt * 0.085);
  globe.rotation.y = rot.y.step(dt);
  globe.rotation.x = rot.x.step(dt);
  camera.position.z = dist.step(dt);

  starfield.rotation.y += dt * 0.006;
  atmo.material.uniforms.uCol.value.setHSL(0.22 + Math.sin(t * 0.16) * 0.03, 0.72, 0.5);

  if (orbs) {
    const anySel = !!selected;
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i];
      n.rise.step(dt);
      n.pos.copy(n.dir).multiplyScalar(
        R * 0.25 + (n.home.length() - R * 0.25) * n.rise.v
      );

      n.vis.set(filterFn(n.data) ? 1 : 0); n.vis.step(dt);

      const isSel = selected === n, isHov = hovered === n;
      const dim = anySel && !isSel;
      n.bright.set(isSel ? 3.6 : isHov ? 2.3 : dim ? 0.22 : (n.data.finished ? 1.7 : n.data.points > 0 ? 1.0 : 0.5));
      n.bright.step(dt);

      const breathe = 1 + Math.sin(t * 1.6 + n.phase) * (n.data.finished ? 0.07 : 0.04);
      const hover = Math.sin(t * 0.9 + n.phase) * 0.035;
      const mult = (isSel ? 2.0 : isHov ? 1.45 : 1) * breathe;

      n.rad.step(dt);
      n.curR = Math.max(0.0001, n.rad.v * mult * n.vis.v);

      _v.copy(n.dir).multiplyScalar(n.pos.length() + hover);
      _m.compose(_v, _q.identity(), _s.setScalar(n.curR));
      orbs.setMatrixAt(i, _m);
      _c.copy(n.baseColor).multiplyScalar(n.bright.v * (0.2 + n.vis.v * 0.8));
      orbs.setColorAt(i, _c);
    }
    orbs.instanceMatrix.needsUpdate = true;
    if (orbs.instanceColor) orbs.instanceColor.needsUpdate = true;
  }

  tagGrp.children.forEach(sp => {
    const n = sp.userData.node;
    if (!n) return;
    _v.copy(n.dir).multiplyScalar(n.pos.length() + n.curR + 0.8);
    sp.position.copy(_v);
    // hide tags on the far side
    const facing = _v.clone().applyMatrix4(globe.matrixWorld).normalize().dot(
      camera.position.clone().normalize()
    );
    sp.material.opacity = n.vis.v * Math.max(0, facing) *
      (selected && selected !== n ? 0.12 : 0.95);
  });

  arcGrp.children.forEach(l => {
    l.material.opacity = 0.18 + Math.sin(t * 1.8) * 0.1;
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
  camera = new THREE.PerspectiveCamera(42, W / H, 0.1, 500);
  camera.position.set(0, 0, 30);

  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'high-performance' });
  renderer.setSize(W, H);
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.15;
  el.appendChild(renderer.domElement);
  renderer.domElement.style.cursor = 'grab';

  composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  bloom = new UnrealBloomPass(new THREE.Vector2(W, H), 0.85, 0.6, 0.14);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  scene.add(new THREE.AmbientLight(0xffffff, 0.4));
  const key = new THREE.DirectionalLight(0xc3f53c, 1.5); key.position.set(6, 5, 8); scene.add(key);
  const rim = new THREE.DirectionalLight(0x4a9eff, 0.9); rim.position.set(-8, -3, -6); scene.add(rim);
  const top = new THREE.PointLight(0xa78bfa, 45, 60, 2); top.position.set(-4, 14, 4); scene.add(top);

  starfield = buildStars(); scene.add(starfield);
  halo = buildHalo(); scene.add(halo);

  globe = new THREE.Group(); scene.add(globe);
  shell = buildShell(); globe.add(shell);
  atmo = buildAtmo(); globe.add(atmo);
  arcGrp = new THREE.Group(); globe.add(arcGrp);
  tagGrp = new THREE.Group(); globe.add(tagGrp);

  nodes = []; byKey.clear();
  syncNodes(pts, false);
  bindControls(renderer.domElement);
  last = performance.now();
  animate();

  dist.jump(90); dist.set(30);   // fly in

  return API;
}

const API = {
  init,
  update(pts) { syncNodes(pts, false); if (selected) drawArcs(selected); },
  setFilter(fn) { filterFn = fn || (() => true); },
  focus(n) {
    selected = n || null;
    drawArcs(selected);
    if (selected) {
      spin = false;
      // spin the globe so the selection faces us
      const d = selected.dir;
      rot.y.set(Math.atan2(d.x, d.z));
      rot.x.set(Math.max(-1.2, Math.min(1.2, Math.asin(THREE.MathUtils.clamp(d.y, -1, 1)))));
      dist.set(Math.min(dist.t, 22));
    }
  },
  select(pred) {
    const n = pred ? nodes.find(x => pred(x.data)) : null;
    API.focus(n);
    return n ? n.data : null;
  },
  clearSelection() { selected = null; arcGrp.clear(); },
  reset() {
    rot.y.set(0.4); rot.x.set(0.18); dist.set(30);
    spin = true; selected = null; arcGrp.clear();
  },
  toggleSpin() { spin = !spin; return spin; },
  zoom(f) { dist.set(Math.max(15, Math.min(70, dist.t * f))); },
  pause(v) { running = !v; if (!v) last = performance.now(); },
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
<title>AGP Tracker</title>
<meta name="description" content="Independent real-time analytics for Agent Grand Prix.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#05070a; --bg2:#080b11; --panel:rgba(255,255,255,.028); --panel2:rgba(255,255,255,.05);
  --line:rgba(255,255,255,.07); --line2:rgba(255,255,255,.12);
  --text:#f2f5f8; --dim:#8892a4; --dim2:#535d6d;
  --acid:#c3f53c; --blue:#4a9eff; --red:#ff5f5f; --amber:#ffb340; --violet:#a78bfa;
  --sans:'Inter',-apple-system,system-ui,sans-serif;
  --mono:'JetBrains Mono',ui-monospace,Menlo,monospace;
  --ease:cubic-bezier(.16,1,.3,1);
}
*{box-sizing:border-box;margin:0;padding:0}
html{scroll-behavior:smooth;scroll-snap-type:y proximity}
body{background:var(--bg);color:var(--text);font-family:var(--sans);font-size:15px;line-height:1.6;
  -webkit-font-smoothing:antialiased;overflow-x:hidden}
::selection{background:var(--acid);color:#000}
a{color:inherit;text-decoration:none}

/* ---- ambient bg ---- */
.amb{position:fixed;inset:0;z-index:0;pointer-events:none;
  background:
    radial-gradient(ellipse 70% 50% at 15% 0%, rgba(195,245,60,.07), transparent 60%),
    radial-gradient(ellipse 60% 50% at 85% 20%, rgba(74,158,255,.06), transparent 60%),
    radial-gradient(ellipse 80% 60% at 50% 100%, rgba(167,139,250,.045), transparent 65%)}
.grain{position:fixed;inset:0;z-index:1;pointer-events:none;opacity:.16;mix-blend-mode:overlay;
  background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3'/%3E%3C/filter%3E%3Crect width='120' height='120' filter='url(%23n)'/%3E%3C/svg%3E")}

/* ---- nav ---- */
nav{position:fixed;top:0;left:0;right:0;z-index:40;padding:14px 26px;
  display:flex;align-items:center;justify-content:space-between;
  background:rgba(5,7,10,.55);backdrop-filter:blur(18px) saturate(160%);
  border-bottom:1px solid transparent;transition:border-color .4s var(--ease),background .4s var(--ease)}
nav.solid{border-bottom-color:var(--line);background:rgba(5,7,10,.82)}
.brand{display:flex;align-items:center;gap:9px;font-weight:700;font-size:15px;letter-spacing:-.3px}
.brand .mk{width:19px;height:19px;border-radius:5px;background:linear-gradient(135deg,var(--acid),#7fb800);
  box-shadow:0 0 18px rgba(195,245,60,.5)}
.brand em{font-style:normal;color:var(--acid)}
.tagx{font-family:var(--mono);font-size:8.5px;padding:2px 6px;border:1px solid var(--line2);border-radius:99px;
  color:var(--dim2);letter-spacing:.6px;text-transform:uppercase}
.nav-r{display:flex;align-items:center;gap:16px}
.nlinks{display:flex;gap:20px;font-size:12.5px;color:var(--dim);font-weight:500}
.nlinks a{position:relative;transition:color .25s}
.nlinks a:hover,.nlinks a.act{color:var(--text)}
.nlinks a.act::after{content:'';position:absolute;bottom:-5px;left:0;right:0;height:1.5px;
  background:var(--acid);border-radius:2px;box-shadow:0 0 10px var(--acid)}
.live-b{display:flex;align-items:center;gap:6px;font-family:var(--mono);font-size:10px;color:var(--dim);
  padding:4px 9px;border:1px solid var(--line);border-radius:99px}
.dot{width:5px;height:5px;border-radius:50%;background:var(--dim2);transition:.3s}
.dot.on{background:var(--acid);box-shadow:0 0 9px var(--acid);animation:bp 2s infinite}
@keyframes bp{0%,100%{opacity:1}50%{opacity:.35}}

/* ---- section rail ---- */
.rail{position:fixed;right:18px;top:50%;transform:translateY(-50%);z-index:35;
  display:flex;flex-direction:column;gap:11px}
.rail i{width:6px;height:6px;border-radius:50%;background:var(--line2);cursor:pointer;
  transition:.35s var(--ease);position:relative}
.rail i:hover{background:var(--dim)}
.rail i.act{background:var(--acid);box-shadow:0 0 12px var(--acid);transform:scale(1.5)}

/* ---- sections ---- */
main{position:relative;z-index:2}
.sec{min-height:100vh;display:flex;flex-direction:column;justify-content:center;
  padding:96px 26px 60px;max-width:1240px;margin:0 auto;
  scroll-snap-align:start;scroll-snap-stop:normal}
.sec-hd{margin-bottom:32px}
.eyebrow{font-family:var(--mono);font-size:10px;letter-spacing:2.2px;text-transform:uppercase;
  color:var(--acid);margin-bottom:11px;display:flex;align-items:center;gap:8px}
.eyebrow::before{content:'';width:20px;height:1px;background:var(--acid);opacity:.6}
h2{font-size:clamp(23px,2.9vw,34px);font-weight:600;letter-spacing:-.8px;line-height:1.15;margin-bottom:11px}
.lede{color:var(--dim);font-size:14.5px;max-width:660px;line-height:1.7}
.lede b{color:var(--text);font-weight:600}

/* reveal */
[data-rv]{opacity:0;transform:translateY(26px);transition:opacity .9s var(--ease),transform .9s var(--ease)}
[data-rv].in{opacity:1;transform:none}
[data-rv][data-d="1"]{transition-delay:.08s} [data-rv][data-d="2"]{transition-delay:.16s}
[data-rv][data-d="3"]{transition-delay:.24s} [data-rv][data-d="4"]{transition-delay:.32s}
[data-rv][data-d="5"]{transition-delay:.4s}

/* ---- hero ---- */
.hero{min-height:100vh;display:flex;flex-direction:column;justify-content:center;align-items:center;
  text-align:center;padding:110px 26px 70px;position:relative;scroll-snap-align:start}
.hero h1{font-size:clamp(38px,6.6vw,78px);font-weight:700;letter-spacing:-2.4px;line-height:1;
  margin-bottom:18px}
.hero h1 .g{background:linear-gradient(120deg,var(--acid) 0%,#8fd400 45%,var(--blue) 100%);
  -webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;
  filter:drop-shadow(0 0 44px rgba(195,245,60,.28))}
.hero p{color:var(--dim);font-size:16px;max-width:530px;margin-bottom:38px;line-height:1.75}
.hstat{display:flex;gap:0;flex-wrap:wrap;justify-content:center;margin-bottom:40px;
  border:1px solid var(--line);border-radius:14px;overflow:hidden;
  background:var(--panel);backdrop-filter:blur(14px)}
.hstat div{padding:18px 30px;border-right:1px solid var(--line);min-width:118px}
.hstat div:last-child{border-right:none}
.hstat .n{font-family:var(--mono);font-size:27px;font-weight:700;letter-spacing:-1px;
  font-variant-numeric:tabular-nums;line-height:1}
.hstat .l{font-size:9.5px;color:var(--dim);text-transform:uppercase;letter-spacing:1.4px;margin-top:7px}
.cue{position:absolute;bottom:34px;left:50%;transform:translateX(-50%);
  font-family:var(--mono);font-size:9.5px;color:var(--dim2);letter-spacing:1.8px;text-transform:uppercase;
  display:flex;flex-direction:column;align-items:center;gap:9px}
.cue .ln{width:1px;height:30px;background:linear-gradient(var(--acid),transparent);animation:fall 2.2s infinite}
@keyframes fall{0%{transform:scaleY(0);transform-origin:top}45%{transform:scaleY(1);transform-origin:top}
  55%{transform:scaleY(1);transform-origin:bottom}100%{transform:scaleY(0);transform-origin:bottom}}

/* ---- glass ---- */
.glass{background:var(--panel);border:1px solid var(--line);border-radius:14px;
  backdrop-filter:blur(16px) saturate(150%);transition:.45s var(--ease)}
.glass:hover{border-color:var(--line2);background:var(--panel2);transform:translateY(-2px)}

.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));gap:12px}
.card{padding:18px}
.card .k{font-family:var(--mono);font-size:9.5px;color:var(--dim);text-transform:uppercase;letter-spacing:1.3px}
.card .v{font-family:var(--mono);font-size:29px;font-weight:700;margin-top:8px;letter-spacing:-1.2px;
  font-variant-numeric:tabular-nums;line-height:1}
.card .n{font-size:11px;color:var(--dim2);margin-top:6px}

/* ---- galaxy ---- */
.gsec{padding-top:82px;padding-bottom:34px}
.gwrap{position:relative;border:1px solid var(--line);border-radius:18px;overflow:hidden;
  background:radial-gradient(ellipse at 50% 50%,#0b1220 0%,#04060a 75%);
  box-shadow:0 30px 90px rgba(0,0,0,.55), inset 0 1px 0 rgba(255,255,255,.04)}
#galaxy{width:100%;height:min(70vh,620px)}
#galaxy canvas{display:block}
.gbar{position:absolute;top:13px;left:13px;right:13px;display:flex;gap:7px;align-items:center;
  flex-wrap:wrap;z-index:6;pointer-events:none}
.gbar>*{pointer-events:auto}
.gl{background:rgba(5,7,10,.7);backdrop-filter:blur(14px);border:1px solid var(--line2);border-radius:9px}
.srch{display:flex;align-items:center;gap:7px;padding:6px 10px}
.srch input{background:none;border:none;color:var(--text);font-family:var(--mono);font-size:11px;
  width:118px;outline:none}
.srch input::placeholder{color:var(--dim2)}
.chips{display:flex;gap:5px}
.chip{font-family:var(--mono);font-size:10px;padding:6px 10px;border-radius:8px;cursor:pointer;
  border:1px solid var(--line2);background:rgba(5,7,10,.7);backdrop-filter:blur(14px);color:var(--dim);
  transition:.3s var(--ease);white-space:nowrap;user-select:none}
.chip:hover{color:var(--text);border-color:var(--dim2)}
.chip.on{color:#000;font-weight:700}
.chip.on.c-fin{background:var(--acid);border-color:var(--acid)}
.chip.on.c-sc{background:var(--blue);border-color:var(--blue)}
.chip.on.c-ze{background:#5b6470;border-color:#5b6470;color:var(--text)}
.gr{margin-left:auto;display:flex;gap:5px}
button{background:rgba(5,7,10,.7);backdrop-filter:blur(14px);color:var(--text);border:1px solid var(--line2);
  border-radius:9px;padding:6px 10px;font-family:var(--mono);font-size:10.5px;cursor:pointer;
  transition:.3s var(--ease)}
button:hover{border-color:var(--acid);color:var(--acid)}
button:disabled{opacity:.4;cursor:wait}
button.on{border-color:var(--acid);color:var(--acid);background:rgba(195,245,60,.1)}
.hint{position:absolute;bottom:12px;left:16px;font-family:var(--mono);font-size:9.5px;color:var(--dim2);
  z-index:4;pointer-events:none}
.glg{position:absolute;bottom:12px;right:16px;display:flex;gap:13px;font-family:var(--mono);font-size:9.5px;
  color:var(--dim);z-index:4;pointer-events:none;flex-wrap:wrap;justify-content:flex-end}
.glg b{display:inline-block;width:6px;height:6px;border-radius:50%;margin-right:5px;vertical-align:0}
.tl{position:absolute;bottom:32px;left:16px;right:16px;z-index:5;display:flex;align-items:center;gap:9px;
  padding:7px 11px;opacity:0;transform:translateY(8px);transition:.35s var(--ease);pointer-events:none}
.tl.on{opacity:1;transform:none;pointer-events:auto}
.tl input[type=range]{flex:1;accent-color:var(--acid);height:3px;cursor:pointer}
.tl .lbl{font-family:var(--mono);font-size:9.5px;color:var(--acid);min-width:126px;white-space:nowrap}

/* ---- tip / card ---- */
#htip{position:fixed;pointer-events:none;z-index:60;background:rgba(5,7,10,.95);border:1px solid var(--acid);
  border-radius:8px;padding:7px 10px;font-family:var(--mono);font-size:10.5px;opacity:0;
  transition:opacity .18s var(--ease);white-space:nowrap;box-shadow:0 10px 30px rgba(0,0,0,.6)}
#htip b{color:var(--acid)}
.dcard{position:fixed;width:300px;background:rgba(8,11,17,.9);backdrop-filter:blur(22px) saturate(170%);
  border:1px solid rgba(195,245,60,.4);border-radius:15px;z-index:50;opacity:0;transform:scale(.95) translateY(8px);
  transition:opacity .35s var(--ease),transform .35s var(--ease);pointer-events:none;
  box-shadow:0 26px 70px rgba(0,0,0,.8),0 0 0 1px rgba(195,245,60,.07),inset 0 1px 0 rgba(255,255,255,.06)}
.dcard.on{opacity:1;transform:none;pointer-events:auto}
.dcard .gb{padding:11px 12px;border-bottom:1px solid var(--line);cursor:grab;display:flex;align-items:center;gap:9px}
.dcard .gb:active{cursor:grabbing}
.dcard .gb img{width:29px;height:29px;border-radius:50%;flex:none;background:var(--panel2)}
.dcard .gb .nm{flex:1;min-width:0}
.dcard .gb a{color:var(--acid);font-weight:700;font-size:13px;display:block;overflow:hidden;
  text-overflow:ellipsis;white-space:nowrap;font-family:var(--mono)}
.dcard .gb .st{font-size:9.5px;color:var(--dim);margin-top:2px}
.dcard .x{cursor:pointer;color:var(--dim2);font-size:16px;line-height:1;padding:0 3px;transition:.2s}
.dcard .x:hover{color:var(--red)}
.dcard .bd{padding:11px 12px;max-height:min(56vh,440px);overflow-y:auto}
.dcard .bd::-webkit-scrollbar{width:4px}
.dcard .bd::-webkit-scrollbar-thumb{background:var(--line2);border-radius:3px}
.row{display:flex;justify-content:space-between;gap:10px;padding:3px 0;font-family:var(--mono);
  font-size:11px;color:var(--dim)}
.row span:last-child{color:var(--text);font-weight:500;text-align:right}
.grp{font-family:var(--mono);font-size:9px;color:var(--dim2);text-transform:uppercase;letter-spacing:1.3px;
  margin:11px 0 5px;padding-top:9px;border-top:1px solid var(--line)}
.grp:first-child{margin-top:0;padding-top:0;border-top:none}
.mini{height:3px;background:rgba(255,255,255,.07);border-radius:2px;overflow:hidden;margin:6px 0 3px}
.mini i{display:block;height:100%;background:var(--acid);transition:width .8s var(--ease);
  box-shadow:0 0 8px var(--acid)}
.split{display:flex;height:5px;border-radius:3px;overflow:hidden;margin:6px 0 4px}
.split i{height:100%;transition:width .8s var(--ease)}
.hrow{display:flex;justify-content:space-between;gap:8px;font-family:var(--mono);font-size:10px;
  padding:5px 7px;border-radius:6px;background:rgba(255,255,255,.03);margin-bottom:3px;cursor:pointer;
  transition:.25s var(--ease);border:1px solid transparent}
.hrow:hover{border-color:var(--line2);background:var(--panel2);transform:translateX(2px)}
.hrow .w{color:var(--acid);font-weight:700}
.hrow .d{color:var(--dim2)}

/* ---- tables ---- */
.tbl{border:1px solid var(--line);border-radius:14px;overflow:hidden;background:var(--panel);
  backdrop-filter:blur(14px)}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-family:var(--mono);font-size:9px;color:var(--dim2);text-transform:uppercase;
  letter-spacing:1.3px;padding:11px 13px;border-bottom:1px solid var(--line);font-weight:500}
td{padding:9px 13px;border-bottom:1px solid rgba(255,255,255,.04);font-size:12.5px;vertical-align:middle;
  font-family:var(--mono)}
tr:last-child td{border-bottom:none}
tbody tr{cursor:pointer;transition:.22s var(--ease)}
tbody tr:hover{background:var(--panel2)}
tbody tr:hover td:first-child{box-shadow:inset 2px 0 0 var(--acid)}
.num{text-align:right;font-variant-numeric:tabular-nums}
.win{color:var(--acid);font-weight:700}
.dim{color:var(--dim2)}
.ghost{color:var(--red);font-size:9.5px}
.who{display:flex;align-items:center;gap:8px}
.who img{width:20px;height:20px;border-radius:50%;background:var(--panel2);flex:none;transition:.3s}
tbody tr:hover .who img{transform:scale(1.14)}
.tag{font-family:var(--mono);font-size:9px;padding:2px 6px;border-radius:5px;border:1px solid;white-space:nowrap}
.t-asker{color:var(--acid);border-color:rgba(195,245,60,.32)}
.t-guesser{color:var(--amber);border-color:rgba(255,179,64,.32)}
.t-balanced{color:var(--blue);border-color:rgba(74,158,255,.32)}
.t-ghost{color:var(--red);border-color:rgba(255,95,95,.3)}
.t-spammer{color:var(--violet);border-color:rgba(167,139,250,.32)}
.pill{font-family:var(--mono);font-size:9px;padding:2px 6px;border-radius:5px;
  background:rgba(255,255,255,.05);border:1px solid var(--line);color:var(--dim2)}
.pill.live{color:var(--acid);border-color:rgba(195,245,60,.4);background:rgba(195,245,60,.09)}
.bar{height:3px;background:rgba(255,255,255,.07);border-radius:2px;overflow:hidden;width:38px}
.bar i{display:block;height:100%;background:var(--acid);transition:width .9s var(--ease)}

.ins{display:flex;flex-direction:column;gap:8px}
.insight{padding:13px 16px;border-left:2px solid var(--amber);border-radius:0 11px 11px 0;
  background:var(--panel);backdrop-filter:blur(14px);font-size:13px;transition:.35s var(--ease)}
.insight:hover{background:var(--panel2);transform:translateX(3px)}
.insight .t{font-family:var(--mono);font-size:9px;color:var(--amber);text-transform:uppercase;
  letter-spacing:1.3px;margin-bottom:4px}
.styles{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}
.sty{padding:16px}
.sty .r{font-family:var(--mono);font-size:25px;font-weight:700;margin:9px 0 3px;letter-spacing:-1px}
.sty .n{font-size:10.5px;color:var(--dim2);font-family:var(--mono)}
.note{padding:11px 15px;border-left:2px solid var(--blue);border-radius:0 10px 10px 0;
  background:var(--panel);font-size:12.5px;color:var(--dim);margin-bottom:20px;backdrop-filter:blur(14px)}
.note b{color:var(--text)}
.note.live{border-left-color:var(--acid)}
select{background:rgba(255,255,255,.03);color:var(--text);border:1px solid var(--line);border-radius:9px;
  padding:9px 12px;font-family:var(--mono);font-size:12px;margin-bottom:12px;width:100%;max-width:300px;
  outline:none;cursor:pointer}
.loading,.err{padding:70px;text-align:center;color:var(--dim2);font-family:var(--mono);font-size:12px}
.err{color:var(--red)}
.foot{padding:26px;text-align:center;font-family:var(--mono);font-size:9.5px;color:var(--dim2);
  border-top:1px solid var(--line);margin-top:40px}

@media(max-width:820px){
  .rail{display:none} .nlinks{display:none}
  .sec{padding:82px 15px 44px} .hero{padding:98px 15px 60px}
  #galaxy{height:52vh}
  td,th{padding:8px 7px;font-size:11px}
  .hide-m{display:none}
  .dcard{width:calc(100vw - 22px);left:11px!important}
  .glg{display:none}
  .hstat div{padding:14px 20px;min-width:96px}
  .hstat .n{font-size:21px}
}
</style>
</head>
<body>
<div class="amb"></div><div class="grain"></div>

<nav id="nav">
  <a class="brand" href="#top"><span class="mk"></span>AGP <em>TRACKER</em>
    <span class="tagx" title="Community project. Not affiliated with Subzero Labs.">unofficial</span></a>
  <div class="nav-r">
    <div class="nlinks" id="nlinks">
      <a href="#galaxy-s" data-s="1">Globe</a>
      <a href="#read-s" data-s="2">Signals</a>
      <a href="#board-s" data-s="3">Standings</a>
      <a href="#races-s" data-s="4">Races</a>
    </div>
    <div class="live-b"><span class="dot" id="dot"></span><span id="conn">connecting</span></div>
    <button id="refresh">↻</button>
  </div>
</nav>

<div class="rail" id="rail">
  <i data-go="0"></i><i data-go="1"></i><i data-go="2"></i><i data-go="3"></i><i data-go="4"></i>
</div>

<main id="app"><div class="loading">initialising…</div></main>
<div id="htip"></div>
<div class="dcard" id="card"><div class="gb" id="grab"></div><div class="bd" id="cardbd"></div></div>

<script type="importmap">
{"imports":{
  "three":"https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js",
  "three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"
}}
</script>
<script type="module" src="/galaxy.js"></script>
<script>
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fmtTime=ms=>{if(!ms)return'—';const s=Math.round(ms/1000);
  return s>3600?`${Math.floor(s/3600)}h${Math.floor(s%3600/60)}m`:s>60?`${Math.floor(s/60)}m${s%60}s`:`${s}s`};
const fmtDate=d=>new Date(d).toLocaleDateString('en-US',{month:'short',day:'numeric'});
const ago=d=>{const n=Math.floor((Date.now()-new Date(d))/864e5);
  return n===0?'today':n===1?'yesterday':`${n} days ago`};
const avatar=l=>`https://github.com/${encodeURIComponent(l)}.png?size=48`;
const ghUrl=l=>`https://github.com/${encodeURIComponent(l)}`;
const who=l=>`<span class="who"><img src="${avatar(l)}" alt="" loading="lazy"
  onerror="this.style.visibility='hidden'">${esc(l)}</span>`;

let DATA=null, GAL=null, ES=null, BUILT=false;
const F={fin:true,sc:true,ze:true,q:'',race:null};

/* ---- animated counter ---- */
function countTo(el,to,dec=0,pre='',suf=''){
  const from=parseFloat(el.dataset.v||0); if(from===to){el.textContent=pre+to.toFixed(dec)+suf;return}
  el.dataset.v=to; const t0=performance.now(), dur=1100;
  const tick=n=>{
    const p=Math.min(1,(n-t0)/dur), e=1-Math.pow(1-p,4);
    el.textContent=pre+(from+(to-from)*e).toFixed(dec)+suf;
    if(p<1) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

/* ---- reveal ---- */
const rv=new IntersectionObserver(es=>es.forEach(e=>{
  if(e.isIntersecting){ e.target.classList.add('in');
    e.target.querySelectorAll?.('[data-cnt]').forEach(c=>{
      countTo(c,+c.dataset.cnt,+(c.dataset.dec||0),c.dataset.pre||'',c.dataset.suf||'');
    });
  }
}),{threshold:.12,rootMargin:'0px 0px -8% 0px'});
const watchRv=()=>$$('[data-rv]').forEach(e=>rv.observe(e));

/* ---- data ---- */
function connect(){
  if(ES)ES.close();
  ES=new EventSource('/api/stream');
  ES.addEventListener('data',e=>{
    DATA=JSON.parse(e.data); paint();
    $('#dot').classList.add('on'); $('#conn').textContent='live';
  });
  ES.onerror=()=>{ $('#dot').classList.remove('on'); $('#conn').textContent='reconnecting';
    setTimeout(()=>{if(ES.readyState===2)connect()},4000); };
}
async function forceSync(){
  const b=$('#refresh'); b.disabled=true; b.textContent='⋯';
  try{await fetch('/api/sync',{method:'POST'})}catch{}
  b.disabled=false; b.textContent='↻';
}

function paint(){ if(!DATA)return; if(!BUILT){build();BUILT=true;} else refresh(); }

/* ---- build ---- */
function build(){
  const {overview:o,races:r}=DATA;
  const live=r.filter(x=>!x.over).length, last=r[0];

  $('#app').innerHTML=`
  <section class="hero sec" id="top">
    <h1 data-rv>AGP <span class="g">TRACKER</span></h1>
    <p data-rv data-d="1">Race data for Agent Grand Prix. Reads the public API, works out the numbers
      the leaderboard doesn't show.</p>
    <div class="hstat" data-rv data-d="2" id="hstat"></div>
    <div class="cue"><span>scroll</span><span class="ln"></span></div>
  </section>

  <section class="sec gsec" id="galaxy-s">
    <div class="sec-hd">
      <div class="eyebrow" data-rv>the globe</div>
      <h2 data-rv data-d="1">Every racer</h2>
      <p class="lede" data-rv data-d="2">One star per racer per race, spread evenly across the sphere.
        Winners sit near the top, ghosts near the bottom. Size = spend.
        Height above the surface = points reached.<br>
        <b>Drag to spin · ⌘/ctrl + scroll to zoom · click a star for details.</b></p>
    </div>
    <div class="gwrap" data-rv data-d="3">
      <div id="galaxy"></div>
      <div class="gbar">
        <div class="gl srch"><span style="color:var(--dim2)">⌕</span>
          <input id="q" placeholder="search racer" autocomplete="off"></div>
        <div class="chips">
          <span class="chip c-fin on" data-f="fin">finished</span>
          <span class="chip c-sc on" data-f="sc">scored</span>
          <span class="chip c-ze on" data-f="ze">zero</span>
        </div>
        <div class="gr">
          <button id="g-tl">⏱</button><button id="g-in">＋</button><button id="g-out">−</button>
          <button id="g-spin">⏸</button><button id="g-reset">⌖</button>
        </div>
      </div>
      <div class="tl gl" id="tl">
        <button id="tl-play">▶</button>
        <input type="range" id="tl-r" min="0" max="0" value="0">
        <span class="lbl" id="tl-l"></span>
        <button id="tl-all">all</button>
      </div>
      <div class="hint" id="hint"></div>
      <div class="glg"><span><b style="background:var(--acid)"></b>finished</span>
        <span><b style="background:#4a9eff"></b>scored</span>
        <span><b style="background:#5d6878"></b>zero</span></div>
    </div>
  </section>

  <section class="sec" id="read-s">
    <div class="sec-hd">
      <div class="eyebrow" data-rv>signals</div>
      <h2 data-rv data-d="1">What the numbers say</h2>
      <p class="lede" data-rv data-d="2">Worked out from the data. Updates when new races land.</p>
    </div>
    ${live?`<div class="note live" data-rv><b>${live} race live.</b> Streaming in real time.</div>`:
      last?`<div class="note" data-rv><b>No race running.</b> Last was <b>${esc(last.name)}</b>, ${ago(last.startsAt)}. New circuits appear automatically.</div>`:''}
    <div class="ins" data-rv data-d="3" id="ins"></div>
    <div style="margin-top:34px">
      <div class="eyebrow" data-rv>playstyle</div>
      <h2 style="font-size:clamp(20px,2.4vw,28px);margin-bottom:8px" data-rv data-d="1">Asking vs guessing</h2>
      <p class="lede" data-rv data-d="2" style="margin-bottom:16px">Grouped by guess-to-question ratio.</p>
      <div class="styles" data-rv data-d="3" id="styles"></div>
    </div>
  </section>

  <section class="sec" id="board-s">
    <div class="sec-hd">
      <div class="eyebrow" data-rv>standings</div>
      <h2 data-rv data-d="1">Racers</h2>
      <p class="lede" data-rv data-d="2">Ranked by wins, then points, then cost per win.
        Click a row to find them in the galaxy.</p>
    </div>
    <div class="cards" data-rv data-d="3" id="stats" style="margin-bottom:16px"></div>
    <div class="tbl" data-rv data-d="4"><table><thead><tr>
      <th>#</th><th>racer</th><th class="hide-m">style</th><th class="num">races</th>
      <th class="num">wins</th><th class="num">pts</th><th class="num">q</th>
      <th class="num hide-m">g</th><th class="num hide-m">g:q</th><th class="num">spend</th>
      <th class="num hide-m">$/win</th></tr></thead><tbody id="stand"></tbody></table></div>
  </section>

  <section class="sec" id="races-s">
    <div class="sec-hd">
      <div class="eyebrow" data-rv>races</div>
      <h2 data-rv data-d="1">Every race</h2>
      <p class="lede" data-rv data-d="2"><b>real</b> = how many on the grid actually asked a question.</p>
    </div>
    <div class="tbl" data-rv data-d="3" style="margin-bottom:26px"><table><thead><tr>
      <th>race</th><th class="hide-m">date</th><th class="hide-m">diff</th><th class="num">grid</th>
      <th class="num">real</th><th>winner</th><th class="num">spend</th></tr></thead>
      <tbody id="racelist"></tbody></table></div>
    <div data-rv data-d="4">
      <div class="eyebrow">classification</div>
      <select id="pick"></select>
      <div class="tbl" id="detail"></div>
    </div>
    <div class="foot">public AGP API · avatars via GitHub ·
      <a href="https://agp.onlatch.com" target="_blank" rel="noopener" style="color:var(--dim)">agp.onlatch.com</a></div>
  </section>`;

  const boot3d=()=>{
    GAL=window.AGP3D.init($('#galaxy'),DATA.pareto,{
      onSelect:d=>d?openCard(d):closeCard(), onHover:(d,e)=>hoverTip(d,e)
    });
    applyFilter();
    // pause the render loop when the galaxy is offscreen — saves battery, keeps 60fps
    new IntersectionObserver(es=>GAL.pause(!es[0].isIntersecting),{threshold:.02}).observe($('#galaxy'));
  };
  if(window.AGP3D)boot3d(); else window.addEventListener('agp3d-ready',boot3d,{once:true});
  addEventListener('resize',()=>GAL&&GAL.resize());

  wire(); refresh(); watchRv(); initScroll();
}

function refresh(){
  const {overview:o,standings:s,races:r,insights:ins,styles}=DATA;

  const hs=$('#hstat');
  if(hs&&!hs.dataset.done){
    hs.innerHTML=`
      <div><div class="n" data-cnt="${o.races}">0</div><div class="l">races</div></div>
      <div><div class="n" data-cnt="${o.entries}">0</div><div class="l">entries</div></div>
      <div><div class="n" style="color:var(--acid)" data-cnt="${o.participationPct}" data-suf="%">0</div><div class="l">actually raced</div></div>
      <div><div class="n" data-cnt="${o.spend}" data-dec="2" data-pre="$">0</div><div class="l">real usdc</div></div>`;
    hs.dataset.done='1';
  }

  $('#stats').innerHTML=`
    <div class="glass card"><div class="k">unique racers</div>
      <div class="v" data-cnt="${o.uniquePlayers}">0</div><div class="n">${o.entries} total entries</div></div>
    <div class="glass card"><div class="k">ghosts</div>
      <div class="v" style="color:var(--red)" data-cnt="${o.ghosts}">0</div><div class="n">never asked once</div></div>
    <div class="glass card"><div class="k">questions</div>
      <div class="v" data-cnt="${o.questions}">0</div><div class="n">${o.guesses.toLocaleString()} guesses</div></div>
    <div class="glass card"><div class="k">finishers</div>
      <div class="v" style="color:var(--acid)" data-cnt="${o.finishers}">0</div><div class="n">crossed the FIN</div></div>
    <div class="glass card"><div class="k">on guesses</div>
      <div class="v" style="color:var(--amber)" data-cnt="${o.guessSpendPct}" data-suf="%">0</div><div class="n">of all spend</div></div>`;

  $('#ins').innerHTML=ins.map(i=>
    `<div class="insight"><div class="t">${esc(i.tag)}</div>${esc(i.text)}</div>`).join('');

  $('#styles').innerHTML=(styles||[]).map(g=>
    `<div class="glass sty"><div><span class="tag t-${g.key}">${esc(g.label)}</span></div>
      <div class="r">${g.wins}<span style="font-size:11px;color:var(--dim2);font-weight:400"> wins</span></div>
      <div class="n">${g.players} racers · ${g.races} entries · ${g.winRate}% win rate</div>
      <div class="n" style="margin-top:4px;color:var(--dim)">${esc(g.note)}</div></div>`).join('');

  $('#stand').innerHTML=s.slice(0,30).map((p,i)=>
    `<tr data-login="${esc(p.login)}"><td class="dim">${i+1}</td>
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
  $$('#stand tr').forEach(tr=>tr.onclick=()=>{
    document.getElementById('galaxy-s').scrollIntoView({behavior:'smooth'});
    setTimeout(()=>flyTo(tr.dataset.login),620);
  });

  $('#racelist').innerHTML=r.map(t=>
    `<tr data-race="${t.id}"><td>${esc(t.name)} ${t.over?'<span class="pill">over</span>':'<span class="pill live">live</span>'}</td>
      <td class="dim hide-m">${fmtDate(t.startsAt)}</td>
      <td class="dim hide-m">${esc(t.difficulty)}</td>
      <td class="num">${t.grid}</td>
      <td class="num"><div style="display:flex;align-items:center;gap:6px;justify-content:flex-end">
        <span>${t.active}</span><div class="bar"><i style="width:${t.participationPct}%"></i></div></div></td>
      <td class="win">${t.winner?who(t.winner):'<span class="dim">nobody</span>'}</td>
      <td class="num">$${t.spend.toFixed(2)}</td></tr>`).join('');
  $$('#racelist tr').forEach(tr=>tr.onclick=()=>{ $('#pick').value=tr.dataset.race; showDetail(tr.dataset.race);
    $('#pick').scrollIntoView({block:'center',behavior:'smooth'}); });

  const pick=$('#pick'), cur=pick.value;
  pick.innerHTML=r.map(t=>`<option value="${t.id}">${esc(t.name)}</option>`).join('');
  if(cur&&r.some(t=>t.id===cur))pick.value=cur;
  showDetail(pick.value);
  $('#tl-r').max=r.length-1;

  if(GAL){ GAL.update(DATA.pareto); applyFilter(); }
  watchRv();
}

/* ---- filters ---- */
function applyFilter(){
  if(!GAL)return;
  const q=F.q.toLowerCase();
  GAL.setFilter(d=>{
    if(F.race&&d.race!==F.race)return false;
    if(q&&!d.login.toLowerCase().includes(q))return false;
    if(d.finished)return F.fin;
    if(d.points>0)return F.sc;
    return F.ze;
  });
  $('#hint').textContent=`${GAL.count()} / ${DATA.pareto.length} stars${F.race?' · '+F.race:''}`;
}

function wire(){
  $('#q').oninput=e=>{F.q=e.target.value.trim();applyFilter()};
  $$('.chip').forEach(c=>c.onclick=()=>{F[c.dataset.f]=!F[c.dataset.f];
    c.classList.toggle('on',F[c.dataset.f]);applyFilter()});

  const spin=$('#g-spin');
  spin.onclick=()=>{if(GAL)spin.textContent=GAL.toggleSpin()?'⏸':'▶'};
  $('#g-reset').onclick=()=>{if(GAL)GAL.reset();closeCard()};
  $('#g-in').onclick=()=>GAL&&GAL.zoom(.75);
  $('#g-out').onclick=()=>GAL&&GAL.zoom(1.33);

  const tl=$('#tl'),tlr=$('#tl-r'),tll=$('#tl-l'),tlp=$('#tl-play');
  let playing=null;
  const setRace=i=>{const r=DATA.races[DATA.races.length-1-i]; if(!r)return;
    F.race=r.name; tll.textContent=`${fmtDate(r.startsAt)} · ${r.name}`; tlr.value=i; applyFilter()};
  const stop=()=>{if(playing){clearInterval(playing);playing=null;tlp.textContent='▶'}};
  $('#g-tl').onclick=()=>{const on=tl.classList.toggle('on'); $('#g-tl').classList.toggle('on',on);
    if(!on){F.race=null;applyFilter();stop()} else setRace(+tlr.value)};
  tlr.oninput=e=>setRace(+e.target.value);
  tlp.onclick=()=>{ if(playing)return stop(); tlp.textContent='⏸';
    playing=setInterval(()=>{let i=+tlr.value+1; if(i>+tlr.max)i=0; setRace(i)},1700)};
  $('#tl-all').onclick=()=>{stop();F.race=null;tll.textContent='all races';applyFilter()};

  $('#pick').onchange=e=>showDetail(e.target.value);
  $('#refresh').onclick=forceSync;
  makeDraggable();
}

/* ---- scroll ---- */
function initScroll(){
  const secs=[...document.querySelectorAll('.sec')];
  const dots=$$('.rail i'), links=$$('#nlinks a');
  const io=new IntersectionObserver(es=>{
    es.forEach(e=>{
      if(!e.isIntersecting)return;
      const i=secs.indexOf(e.target);
      dots.forEach((d,n)=>d.classList.toggle('act',n===i));
      links.forEach(l=>l.classList.toggle('act',+l.dataset.s===i));
    });
  },{threshold:.4});
  secs.forEach(s=>io.observe(s));
  dots.forEach((d,i)=>d.onclick=()=>secs[i]?.scrollIntoView({behavior:'smooth'}));
  addEventListener('scroll',()=>$('#nav').classList.toggle('solid',scrollY>60),{passive:true});
}

/* ---- hover ---- */
function hoverTip(d,e){
  const t=$('#htip');
  if(!d){t.style.opacity=0;return}
  const gq=d.questions?(d.guesses/d.questions).toFixed(2):'—';
  t.innerHTML=`<b>${esc(d.login)}</b> · ${d.finished?'FIN':d.points+'/'+d.pointCount} · ${d.questions}q ${d.guesses}g · $${d.spend.toFixed(3)}`;
  t.style.left=(e.clientX+15)+'px'; t.style.top=(e.clientY-30)+'px'; t.style.opacity=1;
}

/* ---- card ---- */
async function openCard(d){
  const c=$('#card');
  if(!c.dataset.placed){
    const g=$('#galaxy').getBoundingClientRect();
    c.style.left=(g.left+16)+'px'; c.style.top=(Math.max(70,g.top+62))+'px'; c.dataset.placed='1';
  }
  c.classList.add('on');
  $('#grab').innerHTML=`<img src="${avatar(d.login)}" alt="" onerror="this.style.visibility='hidden'">
    <span class="nm"><a href="${ghUrl(d.login)}" target="_blank" rel="noopener">${esc(d.login)}</a>
    <span class="st">loading…</span></span><span class="x" onclick="closeCard()">×</span>`;

  const qC=d.questions*0.001, gC=d.spend-qC;
  const pct=d.finished?100:Math.round(d.points/d.pointCount*100);
  const gq=d.questions?(d.guesses/d.questions).toFixed(2):'—';

  $('#cardbd').innerHTML=`
    <div class="grp">this attempt · ${esc(d.race)}</div>
    <div class="row"><span>result</span><span style="color:${d.finished?'var(--acid)':'var(--text)'}">${d.finished?'FINISHED':d.points+'/'+d.pointCount+' pts'}</span></div>
    <div class="mini"><i style="width:${pct}%"></i></div>
    <div class="row"><span>questions</span><span>${d.questions}</span></div>
    <div class="row"><span>guesses</span><span>${d.guesses}</span></div>
    <div class="row"><span>g:q ratio</span><span>${gq}</span></div>
    <div class="grp">spend split</div>
    <div class="split"><i style="background:var(--acid);width:${d.spend?qC/d.spend*100:0}%"></i>
      <i style="background:var(--amber);width:${d.spend?gC/d.spend*100:0}%"></i></div>
    <div class="row"><span style="color:var(--acid)">questions</span><span>$${qC.toFixed(3)}</span></div>
    <div class="row"><span style="color:var(--amber)">guesses</span><span>$${gC.toFixed(3)}</span></div>
    <div class="row"><span>total</span><span>$${d.spend.toFixed(3)}</span></div>
    <div id="prof"><div class="grp">career</div><div class="row"><span>loading…</span><span></span></div></div>`;

  try{
    const p=await(await fetch(`/api/racer/${encodeURIComponent(d.login)}`)).json();
    $('#grab').querySelector('.st').innerHTML=`<span class="tag t-${p.style.key}">${esc(p.style.label)}</span> · ${p.races} races`;
    $('#prof').innerHTML=`
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
      ${p.history.map(h=>`<div class="hrow" data-r="${esc(h.race)}">
        <span class="${h.finished?'w':''}">${h.finished?'🏁 ':''}${esc(h.race)}</span>
        <span class="d">${h.points}/${h.pointCount} · ${h.questions}q · $${h.spend.toFixed(2)}</span></div>`).join('')}`;
    $$('#prof .hrow').forEach(el=>el.onclick=()=>{F.race=el.dataset.r;
      $('#tl').classList.add('on'); $('#g-tl').classList.add('on'); applyFilter()});
  }catch{}
}
function closeCard(){ $('#card').classList.remove('on'); GAL&&GAL.clearSelection(); }
function flyTo(login){ if(!GAL)return; const d=GAL.select(x=>x.login===login); if(d)openCard(d); }

function makeDraggable(){
  const c=$('#card'), h=$('#grab');
  let dr=null;
  h.addEventListener('pointerdown',e=>{
    if(e.target.classList.contains('x')||e.target.tagName==='A')return;
    h.setPointerCapture(e.pointerId);
    const r=c.getBoundingClientRect(); dr={dx:e.clientX-r.left,dy:e.clientY-r.top};
  });
  h.addEventListener('pointermove',e=>{
    if(!dr)return;
    c.style.left=Math.max(6,Math.min(innerWidth-c.offsetWidth-6,e.clientX-dr.dx))+'px';
    c.style.top=Math.max(6,Math.min(innerHeight-70,e.clientY-dr.dy))+'px';
  });
  h.addEventListener('pointerup',e=>{dr=null;try{h.releasePointerCapture(e.pointerId)}catch{}});
}

async function showDetail(id){
  if(!id)return;
  const d=await(await fetch(`/api/races/${id}`)).json();
  $('#detail').innerHTML=`<table><thead><tr><th>pos</th><th>racer</th><th class="num">points</th>
    <th class="num">q</th><th class="num hide-m">g</th><th class="num hide-m">g:q</th>
    <th class="num">spend</th><th class="num hide-m">time</th></tr></thead><tbody>`+
    d.racers.map((r,i)=>`<tr data-login="${esc(r.login)}"><td class="dim">P${i+1}</td>
      <td class="${r.finished?'win':r.idle?'dim':''}">${who(r.login)}${r.idle?' <span class="ghost">never raced</span>':''}</td>
      <td class="num">${r.finished?'<span class="win">FIN</span>':r.points+'/'+d.track.point_count}</td>
      <td class="num">${r.questions}</td><td class="num dim hide-m">${r.guesses}</td>
      <td class="num dim hide-m">${r.gq??'—'}</td><td class="num">$${r.spend.toFixed(3)}</td>
      <td class="num dim hide-m">${r.finished?fmtTime(r.durationMs):'—'}</td></tr>`).join('')+
    `</tbody></table>`;
  $$('#detail tr').forEach(tr=>tr.onclick=()=>{
    document.getElementById('galaxy-s').scrollIntoView({behavior:'smooth'});
    setTimeout(()=>flyTo(tr.dataset.login),620);
  });
}

fetch('/api/all').then(r=>r.json()).then(d=>{DATA=d;paint();connect();})
  .catch(e=>$('#app').innerHTML=`<div class="err">Couldn't load — is the server running?<br><br>${esc(e.message)}</div>`);
</script>
</body>
</html>
HTML_EOF
echo "-> syntax check"
node --check src/server.js
node --check src/agp.js
node --input-type=module --check < public/galaxy.js
echo ""
echo "=== v10 verification ==="
grep -q "function fib"              public/galaxy.js  && echo "  [ok] fibonacci lattice"  || echo "  [FAIL] lattice"
grep -q "buildShell"                public/galaxy.js  && echo "  [ok] globe shell"        || echo "  [FAIL] shell"
grep -q "ShaderMaterial"            public/galaxy.js  && echo "  [ok] atmosphere"         || echo "  [FAIL] atmosphere"
grep -q "QuadraticBezierCurve3"     public/galaxy.js  && echo "  [ok] race arcs"          || echo "  [FAIL] arcs"
grep -q "UnrealBloomPass"           public/galaxy.js  && echo "  [ok] bloom"              || echo "  [FAIL] bloom"
grep -q "rot.y.jump(rot.y.v + dx"   public/galaxy.js  && echo "  [ok] drag spins globe"   || echo "  [FAIL] spin"
grep -q "spread evenly across the sphere" public/index.html && echo "  [ok] globe copy"   || echo "  [FAIL] copy"
grep -q "scroll-snap-type:y"        public/index.html && echo "  [ok] scroll snap"        || echo "  [FAIL] snap"
grep -q "api/stream"                src/server.js     && echo "  [ok] SSE live"           || echo "  [FAIL] SSE"
grep -q "log1p"                     public/galaxy.js  && echo "  [--] old log-scatter still present" || echo "  [ok] scatter removed"
echo ""
echo "done.  npm start   ->   HARD refresh: Ctrl+Shift+R"
