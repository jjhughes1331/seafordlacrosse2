// league-sheet.js — reads the league's .xlsx schedule into games for the
// database's import_games(). No third-party code: the zip's central
// directory, DecompressionStream('deflate-raw'), shared strings and sheet XML
// through DOMParser. A port of SeafordKit/LeagueSheet.swift + XLSX.swift (the
// iPhone app's reader); the same workbook gives the same rows. Keep the two
// in step.
//
//   LeagueSheet.read(arrayBuffer)  -> Promise<sheet>; rejects with Error(message)
//   LeagueSheet.parse(sheets)      -> sheet, from [{ name, rows: [[cell text]] }]
//   LeagueSheet.unmatched(games, teams) -> Seaford names no team matches
//   sheet = { games, byes, season, homeCount, oddTimes, noGender, skippedText }
//   game  = { game_number, date, time, field, town, home, away, gender, grade, division, note }
//
// Columns are found by their header names (Date, Time, Field Location,
// Location, Home, Away, Division), gender and grade by value. "All Games"
// gives the schedule; an "All Home" sheet fills in each home game's time,
// field and note.
(function(){
  'use strict';

  const fail = why => Object.assign(new Error(why), { why });
  const NOT_A_SHEET = 'That file isn’t a spreadsheet.';
  const NOT_SCHEDULE = 'This doesn’t look like the league schedule: no sheet has Date, Home and Away columns.';
  const DAMAGED = 'its contents are damaged.';

  // ---- Zip ----------------------------------------------------------------
  function readZip(buf){
    const bytes = new Uint8Array(buf);
    const dv = new DataView(buf);
    if(bytes.length < 22) throw fail('the file is empty or cut short.');
    let end = bytes.length - 22;
    while(end >= Math.max(0, bytes.length - 65557) && dv.getUint32(end, true) !== 0x06054b50) end--;
    if(end < 0 || dv.getUint32(end, true) !== 0x06054b50) throw fail('it isn’t a valid .xlsx file.');
    const count = dv.getUint16(end + 10, true);
    let p = dv.getUint32(end + 16, true);
    const entries = new Map();
    const utf8 = new TextDecoder('utf-8');
    for(let i = 0; i < count; i++){
      if(p + 46 > bytes.length || dv.getUint32(p, true) !== 0x02014b50) throw fail(DAMAGED);
      const nameLen = dv.getUint16(p + 28, true), extra = dv.getUint16(p + 30, true), comment = dv.getUint16(p + 32, true);
      if(p + 46 + nameLen > bytes.length) throw fail(DAMAGED);
      const name = utf8.decode(bytes.subarray(p + 46, p + 46 + nameLen));
      entries.set(name, { method: dv.getUint16(p + 10, true), compressed: dv.getUint32(p + 20, true),
        size: dv.getUint32(p + 24, true), offset: dv.getUint32(p + 42, true) });
      p += 46 + nameLen + extra + comment;
    }
    return {
      names: [...entries.keys()].sort(),
      async file(name){
        const e = entries.get(name);
        if(!e) return null;
        if(e.offset + 30 > bytes.length) throw fail(DAMAGED);
        const start = e.offset + 30 + dv.getUint16(e.offset + 26, true) + dv.getUint16(e.offset + 28, true);
        if(start + e.compressed > bytes.length) throw fail(DAMAGED);
        const raw = bytes.subarray(start, start + e.compressed);
        if(e.method === 0) return raw;
        if(e.method !== 8) throw fail('it uses a compression this page can’t read.');
        if(e.size === 0) return new Uint8Array(0);
        if(e.size > 50000000) throw fail('it is too large.');
        if(typeof DecompressionStream === 'undefined') throw fail('this browser can’t open spreadsheets. Update it and try again.');
        let out;
        try {
          out = new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
        } catch(err){ throw fail(DAMAGED); }
        if(out.length !== e.size) throw fail(DAMAGED);
        return out;
      },
    };
  }

  // ---- XML ----------------------------------------------------------------
  function xml(bytes){
    const doc = new DOMParser().parseFromString(new TextDecoder('utf-8').decode(bytes), 'application/xml');
    if(doc.getElementsByTagName('parsererror').length) throw fail('its text is damaged.');
    return doc;
  }
  const kids = (node, local) => [...node.getElementsByTagName('*')].filter(n => n.localName === local);
  const REL_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  function relId(node){
    return node.getAttributeNS(REL_NS, 'id') || node.getAttribute('r:id')
      || ([...node.attributes].find(a => a.localName === 'id') || {}).value || null;
  }

  // sharedStrings.xml: each <si>'s text, its runs joined, phonetic runs left out.
  function sharedStrings(bytes){
    return kids(xml(bytes), 'si').map(si => {
      let s = '';
      (function walk(n){
        for(const c of n.children){
          if(c.localName === 'rPh') continue;
          if(c.localName === 't') s += c.textContent; else walk(c);
        }
      })(si);
      return s;
    });
  }

  // "C12" -> { row: 11, column: 2 }
  function position(ref){
    let col = 0, digits = '';
    for(const ch of ref.toUpperCase()){
      const a = ch.charCodeAt(0);
      if(a >= 65 && a <= 90) col = Math.min(col * 26 + (a - 64), 1000000); else digits += ch;
    }
    const row = /^\d+$/.test(digits) ? parseInt(digits, 10) : NaN;
    if(!(col > 0) || !(row > 0)) return null;
    return { row: row - 1, column: col - 1 };
  }
  const MAX_ROWS = 100000, MAX_COLUMNS = 256;

  // A worksheet's cells, placed by their A1 references, as rows of text.
  function sheetRows(bytes, strings){
    const doc = xml(bytes);
    const rows = new Map();
    let rowIndex = 0;
    for(const row of kids(doc, 'row')){
      const r = parseInt(row.getAttribute('r'), 10);
      if(Number.isFinite(r)) rowIndex = r - 1;
      let column = 0;
      for(const c of row.children){
        if(c.localName !== 'c') continue;
        const ref = c.getAttribute('r');
        const pos = ref ? position(ref) : null;
        if(pos){ rowIndex = pos.row; column = pos.column; }
        const type = c.getAttribute('t') || 'n';
        let value = '';
        (function walk(n){
          for(const k of n.children){
            if(k.localName === 'v' || k.localName === 't') value += k.textContent; else walk(k);
          }
        })(c);
        let text;
        if(type === 's'){ const i = /^\d+$/.test(value) ? parseInt(value, 10) : -1; text = i >= 0 && i < strings.length ? strings[i] : ''; }
        else if(type === 'b') text = value === '1' ? 'TRUE' : 'FALSE';
        else text = value;
        if(text && rowIndex >= 0 && rowIndex < MAX_ROWS && column >= 0 && column < MAX_COLUMNS){
          if(!rows.has(rowIndex)) rows.set(rowIndex, new Map());
          rows.get(rowIndex).set(column, text);
        }
        column++;
      }
      rowIndex++;
    }
    if(!rows.size) return [];
    const last = Math.max(...rows.keys());
    const out = [];
    for(let r = 0; r <= last; r++){
      const cells = rows.get(r);
      if(!cells){ out.push([]); continue; }
      const width = Math.max(...cells.keys());
      const line = [];
      for(let c = 0; c <= width; c++) line.push(cells.get(c) || '');
      out.push(line);
    }
    return out;
  }

  // Every sheet in workbook order, with its name. Numbers stay raw text ("46103").
  async function workbookSheets(buf){
    const zip = readZip(buf);
    const ss = await zip.file('xl/sharedStrings.xml');
    const strings = ss ? sharedStrings(ss) : [];
    let found = [];
    const book = await zip.file('xl/workbook.xml');
    if(book){
      const relBytes = await zip.file('xl/_rels/workbook.xml.rels');
      const rels = {};
      if(relBytes) kids(xml(relBytes), 'Relationship').forEach(n => { if(n.getAttribute('Id') && n.getAttribute('Target')) rels[n.getAttribute('Id')] = n.getAttribute('Target'); });
      kids(xml(book), 'sheet').forEach((n, i) => {
        const id = relId(n), target = id ? rels[id] : null;
        if(target) found.push({ name: n.getAttribute('name') || ('Sheet' + (i + 1)), path: target.startsWith('/') ? target.slice(1) : 'xl/' + target });
      });
    }
    if(!found.length){
      found = zip.names.filter(n => n.startsWith('xl/worksheets/') && n.endsWith('.xml')).map((path, i) => ({ name: 'Sheet' + (i + 1), path }));
    }
    const out = [];
    for(const f of found){
      const bytes = await zip.file(f.path);
      if(bytes) out.push({ name: f.name, rows: sheetRows(bytes, strings) });
    }
    return out;
  }

  // ---- Cells --------------------------------------------------------------
  const clean = cell => String(cell).replace(/ /g, ' ').trim();
  const NUMBER = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/;
  const num = s => (s != null && NUMBER.test(s) ? Number(s) : null);
  const pad = n => String(n).padStart(2, '0');
  const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  // Excel serial day (days since 1899-12-30) as a UTC-midnight Date.
  function day(serial){
    if(!Number.isFinite(serial) || serial < 1 || serial >= 2958466) return null;
    return new Date(Date.UTC(1899, 11, 30) + Math.floor(serial) * 86400000);
  }
  const iso = d => d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
  const dayText = d => DAYS[d.getUTCDay()] + ', ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCDate();
  const isoDate = serial => { const d = day(serial); return d ? iso(d) : null; };
  const noteDate = serial => { const d = day(serial); return d ? dayText(d) : null; };

  // A day fraction ("0.375") or clock text ("9:00 AM", "13:30") as "HH:mm";
  // null when blank or not a time.
  const CLOCK = /^(?:(\d{1,2}):(\d{2})(?::\d{2})?\s*([ap])\.?m\.?|(\d{1,2}):(\d{2})(?::\d{2})?)$/i;
  function clock(cell){
    const v = num(cell);
    if(v !== null){
      if(!Number.isFinite(v) || v < 0 || v >= 1000) return null;
      const minutes = Math.round((v % 1) * 1440) % 1440;
      return pad(Math.floor(minutes / 60)) + ':' + pad(minutes % 60);
    }
    const m = CLOCK.exec(cell);
    if(!m) return null;
    const meridiem = m[3] ? m[3].toLowerCase() : null;
    const h = parseInt(m[1] || m[4], 10), min = parseInt(m[2] || m[5], 10);
    if(min >= 60) return null;
    let hour = h;
    if(meridiem){
      if(h < 1 || h > 12) return null;
      hour = h % 12 + (meridiem === 'p' ? 12 : 0);
    } else if(h > 23) return null;
    return pad(hour) + ':' + pad(min);
  }

  // "5/3" in `year` as "Sun, May 3"; null when the text isn't a month/day.
  function monthDay(text, year){
    const parts = text.split('/');
    if(parts.length !== 2 || !parts.every(p => /^\d{1,2}$/.test(p))) return null;
    const m = parseInt(parts[0], 10), d = parseInt(parts[1], 10);
    const date = new Date(Date.UTC(year, m - 1, d));
    if(m < 1 || m > 12 || date.getUTCMonth() !== m - 1 || date.getUTCDate() !== d) return null;
    return dayText(date);
  }

  const isBye = team => ['bye', 'n/a'].includes(team.toLowerCase());

  // ---- A sheet with Date, Home and Away headers ---------------------------
  const GRADE = /^(K|Kindergarten|Pre-?K|[1-8](st|nd|rd|th))( Grade)?$/i;

  function makeTable(name, rawRows){
    const cleaned = rawRows.map(r => r.map(clean));
    const at = cleaned.findIndex(r => { const h = r.map(x => x.toLowerCase()); return h.includes('date') && h.includes('home') && h.includes('away'); });
    if(at < 0) return null;
    const h = cleaned[at].map(x => x.toLowerCase());
    const col = title => { const i = h.indexOf(title); return i < 0 ? null : i; };
    const t = { name: clean(name).toLowerCase(), body: cleaned.slice(at + 1),
      date: col('date'), home: col('home'), away: col('away'),
      time: col('time'), field: col('field location'), town: col('location'), division: col('division'), grade: col('grade'), note: null };
    // The notes column: headed "Note(s)", else the unheaded column after the Girls/Boys cells.
    const n = h.findIndex(x => x === 'note' || x === 'notes');
    if(n >= 0) t.note = n;
    else {
      let last = -1;
      t.body.forEach(r => r.forEach((c, i) => { if(['girls', 'boys'].includes(c.toLowerCase()) && i > last) last = i; }));
      if(last >= 0 && (last + 1 >= h.length || h[last + 1] === '')) t.note = last + 1;
    }
    return t;
  }

  const cellAt = (row, i) => (i == null || i >= row.length || row[i] === '' ? null : row[i]);

  // The row as a game (gender null when it has no Girls/Boys cell), or null when it isn't a game row.
  function tableGame(t, row){
    const number = num(cellAt(row, 0));
    if(number === null || Math.abs(number) >= 1e9) return null;
    const serial = num(cellAt(row, t.date));
    const date = serial === null ? null : isoDate(serial);
    const home = cellAt(row, t.home), away = cellAt(row, t.away);
    if(!date || !home || !away) return null;
    const g = row.map(c => c.toLowerCase()).find(c => c === 'girls' || c === 'boys');
    const gender = g || null;
    let note = cellAt(row, t.note);
    let grade = cellAt(row, t.grade);
    if(t.grade == null){
      const skip = new Set([t.date, t.home, t.away, t.time, t.field, t.town, t.division, t.note].filter(x => x != null));
      const i = row.findIndex((c, k) => !skip.has(k) && GRADE.test(c));
      grade = i >= 0 ? row[i] : null;
    }
    const n = note == null ? null : num(note);
    if(n !== null && n > 40000 && noteDate(n)) note = 'Rescheduled to ' + noteDate(n);
    const t0 = cellAt(row, t.time);
    return { gender, game: { game_number: Math.trunc(number), date, time: t0 == null ? null : clock(t0),
      field: cellAt(row, t.field), town: cellAt(row, t.town), home, away, gender: gender || '', grade,
      division: cellAt(row, t.division), note } };
  }

  function parse(sheets){
    const usable = sheets.map(s => makeTable(s.name, s.rows)).filter(Boolean);
    const home = usable.find(t => t.name.includes('all home')) || null;
    const main = usable.find(t => t.name.includes('all games'))
      || usable.find(t => !home || t.name !== home.name) || usable[0];
    if(!main) throw fail(NOT_SCHEDULE);

    let noGender = 0, byes = 0;
    const seen = new Set(), games = [], index = new Map();
    const identity = g => [g.date, g.home, g.away, g.gender, g.grade == null ? '' : g.grade, g.game_number].join('|');
    const key = g => [g.date, g.home, g.away, g.gender].join('|');

    for(const row of main.body){
      const parsed = tableGame(main, row);
      if(!parsed) continue;
      if(isBye(parsed.game.home) || isBye(parsed.game.away)){ byes++; continue; }
      if(!parsed.gender){ noGender++; continue; }
      const game = parsed.game; game.gender = parsed.gender;
      if(seen.has(identity(game))) continue;
      seen.add(identity(game));
      if(!index.has(key(game))) index.set(key(game), games.length);
      games.push(game);
    }

    // The home sheet fills time, field and note on the same game, or adds a game the main sheet lacks.
    if(home && home.name !== main.name){
      for(const row of home.body){
        const parsed = tableGame(home, row);
        if(!parsed || isBye(parsed.game.home) || isBye(parsed.game.away) || !parsed.gender) continue;
        const game = parsed.game; game.gender = parsed.gender;
        if(index.has(key(game))){
          const at = games[index.get(key(game))];
          if(game.time != null) at.time = game.time;
          if(game.field != null) at.field = game.field;
          if(game.note != null) at.note = game.note;
        } else if(!seen.has(identity(game))){
          seen.add(identity(game));
          index.set(key(game), games.length);
          games.push(game);
        }
      }
    }

    const earliest = games.map(g => g.date).sort()[0];
    const season = earliest ? parseInt(earliest.slice(0, 4), 10) : NaN;
    if(!Number.isFinite(season)) throw fail(NOT_SCHEDULE);
    // A note like "5/3" is a reschedule date in the season's year.
    for(const g of games){
      const text = g.note == null ? null : monthDay(g.note, season);
      if(text) g.note = 'Rescheduled to ' + text;
    }
    const oddTimes = games.filter(g => g.time != null && (g.time < '07:00' || g.time > '20:00'));
    const homeCount = games.filter(g => g.home.toLowerCase().startsWith('seaford')).length;
    return { games, byes, season, homeCount, oddTimes, noGender,
      skippedText: noGender > 0 ? noGender + (noGender === 1 ? ' row' : ' rows') + ' skipped (no Girls/Boys)' : null };
  }

  async function read(buf){
    let sheets;
    try { sheets = await workbookSheets(buf); } catch(err){ throw fail(NOT_A_SHEET); }
    return parse(sheets);
  }

  // The database's match_seaford_team(), for the preview: league_name wins when
  // set; otherwise "Seaford <grade digit or K>[ <name>]". Returns the Seaford
  // names (home if it starts with Seaford, else away) that no team matches.
  function matchTeam(name, gender, teams){
    const want = name.trim().toLowerCase();
    const squashed = name.trim().replace(/\s+/g, ' ').toLowerCase();
    return teams.find(t => t.gender === gender && t.league_name != null && t.league_name.trim().toLowerCase() === want)
      || teams.find(t => t.gender === gender && t.league_name == null
        && ('seaford ' + (t.grade === 'Kindergarten' ? 'k' : String(t.grade).charAt(0).toLowerCase()) + (t.name ? ' ' + t.name : '')).toLowerCase() === squashed)
      || null;
  }
  function unmatched(games, teams){
    const out = new Set();
    for(const g of games){
      const h = g.home.toLowerCase().startsWith('seaford'), a = g.away.toLowerCase().startsWith('seaford');
      if(!h && !a) continue;
      const name = h ? g.home : g.away;
      if(!matchTeam(name, g.gender, teams)) out.add(name);
    }
    return [...out].sort();
  }

  window.LeagueSheet = { read, parse, unmatched, matchTeam, clock, workbookSheets };
})();
