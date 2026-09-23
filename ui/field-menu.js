/* ui/field-menu.js — the field switcher.
 *
 * Replaces a strip of chips that ran off the right edge and hid two of the
 * five fields. The current field reads as a title with a chevron; tapping it
 * blooms a menu out of the button itself (transform-origin at the trigger),
 * every field visible at once, each with its own colour.
 *
 * The host page renders a trigger and registers what the menu means:
 *
 *   <button class="fm-trigger" data-field-menu="schedule">…</button>
 *   FieldMenu.register('schedule', {
 *     items:      () => [{ id, name, detail, color }],
 *     selected:   () => 'harbor',
 *     onSelect:   id => {...},
 *     favorite:   () => 'harbor',          // optional
 *     onFavorite: id => {...},             // optional
 *   });
 *
 * Behaviour is attached by delegation, so it works on triggers rendered after
 * this file loads, and it does not care which script ran first.
 */
(function () {
  'use strict';

  const registry = {};
  let open = null; // { key, trigger, panel, backdrop, focusIndex }

  const STAR = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 2.6c.3 0 .6.2.7.5l2.3 4.7 5.2.8c.7.1 1 .9.5 1.4l-3.8 3.7.9 5.1c.1.7-.6 1.2-1.2.9L12 17.3l-4.6 2.4c-.6.3-1.3-.2-1.2-.9l.9-5.1-3.8-3.7c-.5-.5-.2-1.3.5-1.4l5.2-.8 2.3-4.7c.1-.3.4-.5.7-.5Z"/></svg>';
  const CHECK = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" d="m5.5 12.5 4.2 4.2L18.5 7.8"/></svg>';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function tap(kind) {
    try { if (window.haptic) window.haptic(kind || 'light'); } catch (e) {}
  }

  function register(key, api) { registry[key] = api; }

  function build(key, trigger) {
    const api = registry[key];
    const items = api.items();
    const sel = api.selected();
    const fav = api.favorite ? api.favorite() : null;

    const backdrop = document.createElement('div');
    backdrop.className = 'fm-backdrop';

    const panel = document.createElement('div');
    panel.className = 'fm-panel';
    panel.setAttribute('role', 'listbox');
    panel.setAttribute('aria-label', 'Choose a field');
    panel.innerHTML = items.map((it, i) => {
      const on = it.id === sel;
      const isFav = fav && it.id === fav;
      const dot = it.id === 'all'
        ? '<span class="fm-dot fm-dot-all" aria-hidden="true"><i></i><i></i><i></i></span>'
        : `<span class="fm-dot" style="--c:${esc(it.color)}" aria-hidden="true"></span>`;
      const star = (api.onFavorite && it.id !== 'all')
        ? `<button type="button" class="fm-star${isFav ? ' on' : ''}" data-fm-fav="${esc(it.id)}" aria-label="${isFav ? 'Remove favourite' : 'Make favourite'}: ${esc(it.name)}">${STAR}</button>`
        : '';
      return `<div class="fm-row${on ? ' on' : ''}" role="option" aria-selected="${on}" tabindex="-1" data-fm-pick="${esc(it.id)}" data-i="${i}" style="--i:${i}">
          ${dot}
          <span class="fm-text"><span class="fm-name">${esc(it.name)}</span>${it.detail ? `<span class="fm-detail">${esc(it.detail)}</span>` : ''}</span>
          ${star}
          <span class="fm-check">${on ? CHECK : ''}</span>
        </div>`;
    }).join('');

    document.body.appendChild(backdrop);
    document.body.appendChild(panel);
    return { backdrop, panel, items };
  }

  function place(trigger, panel) {
    const r = trigger.getBoundingClientRect();
    const vw = window.innerWidth, vh = window.innerHeight;
    const margin = 12;
    const width = Math.min(340, vw - margin * 2);
    panel.style.width = width + 'px';
    const left = Math.max(margin, Math.min(r.left, vw - width - margin));
    const ph = panel.offsetHeight;
    const below = r.bottom + 8;
    const fitsBelow = below + ph < vh - 96; // keep clear of the floating tab bar
    const top = fitsBelow ? below : Math.max(margin + 44, r.top - ph - 8);
    panel.style.left = left + 'px';
    panel.style.top = top + 'px';
    // Bloom from the trigger's own centre, so the menu reads as coming out of it.
    const ox = r.left + r.width / 2 - left;
    const oy = fitsBelow ? -8 : ph + 8;
    panel.style.transformOrigin = `${ox}px ${oy}px`;
  }

  function show(key, trigger) {
    if (open) close(true);
    if (!registry[key]) return;
    const { backdrop, panel } = build(key, trigger);
    place(trigger, panel);
    trigger.setAttribute('aria-expanded', 'true');
    trigger.classList.add('is-open');
    open = { key, trigger, panel, backdrop, focusIndex: -1 };
    tap('light');

    window.Spring.set(panel, { scale: 0.86, opacity: 0, y: 0 });
    window.Spring.to(panel, { scale: 1, opacity: 1 }, { preset: 'snappy' });
    requestAnimationFrame(() => { backdrop.classList.add('on'); panel.classList.add('in'); });

    const selRow = panel.querySelector('.fm-row.on') || panel.querySelector('.fm-row');
    if (selRow) { open.focusIndex = +selRow.dataset.i; selRow.focus({ preventScroll: true }); }
  }

  function close(instant, then) {
    if (!open) return;
    const { trigger, panel, backdrop } = open;
    open = null;
    trigger.setAttribute('aria-expanded', 'false');
    trigger.classList.remove('is-open');
    backdrop.classList.remove('on');
    const remove = () => { panel.remove(); backdrop.remove(); then && then(); };
    if (instant) return remove();
    // Folds back into the trigger rather than just fading, so the eye follows
    // it home and lands on the new label.
    window.Spring.to(panel, { scale: 0.9, opacity: 0 }, { preset: 'snappy' }).then(remove);
    setTimeout(remove, 450);
    trigger.focus({ preventScroll: true });
  }

  function pick(id) {
    if (!open) return;
    const api = registry[open.key];
    const trigger = open.trigger;
    const row = open.panel.querySelector(`[data-fm-pick="${CSS.escape(id)}"]`);
    if (row) row.classList.add('picked');
    tap('light');
    // Let the checkmark land before the menu folds away: 90ms reads as a
    // deliberate confirmation, not lag.
    setTimeout(() => close(false, () => {
      if (id !== api.selected()) api.onSelect(id);
      const next = document.querySelector(`[data-field-menu="${CSS.escape(open ? open.key : trigger.dataset.fieldMenu)}"]`);
      if (next) next.classList.add('fm-changed');
      setTimeout(() => next && next.classList.remove('fm-changed'), 420);
    }), 90);
  }

  function favorite(id) {
    if (!open) return;
    const api = registry[open.key];
    if (!api.onFavorite) return;
    api.onFavorite(id);
    tap('success');
    const fav = api.favorite ? api.favorite() : null;
    open.panel.querySelectorAll('.fm-star').forEach(s => {
      const on = s.dataset.fmFav === fav;
      s.classList.toggle('on', on);
      if (on) { s.classList.remove('pop'); void s.offsetWidth; s.classList.add('pop'); }
    });
  }

  document.addEventListener('click', e => {
    const fav = e.target.closest('[data-fm-fav]');
    if (fav && open) { e.stopPropagation(); return favorite(fav.dataset.fmFav); }
    const row = e.target.closest('[data-fm-pick]');
    if (row && open) return pick(row.dataset.fmPick);
    if (e.target.closest('.fm-backdrop')) return close();
    const trig = e.target.closest('[data-field-menu]');
    if (trig) {
      e.preventDefault();
      if (open && open.trigger === trig) return close();
      return show(trig.dataset.fieldMenu, trig);
    }
  });

  document.addEventListener('keydown', e => {
    if (!open) return;
    const rows = [...open.panel.querySelectorAll('.fm-row')];
    if (e.key === 'Escape') { e.preventDefault(); return close(); }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const d = e.key === 'ArrowDown' ? 1 : -1;
      open.focusIndex = (open.focusIndex + d + rows.length) % rows.length;
      rows[open.focusIndex].focus({ preventScroll: true });
    }
    if (e.key === 'Enter' || e.key === ' ') {
      const r = rows[open.focusIndex];
      if (r) { e.preventDefault(); pick(r.dataset.fmPick); }
    }
  });

  // A menu left floating while the page scrolls under it is detached from its
  // trigger. Close on scroll, the way a context menu does.
  window.addEventListener('scroll', () => { if (open) close(); }, { passive: true });
  window.addEventListener('resize', () => { if (open) close(true); });

  window.FieldMenu = { register, close: () => close(), isOpen: () => !!open };
})();
