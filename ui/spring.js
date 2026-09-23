/* ui/spring.js — a small, interruptible spring solver.
 *
 * Why not CSS transitions: a transition restarts from zero velocity when it is
 * interrupted, so a menu reopened mid-close visibly stutters. A spring keeps
 * its current position AND velocity and simply retargets, which is what makes
 * iOS motion feel continuous under a finger.
 *
 *   Spring.to(el, { scale: 1, opacity: 1, y: 0 }, { preset: 'snappy' })
 *   Spring.run(0, 1, { preset: 'gentle', onUpdate: v => ..., onDone })
 *
 * Reduce Motion: every animation completes on the next frame at its target.
 */
(function () {
  'use strict';

  const PRESETS = {
    // response ~0.3s, no visible overshoot: menus, thumbs, selection
    snappy: { stiffness: 520, damping: 42, mass: 1 },
    // response ~0.45s, a whisper of settle: sheets, cards
    gentle: { stiffness: 260, damping: 30, mass: 1 },
    // visible overshoot: reserved for success moments only
    bouncy: { stiffness: 420, damping: 17, mass: 1 },
  };
  const REST_DELTA = 0.0015;
  const REST_SPEED = 0.01;
  const MAX_STEP = 1 / 60;

  const reduced = () =>
    window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function config(opts) {
    const p = (opts && opts.preset && PRESETS[opts.preset]) || PRESETS.snappy;
    return Object.assign({}, p, opts || {});
  }

  /** Animate one number. Returns a handle with stop() and retarget(to). */
  function run(from, to, opts) {
    const c = config(opts);
    let x = from, v = (opts && opts.velocity) || 0, target = to;
    let last = performance.now(), raf = 0, done = false;

    function finish() {
      done = true;
      x = target; v = 0;
      c.onUpdate && c.onUpdate(x, v);
      c.onDone && c.onDone();
    }
    function frame(now) {
      let dt = Math.min((now - last) / 1000, 0.064);
      last = now;
      // Semi-implicit Euler in fixed sub-steps: stable at any frame rate,
      // including a dropped frame on an older phone.
      while (dt > 0) {
        const h = Math.min(dt, MAX_STEP);
        const force = -c.stiffness * (x - target) - c.damping * v;
        v += (force / c.mass) * h;
        x += v * h;
        dt -= h;
      }
      c.onUpdate && c.onUpdate(x, v);
      if (Math.abs(x - target) < REST_DELTA && Math.abs(v) < REST_SPEED) return finish();
      raf = requestAnimationFrame(frame);
    }

    if (reduced() || from === to) {
      requestAnimationFrame(finish);
    } else {
      raf = requestAnimationFrame(t => { last = t; frame(t); });
    }
    return {
      stop() { cancelAnimationFrame(raf); done = true; },
      retarget(t) { target = t; if (done) { done = false; last = performance.now(); raf = requestAnimationFrame(frame); } },
      get value() { return x; },
      get velocity() { return v; },
    };
  }

  /* Element transforms. State lives on the element so a second call picks up
     the first one's position and velocity instead of snapping. */
  const KEYS = ['x', 'y', 'scale', 'opacity', 'rotate'];
  const DEFAULTS = { x: 0, y: 0, scale: 1, opacity: 1, rotate: 0 };

  function apply(el, s) {
    el.style.transform =
      `translate3d(${s.x.toFixed(2)}px, ${s.y.toFixed(2)}px, 0) scale(${s.scale.toFixed(4)})` +
      (s.rotate ? ` rotate(${s.rotate.toFixed(2)}deg)` : '');
    el.style.opacity = String(Math.max(0, Math.min(1, s.opacity)).toFixed(3));
  }

  function to(el, targets, opts) {
    if (!el) return Promise.resolve();
    const st = el.__spring || (el.__spring = { values: Object.assign({}, DEFAULTS), handles: {} });
    if (opts && opts.from) Object.assign(st.values, opts.from);
    apply(el, st.values);
    const keys = Object.keys(targets).filter(k => KEYS.includes(k));
    return new Promise(resolve => {
      let pending = keys.length;
      if (!pending) return resolve();
      keys.forEach(k => {
        const prev = st.handles[k];
        const velocity = prev ? prev.velocity : 0;
        if (prev) prev.stop();
        st.handles[k] = run(st.values[k], targets[k], Object.assign({}, opts, {
          velocity,
          onUpdate: val => { st.values[k] = val; apply(el, st.values); },
          onDone: () => { delete st.handles[k]; if (--pending === 0) resolve(); },
        }));
      });
    });
  }

  function set(el, values) {
    const st = el.__spring || (el.__spring = { values: Object.assign({}, DEFAULTS), handles: {} });
    Object.values(st.handles).forEach(h => h.stop());
    st.handles = {};
    Object.assign(st.values, values);
    apply(el, st.values);
  }

  window.Spring = { run, to, set, PRESETS, reduced };
})();
