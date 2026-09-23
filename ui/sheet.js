/* ui/sheet.js — every sheet behaves like an iOS sheet.
 *
 * The sheets drew a grabber but could not be dragged: a promise the UI did
 * not keep. This gives every `.share-modal` host the system behaviour:
 *
 *   - drag down anywhere on the sheet while its content is scrolled to the
 *     top; the backdrop fades with the finger
 *   - release past a third of the sheet's height, or flick down, and it
 *     closes; otherwise it springs back
 *   - the spring carries the finger's velocity, so a flick feels like one
 *
 * Closing goes through the host's own backdrop (`.share-backdrop`), so each
 * sheet's existing close logic (resolving a confirm, clearing state) runs
 * exactly as if the backdrop had been tapped.
 *
 * Wired by delegation: sheets rendered after this file loads just work.
 */
(function () {
  'use strict';

  const CLOSE_FRACTION = 1 / 3;
  const FLICK = 0.55;            // px per ms, downward
  let drag = null;

  function sheetFor(target) {
    const sheet = target.closest && target.closest('.share-sheet');
    if (!sheet) return null;
    const host = sheet.closest('.share-modal');
    if (!host || getComputedStyle(host).display === 'none') return null;
    return { sheet, host, backdrop: host.querySelector('.share-backdrop') };
  }

  // Controls keep their own gestures: a switch, a text field, a slider.
  function interactive(el) {
    return !!el.closest('input, textarea, select, [contenteditable], [data-sheet-nodrag]');
  }

  document.addEventListener('touchstart', e => {
    if (e.touches.length !== 1 || window.matchMedia('(min-width: 701px)').matches) return;
    const hit = sheetFor(e.target);
    if (!hit || interactive(e.target)) return;
    const t = e.touches[0];
    drag = {
      ...hit, startY: t.clientY, lastY: t.clientY, lastT: e.timeStamp, v: 0,
      dy: 0, active: false, scroller: e.target.closest('.sheet-scroll') || hit.sheet,
    };
  }, { passive: true });

  document.addEventListener('touchmove', e => {
    if (!drag) return;
    const y = e.touches[0].clientY;
    const dy = y - drag.startY;
    if (!drag.active) {
      // Only a downward pull that starts with the content at its top is a
      // dismiss; anything else is the user scrolling the sheet.
      if (dy < 6 || drag.scroller.scrollTop > 0) { if (dy < -6 || drag.scroller.scrollTop > 0) drag = null; return; }
      drag.active = true;
      if (window.Spring) Spring.set(drag.sheet, { y: 0, opacity: 1 });
    }
    e.preventDefault();
    const dt = Math.max(1, e.timeStamp - drag.lastT);
    drag.v = (y - drag.lastY) / dt;
    drag.lastY = y; drag.lastT = e.timeStamp;
    drag.dy = Math.max(0, dy) + Math.min(0, dy) * 0.15;   // resist upward
    drag.sheet.style.transform = `translate3d(0, ${drag.dy.toFixed(1)}px, 0)`;
    if (drag.backdrop) drag.backdrop.style.opacity = String(1 - Math.min(1, drag.dy / drag.sheet.offsetHeight));
  }, { passive: false });

  function end() {
    if (!drag) return;
    const d = drag; drag = null;
    if (!d.active) return;
    const h = d.sheet.offsetHeight;
    const close = d.dy > h * CLOSE_FRACTION || d.v > FLICK;
    const settle = (y, done) => {
      if (!window.Spring) { d.sheet.style.transform = ''; done && done(); return; }
      Spring.set(d.sheet, { y: d.dy });
      Spring.to(d.sheet, { y }, { preset: close ? 'snappy' : 'gentle', velocity: d.v * 1000 }).then(done);
    };
    if (close) {
      try { window.haptic && window.haptic('light'); } catch (e) {}
      settle(h + 40, () => {
        d.backdrop ? d.backdrop.click() : (d.host.style.display = 'none');
        // Reset for the next opening; the host is hidden by now.
        d.sheet.style.transform = ''; d.sheet.style.opacity = '';
        if (d.sheet.__spring) d.sheet.__spring.values.y = 0;
        if (d.backdrop) d.backdrop.style.opacity = '';
      });
    } else {
      if (d.backdrop) d.backdrop.style.opacity = '';
      settle(0, () => { d.sheet.style.transform = ''; });
    }
  }
  document.addEventListener('touchend', end, { passive: true });
  document.addEventListener('touchcancel', end, { passive: true });
})();
