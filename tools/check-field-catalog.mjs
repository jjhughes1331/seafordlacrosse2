// Checks lib/field-catalog.js: the catalog built from database rows must be
// exactly today's FIELDS_FALLBACK, both from rows expanded out of the
// fallback and from the live export (tools/fixtures/catalog-live.json).
//   node tools/check-field-catalog.mjs
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const root = new URL('..', import.meta.url);
const ctx = { window: {} };
vm.createContext(ctx);
vm.runInContext(readFileSync(new URL('lib/field-catalog.js', root), 'utf8'), ctx);
const { FIELDS_FALLBACK, buildFieldCatalog, slotStartMinutesRaw } = ctx.window;
const live = JSON.parse(readFileSync(new URL('tools/fixtures/catalog-live.json', root), 'utf8'));
const plain = x => JSON.parse(JSON.stringify(x));   // across vm realms

let failed = 0;
function check(name, fn){
  try { fn(); console.log('PASS', name); }
  catch(e){ failed++; console.log('FAIL', name, '\n ', e.message.split('\n').slice(0, 12).join('\n  ')); }
}

check('round trip', () => {
  const fieldRows = FIELDS_FALLBACK.map((f, i) => ({ id: f.id, name: f.name, short_name: f.short ?? null, note: f.note, sort: i + 1 }));
  const slotRows = [];
  FIELDS_FALLBACK.forEach(f => f.availability.forEach(a => a.subfields.forEach(sub => a.times.forEach(time =>
    slotRows.push({ field_id: f.id, subfield: sub, time, days: [...a.days] })))));
  slotRows.reverse();   // order must come from the rules, not the input
  assert.deepEqual(plain(buildFieldCatalog(fieldRows, slotRows)), plain(FIELDS_FALLBACK));
});

check('live equals fallback', () => {
  assert.deepEqual(plain(buildFieldCatalog(live.fields, live.slots)), plain(FIELDS_FALLBACK));
});

check('empty rows keep the fallback', () => {
  assert.deepEqual(plain(buildFieldCatalog([], [])), []);
});

check('start minutes', () => {
  assert.equal(slotStartMinutesRaw('12:00-1:00 PM'), 720);
  assert.equal(slotStartMinutesRaw('11:00-12:00 PM'), 660);
  assert.equal(slotStartMinutesRaw('7:15-9:00 PM'), 1155);
  assert.equal(slotStartMinutesRaw('9:00-10:00 AM'), 540);
});

process.exit(failed ? 1 : 0);
