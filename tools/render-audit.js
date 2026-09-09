// Rendered-output audit. Paste into the console on https://seafordlax.com/?fixture=1
//
// WHY THIS EXISTS: three separate times, a source-text grep reported the site
// clean and the running page disagreed.
//   - an emoji written as the HTML entity &#128075; (a regex over emoji
//     codepoints cannot see it — the browser decodes it, the file does not)
//   - thirteen Lucide-style icons found only by querying the DOM for
//     svg[fill="none"][stroke], after grep for remembered strings said none
//   - a table that overflowed a phone only once a real long email was in it
// Source is what we wrote. Rendered output is what a coach sees. Audit the
// second one.
(async function renderAudit(){
  const out = {};
  for (const v of ['schedule','book','openweek','myteam','league','admin']) {
    try { switchView(v); await new Promise(r => setTimeout(r, 500)); } catch(e){}
  }
  document.querySelectorAll('[id^=view]').forEach(v => v.style.display = 'block');
  document.querySelectorAll('[data-adminpane],[data-peoplepane]').forEach(p => p.hidden = false);
  document.querySelectorAll('details').forEach(d => d.open = true);
  await new Promise(r => setTimeout(r, 400));

  const els = [...document.querySelectorAll('body *')].filter(e => !['SCRIPT','STYLE'].includes(e.tagName));
  const cs = e => getComputedStyle(e);

  // Emoji in text the browser actually rendered (entities included)
  const EMOJI = /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/u;
  out.emoji = els.filter(e => !e.children.length && EMOJI.test(e.textContent || ''))
    .map(e => e.tagName + '.' + e.className + ': ' + e.textContent.trim().slice(0, 30));

  // Icon vocabulary: stroked and solid should not both be in play
  out.strokedIcons = [...document.querySelectorAll('svg')]
    .filter(s => s.getAttribute('fill') === 'none' && (s.getAttribute('stroke') || '') !== '').length;
  out.solidIcons = document.querySelectorAll('svg[fill="currentColor"]').length;

  // Tap targets under Apple's 44pt minimum.
  // Measures the HIT AREA, not the box. Several controls here are deliberately
  // small but carry a ::before overlay that expands what a thumb can hit (the
  // toast close is 26px with a 44px target). Measuring box height alone reports
  // those as failures, and an audit that cries wolf stops being read.
  // Deterministic rather than positional: this script force-displays every view
  // at once so nothing hides from it, which makes elements overlap and breaks
  // elementFromPoint. Read the overlay's computed height instead. A ::before of
  // 44px, or an inset that grows the box to 44, is a real 44px target.
  const hitOK = e => {
    if (e.getBoundingClientRect().height >= 43.5) return true;   // sub-pixel layout: a 44px select measures 43.99
    const b = getComputedStyle(e, '::before');
    return b.content !== 'none' && parseFloat(b.height) >= 43.5;
  };
  out.under44 = els.filter(e => /^(BUTTON|A|SELECT|INPUT)$/.test(e.tagName))
    .filter(e => e.getBoundingClientRect().height > 0 && !hitOK(e))
    .map(e => ({ el: e.tagName + '.' + String(e.className).slice(0,20), h: Math.round(e.getBoundingClientRect().height) }));

  // Anything wider than its own container (the bug a short test email hides)
  out.overflowing = els.filter(e => {
    const p = e.parentElement; if (!p) return false;
    if (cs(e).position === 'fixed') return false;   // fixed elements escape their parent by design
    return e.getBoundingClientRect().width > p.getBoundingClientRect().width + 1;
  }).map(e => e.tagName + '.' + String(e.className).slice(0, 24)).slice(0, 10);
  out.pageScrollsSideways = document.documentElement.scrollWidth - window.innerWidth;

  // Em dashes in rendered copy
  out.emDashes = els.filter(e => !e.children.length && (e.textContent || '').includes('—'))
    .map(e => e.textContent.trim().slice(0, 50));

  // Gradients, gradient text, glass, grain
  out.gradients = els.filter(e => /gradient/.test(cs(e).backgroundImage)).length;
  out.gradientText = els.filter(e => cs(e).webkitBackgroundClip === 'text').length;
  out.backdropFilters = els.filter(e => (cs(e).backdropFilter || 'none') !== 'none')
    .map(e => String(e.className).slice(0, 20));
  out.serif = els.filter(e => /serif/.test(cs(e).fontFamily) && !/sans-serif/.test(cs(e).fontFamily)).length;
  out.fontFamilies = [...new Set(els.map(e => cs(e).fontFamily.split(',')[0].replace(/"/g,'')))];

  console.table(out.under44);
  console.log(out);
  return out;
})();
