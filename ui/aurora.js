/* ui/aurora.js — the living surface behind the Next Practice card.
 *
 * A WebGL mesh gradient: four soft colour fields drifting on slow Lissajous
 * paths, blended in linear light, with a floodlight bloom from the top edge
 * and a fine film grain so it reads as a material rather than a CSS gradient.
 * On iOS, WebKit backs WebGL with Metal, so this is Metal-rendered on device.
 *
 *   const a = Aurora.mount(canvas, { colors: ['#0b3d24', '#3478f6', '#30d158'] });
 *   a.setColors([...]); a.destroy();
 *
 * Costs nothing when you can't see it: paused off-screen, paused in a hidden
 * tab, one static frame for Reduce Motion, DPR capped at 2, and a CSS
 * gradient fallback if WebGL is unavailable or the context is lost.
 */
(function () {
  'use strict';

  const VERT = `
    attribute vec2 p;
    varying vec2 uv;
    void main(){ uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }`;

  const FRAG = `
    precision highp float;
    varying vec2 uv;
    uniform float t;
    uniform vec2 res;
    uniform vec3 c0, c1, c2, c3;

    // sRGB <-> linear so the blend doesn't go muddy in the middle
    vec3 lin(vec3 c){ return pow(c, vec3(2.2)); }
    vec3 srgb(vec3 c){ return pow(c, vec3(1.0/2.2)); }

    float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

    float blob(vec2 q, vec2 c, float r){
      float d = length(q - c);
      return exp(-(d * d) / (r * r));
    }

    void main(){
      vec2 q = uv;
      q.x *= res.x / res.y;                  // keep blobs round on a wide card
      float a = res.x / res.y;
      float s = t * 0.045;                   // slow: this is ambience, not a show

      vec2 p0 = vec2(0.20 * a + 0.10 * a * sin(s * 1.3), 0.30 + 0.18 * cos(s * 1.1));
      vec2 p1 = vec2(0.85 * a + 0.12 * a * cos(s * 0.9), 0.70 + 0.16 * sin(s * 1.7));
      vec2 p2 = vec2(0.55 * a + 0.20 * a * sin(s * 0.7 + 1.0), 0.15 + 0.12 * sin(s * 1.2 + 2.0));
      vec2 p3 = vec2(0.40 * a + 0.18 * a * cos(s * 1.5 + 0.5), 0.90 + 0.10 * cos(s * 0.8));

      float w0 = blob(q, p0, 0.55);
      float w1 = blob(q, p1, 0.50);
      float w2 = blob(q, p2, 0.45);
      float w3 = blob(q, p3, 0.60);
      float ws = w0 + w1 + w2 + w3 + 0.0001;

      vec3 col = (lin(c0) * w0 + lin(c1) * w1 + lin(c2) * w2 + lin(c3) * w3) / ws;

      // Floodlight: a soft bloom from the top-right corner, like one bank of
      // lights over a field at dusk. Kept off the left, where the type sits.
      float flood = smoothstep(0.95, 0.0, length((uv - vec2(1.05, 1.1)) * vec2(1.0, 1.6)));
      col += vec3(0.20, 0.22, 0.20) * flood;

      // Legibility: the left 60% carries white type, so it is pulled down.
      float shade = smoothstep(0.75, 0.0, uv.x);
      col *= 1.0 - shade * 0.42;

      col = srgb(col);
      // Film grain, fixed: it only exists to stop the gradient banding. A
      // re-seeded grain forced a fresh frame every refresh for no one.
      col += (hash(gl_FragCoord.xy) - 0.5) * 0.035;
      gl_FragColor = vec4(col, 1.0);
    }`;

  function hex(h) {
    const m = String(h).trim().replace('#', '');
    const n = parseInt(m.length === 3 ? m.split('').map(x => x + x).join('') : m, 16);
    return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
  }

  function compile(gl, type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }

  function mount(canvas, opts) {
    const reduced = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
    let colors = (opts && opts.colors) || ['#0b3d24', '#1f6e40', '#30d158', '#0a2a18'];
    const fallback = () => {
      canvas.style.background = `radial-gradient(120% 90% at 20% 20%, ${colors[1]}, transparent 60%),
        radial-gradient(90% 80% at 90% 80%, ${colors[2]}, transparent 55%), ${colors[0]}`;
    };

    const gl = canvas.getContext('webgl', { antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: false });
    if (!gl) { fallback(); return { setColors(c){ colors = c; fallback(); }, destroy(){} }; }

    let prog, loc = {}, raf = 0, visible = true, alive = true;
    const t0 = performance.now() - Math.random() * 60000; // not every card starts identical

    function init() {
      prog = gl.createProgram();
      gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
      gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(prog);
      gl.useProgram(prog);
      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      // One oversized triangle covers the viewport with no diagonal seam.
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const p = gl.getAttribLocation(prog, 'p');
      gl.enableVertexAttribArray(p);
      gl.vertexAttribPointer(p, 2, gl.FLOAT, false, 0, 0);
      ['t', 'res', 'c0', 'c1', 'c2', 'c3'].forEach(n => { loc[n] = gl.getUniformLocation(prog, n); });
    }

    function size() {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
      const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      gl.viewport(0, 0, w, h);
    }

    function draw(now) {
      if (!alive) return;
      size();
      const cs = colors.map(hex);
      while (cs.length < 4) cs.push(cs[cs.length - 1]);
      gl.uniform1f(loc.t, (now - t0) / 1000);
      gl.uniform2f(loc.res, canvas.width, canvas.height);
      gl.uniform3fv(loc.c0, cs[0]); gl.uniform3fv(loc.c1, cs[1]);
      gl.uniform3fv(loc.c2, cs[2]); gl.uniform3fv(loc.c3, cs[3]);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    // The drift is slow (t * 0.045), so ~20fps is indistinguishable from 120
    // and a sixth of the work; after 12s with no touch or scroll it holds its
    // last frame until someone interacts. Low Power Mode (html.lpm, set by
    // the app) gets one still frame, like Reduce Motion.
    const FRAME_MS = 50, IDLE_MS = 12000;
    let last = 0, idleAt = performance.now() + IDLE_MS;
    const still = () => reduced || document.documentElement.classList.contains('lpm');
    function loop(now) {
      if (now - last >= FRAME_MS || !last) { draw(now); last = now; }
      if (!still() && visible && !document.hidden && now < idleAt) raf = requestAnimationFrame(loop);
    }
    function resume() { cancelAnimationFrame(raf); raf = requestAnimationFrame(loop); }
    const wake = () => { const was = performance.now() >= idleAt; idleAt = performance.now() + IDLE_MS; if (was && visible) resume(); };
    ['touchstart', 'scroll', 'pointerdown'].forEach(ev => addEventListener(ev, wake, { passive: true }));

    try { init(); } catch (e) { fallback(); return { setColors(c){ colors = c; fallback(); }, destroy(){} }; }

    const io = new IntersectionObserver(es => { visible = es[0].isIntersecting; if (visible) resume(); });
    io.observe(canvas);
    const onVis = () => { if (!document.hidden) resume(); };
    document.addEventListener('visibilitychange', onVis);
    canvas.addEventListener('webglcontextlost', e => { e.preventDefault(); alive = false; fallback(); });
    resume();

    return {
      setColors(c) { colors = c; if (still() || performance.now() >= idleAt) requestAnimationFrame(draw); },
      destroy() {
        alive = false; cancelAnimationFrame(raf); io.disconnect();
        ['touchstart', 'scroll', 'pointerdown'].forEach(ev => removeEventListener(ev, wake));
        document.removeEventListener('visibilitychange', onVis);
        const ext = gl.getExtension('WEBGL_lose_context'); if (ext) ext.loseContext();
      },
    };
  }

  window.Aurora = { mount };
})();
