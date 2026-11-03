// field-catalog.js — the field list, built from the database.
//
// The bookable slots live in the database: `fields` (names, notes, order)
// and `field_slots` (the allowlist the booking trigger enforces). index.html
// reads both at boot and builds FIELDS from them with buildFieldCatalog, so a
// field or a time changes in one place. FIELDS_FALLBACK is the list as it
// stood when it moved (2026-11); it is only used when that read fails.
// The iPhone app builds the same list with the same rules
// (SeafordKit/FieldCatalog.swift); tools/check-field-catalog.mjs proves both
// equal the live export.

// Alphabetical by display name, and names are consistently "Seaford <X>" /
// full proper names throughout — no more mixing "Harbor" with "Seaford HS"
// with "Middle School" depending on which label happened to render.
var FIELDS_FALLBACK = [
  { id:"cedarcreek", name:"Cedar Creek",
    note:"East Field, Tuesday and Thursday only. Half field only (shared with soccer and Wantagh Lax).",
    availability:[ { days:[2,4], subfields:["1/2 Field"], times:["4:30-5:30 PM","5:30-6:30 PM","6:30-8:00 PM"] } ]},
  { id:"harbor", name:"Seaford Harbor",
    note:"Field 1 inside track, Field 2 outside track.",
    availability:[
      { days:[1,2,3,4,5], subfields:["Field 1","Field 2"], times:["4:30-5:30 PM","5:30-6:30 PM","6:30-7:30 PM","7:30-8:30 PM"] },
      { days:[0,6], subfields:["Field 1","Field 2"], times:["9:00-10:00 AM","10:00-11:00 AM","11:00-12:00 PM","12:00-1:00 PM","1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM","6:00-7:00 PM","7:00-8:00 PM"] },
    ]},
  { id:"seafordhs", name:"Seaford HS",
    note:"Turf field. School games have priority weeknights.",
    availability:[
      { days:[1,2,3,4,5], subfields:["Half Field A (North)","Half Field B (South)"], times:["7:15-9:00 PM"] },
      { days:[6], subfields:["Half Field A (North)","Half Field B (South)"], times:["1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM","6:00-7:00 PM"] },
    ]},
  { id:"sms", name:"Seaford MS",
    note:"Grass field. School teams have priority; permit starts at 5 PM.",
    availability:[
      { days:[1,2,3,4,5], subfields:["Half Field A","Half Field B"], times:["6:00-7:00 PM","7:30-9:00 PM"] },
      { days:[6], subfields:["Half Field A","Half Field B"], times:["1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM"] },
    ]},
  { id:"seamans", name:"Seamans Neck Park", short:"Seamans Neck",
    note:"Field A closest to parking, B mid field, C far end.",
    availability:[
      { days:[1,2,3,4,5], subfields:["Field A","Field B","Field C"], times:["5:00-6:30 PM","6:30-8:00 PM","8:00-10:00 PM"] },
      { days:[6], subfields:["Half Field A","Half Field B"], times:["1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM"] },
    ]},
];

// "11:00-12:00 PM" -> 660. Only the end carries AM/PM: the start shares it
// unless its hour (12 counted as 0) is later than the end's, which means the
// range crosses noon or midnight.
function slotStartMinutesRaw(time){
  const m = /^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*(AM|PM)$/i.exec(String(time).trim());
  if(!m) return 0;
  const sh = +m[1] % 12, eh = +m[3] % 12, endPM = m[5].toUpperCase() === 'PM';
  const startPM = sh > eh ? !endPM : endPM;
  return (sh + (startPM ? 12 : 0)) * 60 + +m[2];
}

// Rows -> FIELDS' shape. Per field (by sort), slots with the same days form
// one availability group; groups run weekdays first (Sunday counts as 7),
// sub-fields alphabetically, times by start. Empty in, empty out: the caller
// keeps FIELDS_FALLBACK then.
function buildFieldCatalog(fieldRows, slotRows){
  const fields = [...(fieldRows || [])].sort((a, b) => a.sort - b.sort);
  return fields.map(f => {
    const groups = new Map();
    (slotRows || []).filter(s => s.field_id === f.id).forEach(s => {
      const days = [...s.days].sort((a, b) => a - b);
      const key = days.join(',');
      if(!groups.has(key)) groups.set(key, { days, subfields: new Set(), times: new Set() });
      groups.get(key).subfields.add(s.subfield);
      groups.get(key).times.add(s.time);
    });
    const firstDay = g => Math.min(...g.days.map(d => d === 0 ? 7 : d));
    const availability = [...groups.values()]
      .sort((a, b) => firstDay(a) - firstDay(b))
      .map(g => ({
        days: g.days,
        subfields: [...g.subfields].sort((a, b) => a.localeCompare(b)),
        times: [...g.times].sort((a, b) => slotStartMinutesRaw(a) - slotStartMinutesRaw(b)),
      }));
    const out = { id: f.id, name: f.name };
    if(f.short_name) out.short = f.short_name;
    out.note = f.note;
    out.availability = availability;
    return out;
  }).filter(f => f.availability.length);
}

window.FIELDS_FALLBACK = FIELDS_FALLBACK;
window.buildFieldCatalog = buildFieldCatalog;
window.slotStartMinutesRaw = slotStartMinutesRaw;
