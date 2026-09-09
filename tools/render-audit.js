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

  // Tap targets under Apple's 44pt minimum
  out.under44 = els.filter(e => /^(BUTTON|A|SELECT|INPUT)$/.test(e.tagName))
    .map(e => ({ el: e.tagName + '.' + String(e.className).slice(0,20), h: Math.round(e.getBoundingClientRect().height) }))
    .filter(x => x.h > 0 && x.h < 44);

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
