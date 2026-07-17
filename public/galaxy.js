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
      color: 0x010204, roughness: 1.0, metalness: 0.0,
      transparent: true, opacity: 0.95
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
    color: 0x3f5b70, size: 0.045, sizeAttenuation: true,
    transparent: true, opacity: 0.0, depthWrite: false
  }));
  g.add(matrix);

  // graticule
  grat = new THREE.Group();
  const gm = new THREE.LineBasicMaterial({ color: 0x1f4058, transparent: true, opacity: 0.0 });
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
          float i = pow(clamp(0.65 - dot(vN, vec3(0.0,0.0,1.0)), 0.0, 1.0), 3.8);
          gl_FragColor = vec4(uCol, 1.0) * i * 0.25;
        }`
    })
  );
}

function buildHalo() {
  const c = document.createElement('canvas'); c.width = c.height = 256;
  const x = c.getContext('2d');
  const g = x.createRadialGradient(128, 128, 80, 128, 128, 128);
  g.addColorStop(0, 'rgba(40, 70, 110, 0.12)');
  g.addColorStop(0.55, 'rgba(20, 30, 50, 0.04)');
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
  const n = 3500;
  const pos = new Float32Array(n * 3);
  const colors = new Float32Array(n * 3);
  const c = new THREE.Color();
  for (let i = 0; i < n; i++) {
    const r = R * (1.2 + Math.random() * 8.5);
    const th = Math.random() * Math.PI * 2, ph = Math.acos(2 * Math.random() - 1);
    pos[i*3] = r*Math.sin(ph)*Math.cos(th);
    pos[i*3+1] = r*Math.sin(ph)*Math.sin(th);
    pos[i*3+2] = r*Math.cos(ph);
    
    // HD Universe colored stars: warm oranges, cool blues, and whites
    const rand = Math.random();
    if (rand < 0.15) c.set('#ffcc99');
    else if (rand < 0.35) c.set('#99ccff');
    else c.set('#ffffff');
    
    colors[i*3] = c.r; colors[i*3+1] = c.g; colors[i*3+2] = c.b;
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  g.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  return new THREE.Points(g, new THREE.PointsMaterial({
    size: 0.15, sizeAttenuation: true, vertexColors: true,
    transparent: true, opacity: 0.75, depthWrite: false, blending: THREE.AdditiveBlending
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
    // lock dots to the surface
    const lift = R * 1.0;
    out.set(keyOf(d), { dir, pos: dir.clone().multiplyScalar(lift) });
  });
  return out;
}

const radOf = d => 0.15;

/* ---------- orbs ---------- */
function rebuild(count) {
  if (orbs) { globe.remove(orbs); orbs.geometry.dispose(); orbs.material.dispose(); }
  const geo = new THREE.SphereGeometry(1, 32, 24);
  const mat = new THREE.MeshBasicMaterial({
    color: 0xffffff, transparent: false
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
      curR: 0.0001,
      baseColor: colorFor(d)
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

  if (spin && !drag) rot.y.jump(rot.y.v + dt * 0.15);
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
      
      // Lock all dots to the surface (no hovering based on points)
      n.home.copy(n.dir).multiplyScalar(R * 1.0);
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
    // hide tags on the far side, and only show if hovered or selected to prevent overlapping text in dense view
    const facing = _v.clone().applyMatrix4(globe.matrixWorld).normalize().dot(
      camera.position.clone().normalize()
    );
    const isHovSel = (selected === n || hovered === n);
    sp.material.opacity = isHovSel ? (n.vis.v * Math.max(0, facing)) : 0;
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
  bloom = new UnrealBloomPass(new THREE.Vector2(W, H), 0.3, 0.5, 0.25);
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
