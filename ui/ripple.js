/* ui/ripple.js — the moment a booking lands.
 *
 * Confetti says "you won a prize". A booking is a small, certain thing, so it
 * gets a small, certain acknowledgement: one pressure ring from the exact
 * point of the tap, a faint second echo, and a handful of sparks that drift
 * out and fade under drag. ~650ms, tinted by the field's colour, gone.
 *
 *   Ripple.at(x, y, '#3478f6');
 *
 * One shared canvas, created on first use, pointer-events off. Skipped
 * entirely for Reduce Motion (the haptic still fires, from the caller).
 */
(function () {
  'use strict';

  let canvas = null, ctx = null, raf = 0;
  const bursts = [];

  function ensure() {
    if (canvas) return;
    canvas = document.createElement('canvas');
    canvas.className = 'ripple-layer';
    canvas.setAttribute('aria-hidden', 'true');
    Object.assign(canvas.style, {
      position: 'fixed', inset: '0', width: '100vw', height: '100vh',
      pointerEvents: 'none', zIndex: '900',
    });
    document.body.appendChild(canvas);
    ctx = canvas.getContext('2d');
  }

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    const w = Math.round(innerWidth * dpr), h = Math.round(innerHeight * dpr);
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function rgb(hex) {
    const m = String(hex || '#30d158').replace('#', '');
    const n = parseInt(m.length === 3 ? m.split('').map(x => x + x).join('') : m, 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  // Ease that decelerates like a thrown object: fast out, long settle.
  const out = t => 1 - Math.pow(1 - t, 3.2);

  function at(x, y, color) {
    if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    ensure();
    const [r, g, b] = rgb(color);
    const sparks = Array.from({ length: 9 }, (_, i) => {
      const ang = (i / 9) * Math.PI * 2 + Math.random() * 0.5;
      const sp = 150 + Math.random() * 110;
      return { x, y, vx: Math.cos(ang) * sp, vy: Math.sin(ang) * sp, r: 1.6 + Math.random() * 1.4 };
    });
    bursts.push({ x, y, r, g, b, t0: performance.now(), sparks, last: performance.now() });
    if (!raf) raf = requestAnimationFrame(frame);
  }

  function frame(now) {
    resize();
    ctx.clearRect(0, 0, innerWidth, innerHeight);
    for (let i = bursts.length - 1; i >= 0; i--) {
      const B = bursts[i];
      const age = (now - B.t0) / 1000;
      const dt = Math.min((now - B.last) / 1000, 0.05);
      B.last = now;
      if (age > 0.75) { bursts.splice(i, 1); continue; }

      // Pressure ring and its echo.
      [[0, 58, 2.4, 0.55], [0.09, 84, 1.2, 0.28]].forEach(([delay, maxR, width, alpha]) => {
        const k = Math.max(0, Math.min(1, (age - delay) / 0.55));
        if (k <= 0 || k >= 1) return;
        ctx.beginPath();
        ctx.arc(B.x, B.y, 6 + out(k) * maxR, 0, Math.PI * 2);
        ctx.lineWidth = width * (1 - k * 0.6);
        ctx.strokeStyle = `rgba(${B.r},${B.g},${B.b},${alpha * (1 - k)})`;
        ctx.stroke();
      });

      // A soft fill that breathes out from the point of contact.
      const f = Math.min(1, age / 0.35);
      if (f < 1) {
        const grd = ctx.createRadialGradient(B.x, B.y, 0, B.x, B.y, 44 * out(f) + 1);
        grd.addColorStop(0, `rgba(${B.r},${B.g},${B.b},${0.22 * (1 - f)})`);
        grd.addColorStop(1, `rgba(${B.r},${B.g},${B.b},0)`);
        ctx.fillStyle = grd;
        ctx.beginPath(); ctx.arc(B.x, B.y, 44, 0, Math.PI * 2); ctx.fill();
      }

      // Sparks under air drag.
      const drag = Math.exp(-6.5 * dt);
      B.sparks.forEach(s => {
        s.vx *= drag; s.vy *= drag;
        s.x += s.vx * dt; s.y += s.vy * dt;
        const a = Math.max(0, 1 - age / 0.7);
        ctx.fillStyle = `rgba(${B.r},${B.g},${B.b},${0.85 * a})`;
        ctx.beginPath(); ctx.arc(s.x, s.y, s.r * (0.6 + 0.4 * a), 0, Math.PI * 2); ctx.fill();
      });
    }
    raf = bursts.length ? requestAnimationFrame(frame) : 0;
    if (!raf) ctx.clearRect(0, 0, innerWidth, innerHeight);
  }

  window.Ripple = { at };
})();
