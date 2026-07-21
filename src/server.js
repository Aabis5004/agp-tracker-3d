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

// allow the race-feed site (and any origin) to read the API + SSE stream
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});
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
