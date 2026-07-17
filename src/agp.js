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
