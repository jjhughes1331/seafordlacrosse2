/* tools/pixel-audit.js — run on ?fixture=1 in a phone-width window.
 *
 * Walks every tab and reports what a design review would catch by eye but
 * miss at scale:
 *   - tap targets under 44pt (buttons, links, inputs, menu triggers)
 *   - text under WCAG contrast (4.5:1 body, 3:1 for 18px+ or 14px+ bold),
 *     measured against the actual painted background behind the text
 * Returns { view: { taps: [...], contrast: [...] } }.
 */
(async function pixelAudit() {
  const VIEWS = ['schedule', 'book', 'openweek', 'myteam', 'league', 'admin'];
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  const parse = c => {
    const m = c.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  };
  const lum = ({ r, g, b }) => {
    const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
  };
  const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const blend = (top, under) => ({
    r: top.r * top.a + under.r * (1 - top.a), g: top.g * top.a + under.g * (1 - top.a),
    b: top.b * top.a + under.b * (1 - top.a), a: 1,
  });
  // The colour actually behind an element: walk up compositing backgrounds.
  function backdrop(el) {
    const stack = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.backgroundImage !== 'none' && !/gradient/.test(cs.backgroundImage)) return null; // image: can't judge
      if (/gradient/.test(cs.backgroundImage) || n.tagName === 'CANVAS') return null;
      const c = parse(cs.backgroundColor);
      if (c && c.a > 0) { stack.push(c); if (c.a >= 1) break; }
    }
    let base = parse(getComputedStyle(document.body).backgroundColor) || { r: 255, g: 255, b: 255, a: 1 };
    for (let i = stack.length - 1; i >= 0; i--) base = blend(stack[i], base);
    return base;
  }
  const visible = el => {
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity > 0.05;
  };

  const out = {};
  for (const v of VIEWS) {
    const tab = document.querySelector(`.view-tab[data-view="${v}"]`);
    if (!tab || getComputedStyle(tab).display === 'none') continue;
    tab.click();
    await sleep(500);
    const taps = [], contrast = [];
    document.querySelectorAll('button, a[href], input, select, [role="button"], [data-field-menu]').forEach(el => {
      if (!visible(el) || el.closest('.view-tabs')) return;
      const r = el.getBoundingClientRect();
      const before = getComputedStyle(el, '::before');
      const hit = Math.max(r.height, parseFloat(before.height) || 0);
      if (hit < 43.5 && r.width < 200) taps.push(`${el.tagName.toLowerCase()}.${(el.className || '').toString().split(' ')[0]} "${(el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 24)}" ${Math.round(r.width)}x${Math.round(r.height)}`);
    });
    const seen = new Set();
    document.querySelectorAll('body *').forEach(el => {
      if (!visible(el) || el.closest('.next-card.hero') || el.closest('#fixture-banner')) return;
      const own = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim().length > 1);
      if (!own) return;
      const cs = getComputedStyle(el);
      const fg = parse(cs.color); const bg = backdrop(el);
      if (!fg || !bg) return;
      const size = parseFloat(cs.fontSize), bold = +cs.fontWeight >= 600;
      const need = (size >= 18 || (size >= 14 && bold)) ? 3 : 4.5;
      const cr = ratio(blend(fg, bg), bg);
      const key = el.className + '|' + cs.color;
      if (cr < need && !seen.has(key)) {
        seen.add(key);
        contrast.push(`${el.tagName.toLowerCase()}.${(el.className || '').toString().split(' ')[0]} "${el.textContent.trim().slice(0, 28)}" ${cr.toFixed(2)}:1 (needs ${need})`);
      }
    });
    out[v] = { taps, contrast };
  }
  return out;
})();
