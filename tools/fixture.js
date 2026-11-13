// tools/fixture.js — FIXTURE MODE (?fixture=1). index.html writes this in,
// parser-blocking, only when the URL asks for it, so it replaces
// supabase.createClient before the app first calls it. A normal visit never
// downloads it. See the note above the loader in index.html.
(function(){
  if(new URLSearchParams(location.search).get('fixture') !== '1') return;

  const uuid = (n) => 'ffffffff-0000-4000-8000-' + String(n).padStart(12, '0');
  const ADMIN_ID = uuid(1);
  const GRADES_F = ["Kindergarten","1st Grade","2nd Grade","3rd Grade","4th Grade","5th Grade","6th Grade"];

  // Girls 2nd Grade is split (Green and White), as a director would split it.
  const teams = [];
  let n = 100;
  ['girls','boys'].forEach(g => GRADES_F.forEach(grade =>
    (g === 'girls' && grade === '2nd Grade' ? ['Green', 'White'] : [null]).forEach(name =>
      teams.push({ id: uuid(++n), gender: g, grade, name, league_name: null, priority_finished_at: null }))));
  const teamId = (g, grade, name = null) => teams.find(t => t.gender === g && t.grade === grade && (t.name || null) === name).id;

  const profiles = [
    { id: ADMIN_ID, email: 'admin@fixture.test',  role: 'admin',    gender: null,    team_id: null },
    { id: uuid(2),  email: 'dana@fixture.test',   role: 'director', gender: 'girls', team_id: null },
    { id: uuid(3),  email: 'sam.coach@fixture.test', role: 'coach', gender: 'girls', team_id: teamId('girls','6th Grade') },
    { id: uuid(4),  email: 'jordan.reallylongaddress@fixture.test', role: 'coach', gender: 'boys', team_id: teamId('boys','5th Grade') },
    { id: uuid(5),  email: 'riley.chen@fixture.test', role: 'assistant', gender: 'girls', team_id: teamId('girls','6th Grade'),
      first_name: 'Riley', last_name: 'Chen', invited_by: uuid(3) },
    { id: uuid(6),  email: 'pat.morgan@fixture.test', role: 'coach', gender: 'girls', team_id: teamId('girls','2nd Grade','Green'),
      first_name: 'Pat', last_name: 'Morgan', invited_by: uuid(2) },
    { id: uuid(7),  email: 'casey.lin@fixture.test', role: 'coach', gender: 'girls', team_id: teamId('girls','2nd Grade','White'),
      first_name: 'Casey', last_name: 'Lin', invited_by: uuid(2) },
  ];
  // Who coaches what (team_members). Sam, the fixture coach, heads Girls 6th
  // and assists on Girls 2nd Grade Green; Riley only assists.
  const team_members = [
    [teamId('girls','6th Grade'), uuid(3), 'head'],
    [teamId('girls','6th Grade'), uuid(5), 'assistant'],
    [teamId('girls','2nd Grade','Green'), uuid(6), 'head'],
    [teamId('girls','2nd Grade','Green'), uuid(3), 'assistant'],
    [teamId('girls','2nd Grade','White'), uuid(7), 'head'],
    [teamId('boys','5th Grade'), uuid(4), 'head'],
  ].map(([team_id, profile_id, role]) => ({ team_id, profile_id, role, assigned_by: uuid(2), created_at: '2026-11-04T12:00:00Z' }));

  // Seeded off the real FIELDS table further down the page, so every fixture
  // booking sits on a slot that genuinely exists — otherwise the calendar
  // would show practices at times no field actually offers.
  const bookings = [];
  let seeded = false;
  function seedBookings(){
    if(seeded) return;
    let F;
    try { F = FIELDS; } catch(e) { return; }   // still in the TDZ; try again next query
    if(!F || !F.length) return;
    seeded = true;
    let id = 1000;
    const start = new Date(2027, 2, 1);
    for(let d = 0; d < 28; d++){
      const day = new Date(2027, 2, 1 + d);
      F.forEach((f, fi) => {
        const avail = f.availability.find(a => a.days.includes(day.getDay()));
        if(!avail) return;
        // deterministic, roughly half-full, so fullness bars have a range
        avail.times.forEach((time, ti) => avail.subfields.forEach((sub, si) => {
          if((d * 7 + fi * 3 + ti * 2 + si) % 3 !== 0) return;
          const t = teams[(d + fi + ti + si) % teams.length];
          const dateISO = day.getFullYear() + '-' + String(day.getMonth()+1).padStart(2,'0') + '-' + String(day.getDate()).padStart(2,'0');
          if(closureOf(f.id, dateISO, time, sub)) return;   // a closed slot holds no practice
          bookings.push({ id: uuid(++id), field_id: f.id, date: dateISO,
            subfield: sub, time, team_id: t.id, booked_by: ADMIN_ID });
        }));
      });
    }
    // &now=soon | &now=live: a practice today for the fixture coach (Girls 6th),
    // starting in 40 minutes or already 20 minutes in, plus two later ones, so
    // the app's countdown, Live Activity and "practice now" states are testable.
    const nowMode = new URLSearchParams(location.search).get('now');
    if(nowMode === 'soon' || nowMode === 'live'){
      const iso = d => d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' + String(d.getDate()).padStart(2,'0');
      const clock = d => (d.getHours() % 12 || 12) + ':' + String(d.getMinutes()).padStart(2,'0');
      const slot = (a, b) => clock(a) + '-' + clock(b) + (b.getHours() >= 12 ? ' PM' : ' AM');
      const coach = teamId('girls','6th Grade');
      const s0 = new Date(); s0.setSeconds(0, 0);
      s0.setMinutes(s0.getMinutes() - s0.getMinutes() % 5 + (nowMode === 'live' ? -20 : 40));
      const later = (days, h, m, mins) => { const a = new Date(); a.setDate(a.getDate() + days); a.setHours(h, m, 0, 0); return [a, new Date(a.getTime() + mins * 60000)]; };
      [[s0, new Date(s0.getTime() + 90 * 60000), 'harbor', 'Field 1'],
       [...later(1, 17, 30, 90), 'seamans', 'Field A'],
       [...later(3, 18, 0, 60), 'cedarcreek', '1/2 Field']].forEach(([a, b, f, sub]) =>
        bookings.push({ id: uuid(++id), field_id: f, date: iso(a), subfield: sub, time: slot(a, b), team_id: coach, booked_by: ADMIN_ID }));
    }
  }

  // notification_settings_2026_11_04.sql: nobody has a row until they save
  // one; a missing row means these defaults.
  const PREFS_DEFAULTS = { waitlist_opened: true, schedule_lock: true, booking_turn: true, team_bookings: false, field_duty: true, teams_chosen: false };
  const store = {
    teams, profiles, bookings, team_members,
    notification_prefs: [], notification_teams: [],
    games: [],
    waitlist: [],
    // Closures that show with no clicking, early in the season: Seamans Neck
    // on a Thursday at one time; Field B there for a week, all day (a part
    // closure); and Seaford HS on Fridays through March (a weekday closure).
    field_closures: [
      { id: uuid(900), field_id: 'seamans', start_date: '2027-03-04', end_date: '2027-03-04', times: ['5:00-6:30 PM'], subfields: null, weekdays: null,
        reason: 'School game', created_by: uuid(2), created_at: '2026-11-11T12:00:00Z' },
      { id: uuid(901), field_id: 'seamans', start_date: '2027-03-08', end_date: '2027-03-13', times: null, subfields: ['Field B'], weekdays: null,
        reason: 'Field repairs', created_by: uuid(2), created_at: '2026-11-11T12:00:00Z' },
      { id: uuid(902), field_id: 'seafordhs', start_date: '2027-03-01', end_date: '2027-03-31', times: null, subfields: null, weekdays: [5],
        reason: 'No permit', created_by: uuid(2), created_at: '2026-11-11T12:00:00Z' },
    ],
    app_settings: [{ id: true, schedule_locked: false, priority_booking_enabled: false, priority_forced_ranks: [], locked_by: null }],
  };
  window.__fixtureStore = store;

  // The closure covering a slot, if any (the contract's closed(slot)).
  // The full rule (field_closures_part2_2026_11.sql, closure_covers): field,
  // dates, and each list present holding the slot's weekday, time and part.
  const dowOf = iso => { const [y, m, d] = iso.split('-').map(Number); return new Date(y, m - 1, d).getDay(); };
  function covers(c, field, date, time, sub){
    return c.field_id === field && c.start_date <= date && date <= c.end_date
      && (c.weekdays == null || c.weekdays.includes(dowOf(date)))
      && (c.times == null || c.times.includes(time))
      && (c.subfields == null || c.subfields.includes(sub));
  }
  function closureOf(field, date, time, sub){
    return (store.field_closures || []).find(c => covers(c, field, date, time, sub)) || null;
  }

  const match = (row, filters) => filters.every(([k, op, v]) =>
    op === 'eq' ? row[k] === v : op === 'neq' ? row[k] !== v : op === 'in' ? v.includes(row[k])
    : op === 'notis' ? !(v === null ? row[k] == null : row[k] === v) : true);

  function from(table){
    let filters = [], op = 'select', payload = null, wantSingle = false, maybe = false, conflict = 'id';
    let orderBy = null, lim = null, rng = null, wantCount = false, headOnly = false;
    const rows = () => (store[table] = store[table] || []);
    async function exec(){
      seedBookings();
      // The alert tables' RLS: own rows only, and notification_teams is
      // read-only (set_notification_teams writes it).
      const own = table === 'notification_prefs' || table === 'notification_teams';
      if(table === 'notification_teams' && op !== 'select')
        return { data: null, error: { code: '42501', message: 'permission denied for table notification_teams' } };
      // field_closures has no write policy: close_field / reopen_field are the only way in.
      if(table === 'field_closures' && op !== 'select')
        return { data: null, error: { code: '42501', message: 'permission denied for table field_closures' } };
      const hit = rows().filter(r => match(r, filters) && (!own || r.profile_id === who.id));
      let data;
      if(op === 'select'){
        data = hit.map(r => ({ ...r }));
        if(orderBy) data.sort((a, b) => (a[orderBy[0]] > b[orderBy[0]] ? 1 : a[orderBy[0]] < b[orderBy[0]] ? -1 : 0) * (orderBy[1] ? 1 : -1));
        if(rng) data = data.slice(rng[0], rng[1] + 1);
        if(lim != null) data = data.slice(0, lim);
        if(wantCount || headOnly) return { data: headOnly ? null : data, count: hit.length, error: null };
      }
      else if(op === 'upsert'){
        const keys = conflict.split(',').map(k => k.trim());
        data = [];
        for(const r of (Array.isArray(payload) ? payload : [payload])){
          if(own && r.profile_id !== who.id)
            return { data: null, error: { code: '42501', message: 'new row violates row-level security policy for table "' + table + '"' } };
          const stamp = table === 'notification_prefs' ? { updated_at: new Date().toISOString() } : {};
          const ex = rows().find(x => keys.every(k => x[k] === r[k]));
          if(ex) Object.assign(ex, r, stamp);
          else rows().push({ ...(table === 'notification_prefs' ? PREFS_DEFAULTS : {}), ...r, ...stamp });
          data.push({ ...(ex || rows()[rows().length - 1]) });
        }
      }
      else if(op === 'insert'){
        const list = (Array.isArray(payload) ? payload : [payload]).map(r => ({ id: crypto.randomUUID(), ...r }));
        // mirror the real unique constraint on a slot
        for(const r of list){
          // enforce_allowed_slot(): a closed slot refuses a booking or a waitlist entry.
          if(table === 'bookings' || table === 'waitlist'){
            const c = closureOf(r.field_id, r.date, r.time, r.subfield);
            if(c) return { data: null, error: { code: '23514', message: 'Field closed: ' + c.reason } };
          }
          if(table === 'bookings' && rows().some(x => x.field_id===r.field_id && x.date===r.date && x.subfield===r.subfield && x.time===r.time))
            return { data: null, error: { code: '23505', message: 'duplicate key value violates unique constraint' } };
        }
        list.forEach(r => rows().push(r));
        data = list.map(r => ({ ...r }));
      }
      else if(op === 'update'){ hit.forEach(r => Object.assign(r, payload)); data = hit.map(r => ({ ...r })); }
      else if(op === 'delete'){ data = hit.map(r => ({ ...r })); store[table] = rows().filter(r => !match(r, filters)); }
      if(wantSingle){
        if(!data.length && !maybe) return { data: null, error: { code: 'PGRST116', message: 'no rows returned' } };
        return { data: data[0] || null, error: null };
      }
      return { data, error: null };
    }
    const api = {
      select(cols, o){ if(op === 'select'){ wantCount = !!(o && o.count); headOnly = !!(o && o.head); } return api; },
      insert(d){ op = 'insert'; payload = d; return api; },
      upsert(d, o){ op = 'upsert'; payload = d; conflict = (o && o.onConflict) || 'id'; return api; },
      update(d){ op = 'update'; payload = d; return api; },
      delete(){ op = 'delete'; return api; },
      eq(k, v){ filters.push([k, 'eq', v]); return api; },
      neq(k, v){ filters.push([k, 'neq', v]); return api; },
      in(k, v){ filters.push([k, 'in', v]); return api; },
      // .not(col, 'is', null): the priority reset's "every team" filter.
      not(k, o, v){ if(o === 'is') filters.push([k, 'notis', v]); return api; },
      order(col, o){ orderBy = [col, !(o && o.ascending === false)]; return api; }, limit(n){ lim = n; return api; }, like(){ return api; },
      // .range(from, to), both ends included, as PostgREST counts them (selectAllRows pages with it).
      range(a, b){ rng = [a, b]; return api; },
      single(){ wantSingle = true; return api; },
      maybeSingle(){ wantSingle = true; maybe = true; return api; },
      then(res, rej){ return exec().then(res, rej); },
    };
    return api;
  }

  // &as=coach signs in as Sam (heads Girls 6th Grade, assists on Girls 2nd
  // Grade Green), &as=assistant as Riley (assistant only, Girls 6th),
  // &as=director as the girls director; default is the admin. Lets every
  // role's screens be checked.
  const AS = new URLSearchParams(location.search).get('as');
  const who = AS === 'coach' ? store.profiles[2] : AS === 'assistant' ? store.profiles[4]
    : AS === 'director' ? store.profiles[1] : store.profiles[0];
  const session = { access_token: 'fixture-token', user: { id: who.id, email: who.email } };
  let authListener = null;
  const client = {
    __fixture: true,
    auth: {
      getSession: async () => ({ data: { session }, error: null }),
      getUser:    async () => ({ data: { user: session.user }, error: null }),
      onAuthStateChange: (cb) => { authListener = cb; return { data: { subscription: { unsubscribe(){} } } }; },
      signInWithPassword: async () => ({ data: { session }, error: null }),
      // Sign out the way the real client does (a SIGNED_OUT event), so the app's
      // own teardown runs.
      signOut: async () => {
        if(authListener) authListener('SIGNED_OUT', null); else location.href = location.pathname;
        return { error: null };
      },
      resetPasswordForEmail: async () => ({ data: {}, error: null }),
      updateUser: async () => ({ data: { user: session.user }, error: null }),
    },
    from,
    rpc: (name, p = {}) => rpc(name, p),
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } }),
    removeChannel: () => {},
  };

  // The database's assignment rules (teams_assignments_2026_11_04.sql), for
  // the in-memory store: one head per team (a new head replaces the old one,
  // who comes off the team), at most 3 assistants, and profiles.role/team_id
  // kept in step for every coach and assistant.
  function syncProfile(pid){
    const p = store.profiles.find(x => x.id === pid);
    if(!p || p.role === 'admin' || p.role === 'director') return;
    const mine = store.team_members.filter(m => m.profile_id === pid);
    const head = mine.find(m => m.role === 'head');
    const first = head || mine[0];
    if(head) p.role = 'coach'; else if(first) p.role = 'assistant';
    p.team_id = first ? first.team_id : null;
    if(first) p.gender = teams.find(t => t.id === first.team_id)?.gender || p.gender;
  }
  function writeMember(team_id, profile_id, role){
    const M = store.team_members;
    if(role === 'assistant' && M.filter(m => m.team_id === team_id && m.role === 'assistant' && m.profile_id !== profile_id).length >= 3)
      return 'A team can have at most 3 assistant coaches';
    const old = role === 'head' ? M.find(m => m.team_id === team_id && m.role === 'head' && m.profile_id !== profile_id) : null;
    if(old) M.splice(M.indexOf(old), 1);
    const row = M.find(m => m.team_id === team_id && m.profile_id === profile_id);
    if(row) row.role = role;
    else M.push({ team_id, profile_id, role, assigned_by: who.id, created_at: new Date().toISOString() });
    syncProfile(profile_id); if(old) syncProfile(old.profile_id);
    return null;
  }

  // The five team functions (teams_assignments_2026_11_04.sql) with the same
  // rules and the same refusal text: an admin or the program's director
  // manages; one head per team; at most 3 assistants; a team with bookings
  // can't be removed; removing a team unassigns everyone on it.
  async function rpc(name, p){
    await new Promise(r => setTimeout(r, 200));
    seedBookings();
    const fail = (message, code) => ({ data: null, error: { message, code } });
    const ok = (data = null) => ({ data, error: null });
    const manages = team => who.role === 'admin' || (who.role === 'director' && !!team && who.gender === team.gender);
    const team = teams.find(t => t.id === p.p_team);
    const clean = v => (v == null ? '' : String(v).trim()) || null;
    const taken = (gender, grade, name, except) => teams.some(t => t !== except && t.gender === gender && t.grade === grade
      && (t.name || '').toLowerCase() === (name || '').toLowerCase());
    if(name === 'create_team'){
      if(!(who.role === 'admin' || (who.role === 'director' && who.gender === p.p_gender)))
        return fail("Only an admin or this program's director can add teams", '42501');
      if(!['girls', 'boys'].includes(p.p_gender)) return fail('Program must be girls or boys', '22023');
      if(!GRADES_F.includes(p.p_grade)) return fail('Unknown grade: ' + p.p_grade, '22023');
      const nm = clean(p.p_name);
      if(taken(p.p_gender, p.p_grade, nm))
        return fail("There's already a " + (p.p_gender === 'girls' ? 'Girls' : 'Boys') + ' ' + p.p_grade + ' team'
          + (nm ? ' called ' + nm : ' without a name') + '. Give the new one a different name (Green, White...).', '23505');
      const row = { id: crypto.randomUUID(), gender: p.p_gender, grade: p.p_grade, name: nm, league_name: clean(p.p_league_name), priority_finished_at: null };
      teams.push(row);
      return ok(row.id);
    }
    if(name === 'rename_team'){
      if(!manages(team)) return fail("Only an admin or this program's director can rename teams", '42501');
      const nm = clean(p.p_name);
      if(taken(team.gender, team.grade, nm, team)) return fail('Another team in that grade already has that name', '23505');
      team.name = nm; team.league_name = clean(p.p_league_name);
      return ok();
    }
    if(name === 'delete_team'){
      if(!manages(team)) return fail("Only an admin or this program's director can remove teams", '42501');
      if(bookings.some(b => b.team_id === team.id))
        return fail('This team still has bookings. Clear them first (Admin > Clear Bookings).', '23503');
      const gone = store.team_members.filter(m => m.team_id === team.id).map(m => m.profile_id);
      store.team_members = store.team_members.filter(m => m.team_id !== team.id);
      teams.splice(teams.indexOf(team), 1);
      gone.forEach(syncProfile);
      return ok();
    }
    if(name === 'assign_team_member'){
      if(!['head', 'assistant'].includes(p.p_role)) return fail('Role must be head or assistant', '22023');
      if(!team) return fail('That team no longer exists', 'P0002');
      if(!manages(team)) return fail("Only an admin or this program's director can assign coaches", '42501');
      const target = store.profiles.find(x => x.id === p.p_profile);
      if(!target) return fail('That person no longer has an account', 'P0002');
      const old = p.p_role === 'head' ? store.team_members.find(m => m.team_id === team.id && m.role === 'head' && m.profile_id !== target.id) : null;
      const refusal = writeMember(team.id, target.id, p.p_role);
      if(refusal) return fail(refusal, '23514');
      return ok({ replaced: old ? old.profile_id : null });
    }
    if(name === 'unassign_team_member'){
      if(!manages(team)) return fail("Only an admin or this program's director can change a team's coaches", '42501');
      store.team_members = store.team_members.filter(m => !(m.team_id === p.p_team && m.profile_id === p.p_profile));
      syncProfile(p.p_profile);
      return ok();
    }
    if(name === 'set_notification_teams'){
      // null = back to the default (assigned teams, a director's program);
      // teams this person may not follow (may_follow_team) are dropped, as
      // the SQL does. Returns what was saved.
      const mayFollow = id => store.team_members.some(m => m.team_id === id && m.profile_id === who.id) || who.role === 'admin'
        || (who.role === 'director' && teams.some(t => t.id === id && t.gender === who.gender));
      const ids = p.p_team_ids == null ? null : [...new Set(p.p_team_ids)].filter(mayFollow);
      // An admin may follow any team, so an id that is no team reaches the
      // foreign key, and the whole call rolls back.
      if(ids && ids.some(id => !teams.some(t => t.id === id)))
        return fail('insert or update on table "notification_teams" violates foreign key constraint "notification_teams_team_id_fkey"', '23503');
      let row = store.notification_prefs.find(r => r.profile_id === who.id);
      if(!row){ row = { profile_id: who.id, ...PREFS_DEFAULTS }; store.notification_prefs.push(row); }
      store.notification_teams = store.notification_teams.filter(r => r.profile_id !== who.id);
      row.updated_at = new Date().toISOString();
      if(ids == null){ row.teams_chosen = false; return ok(null); }
      ids.forEach(team_id => store.notification_teams.push({ profile_id: who.id, team_id }));
      row.teams_chosen = true;
      return ok(ids);
    }
    if(name === 'import_games'){
      // games_2026_11_04.sql: directors and admins only; BYE and exact
      // duplicate rows skipped; the season is replaced outright; each game
      // is matched to a Seaford team (league_name wins).
      if(!['admin', 'director'].includes(who.role)) return fail('Only directors and admins can upload the league schedule', '42501');
      if(!Array.isArray(p.p_rows)) return fail('Expected a list of games', '22023');
      const rows = p.p_rows.map(r => ({
        game_number: r.game_number == null ? null : parseInt(r.game_number, 10), game_date: r.date || null,
        start_time: r.time || null, field_label: (r.field || '').trim() || null, town: (r.town || '').trim() || null,
        home: String(r.home || '').trim(), away: String(r.away || '').trim(),
        gender: (r.gender || '').trim().toLowerCase() || null,
        grade: (g => g == null ? null : /^(k|kindergarten)$/i.test(g.trim()) ? 'Kindergarten'
          : /^[1-6](st|nd|rd|th)/.test(g.trim()) ? g.trim().match(/^[1-6](?:st|nd|rd|th)/)[0] + ' Grade' : g.trim())(r.grade),
        division: (r.division || '').trim() || null, note: (r.note || '').trim() || null }));
      const bye = x => ['BYE', 'N/A', ''].includes(x.toUpperCase());
      const byes = rows.filter(r => bye(r.home) || bye(r.away)).length;
      const kept = rows.filter(r => !(bye(r.home) || bye(r.away) || r.game_number == null || r.game_date == null));
      if(kept.some(r => r.gender !== 'girls' && r.gender !== 'boys')) return fail('Every game needs Girls or Boys', '22023');
      const uniq = new Map(); kept.forEach(r => uniq.set(JSON.stringify(r), r));
      const removed = store.games.filter(g => g.season === p.p_season).length;
      store.games = store.games.filter(g => g.season !== p.p_season);
      const matchTeam = (nm, gender) => {
        const want = nm.trim().toLowerCase(), squash = nm.trim().replace(/\s+/g, ' ').toLowerCase();
        const byLeague = teams.find(t => t.gender === gender && t.league_name && t.league_name.trim().toLowerCase() === want);
        return byLeague || teams.find(t => t.gender === gender && !t.league_name
          && ('seaford ' + (t.grade === 'Kindergarten' ? 'k' : t.grade[0]) + (t.name ? ' ' + t.name : '')).toLowerCase() === squash) || null;
      };
      [...uniq.values()].forEach(r => {
        const isHome = /^seaford/i.test(r.home), lf = (r.field_label || '').toLowerCase();
        const team = matchTeam(isHome ? r.home : r.away, r.gender);
        store.games.push({ id: crypto.randomUUID(), season: p.p_season, game_number: r.game_number, game_date: r.game_date,
          start_time: r.start_time ? r.start_time + ':00' : null, field_label: r.field_label,
          field_id: ['shs', 'seaford hs', 'seaford high school'].includes(lf) ? 'seafordhs' : lf.startsWith('cedar creek') ? 'cedarcreek' : null,
          town: r.town, home: r.home, away: r.away, gender: r.gender, grade: r.grade, division: r.division, note: r.note,
          is_home: isHome, seaford_team_id: team ? team.id : null, imported_at: new Date().toISOString(), imported_by: who.id });
      });
      const season = store.games.filter(g => g.season === p.p_season);
      const clock12 = t => { const [h, m] = t.split(':'); return ((+h % 12) || 12) + ':' + m + (+h < 12 ? ' AM' : ' PM'); };
      return ok({ imported: season.length, removed, byes,
        unmatched: [...new Set(season.filter(g => !g.seaford_team_id).map(g => /^seaford/i.test(g.home) ? g.home : g.away))].sort(),
        odd_times: season.filter(g => g.start_time && (g.start_time < '07:00' || g.start_time > '20:00'))
          .sort((a, b) => (a.game_date + a.game_number).localeCompare(b.game_date + b.game_number))
          .map(g => ({ game: g.gender[0].toUpperCase() + g.gender.slice(1) + ' ' + g.game_number, date: g.game_date, time: clock12(g.start_time), teams: g.home + ' v ' + g.away })) });
    }
    // field_closures_part2_2026_11.sql: closure_input's checks, with its
    // refusal text, on what a close or an edit sends; the lists come back
    // tidied (distinct, sorted) or null.
    const iso = d => d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    function closureInput(fieldId, q){
      const slots = (FIELDS.find(f => f.id === fieldId) || {}).availability || [];
      const isoOk = v => /^\d{4}-\d{2}-\d{2}$/.test(String(v));
      if(!isoOk(q.p_start) || !isoOk(q.p_end) || q.p_end < q.p_start) return { error: 'The last day is before the first' };
      if(q.p_end < iso(new Date())) return { error: 'Those dates have passed' };
      if((Date.parse(q.p_end) - Date.parse(q.p_start)) / 86400000 > 366) return { error: 'A closure can run for a year at most' };
      const reason = String(q.p_reason == null ? '' : q.p_reason).trim();
      if(reason.length < 1 || reason.length > 40) return { error: 'The reason needs 1 to 40 characters' };
      const tidy = (v, num) => v == null ? null : [...new Set(v.filter(x => x != null))].sort(num ? (a, b) => a - b : undefined);
      const times = tidy(q.p_times), subfields = tidy(q.p_subfields), weekdays = tidy(q.p_weekdays, true);
      if(times){
        if(!times.length) return { error: 'Pick at least one time, or close the whole day' };
        const have = new Set(slots.flatMap(a => a.times));
        if(times.some(t => !have.has(t))) return { error: 'That field has no such time' };
      }
      if(subfields){
        if(!subfields.length) return { error: 'Pick at least one part, or close every part' };
        const have = new Set(slots.flatMap(a => a.subfields));
        if(subfields.some(t => !have.has(t))) return { error: 'That field has no such part' };
      }
      if(weekdays){
        if(!weekdays.length) return { error: 'Pick at least one day of the week, or close every day' };
        if(weekdays.some(d => !Number.isInteger(d) || d < 0 || d > 6)) return { error: 'That is not a day of the week' };
        let falls = false;
        for(let d = new Date(q.p_start + 'T00:00'), end = new Date(q.p_end + 'T00:00'); d <= end && !falls; d.setDate(d.getDate() + 1)) falls = weekdays.includes(d.getDay());
        if(!falls) return { error: 'None of those days fall in the dates' };
      }
      return { times, subfields, weekdays, reason };
    }
    // apply_closure: what the closure covers from today on goes, waitlist
    // first, then the practices. Returns the practices cancelled.
    function applyClosure(c){
      const today = iso(new Date());
      const gone = r => r.date >= today && covers(c, r.field_id, r.date, r.time, r.subfield);
      store.waitlist = store.waitlist.filter(r => !gone(r));
      const before = store.bookings.length;
      store.bookings = store.bookings.filter(r => !gone(r));
      return before - store.bookings.length;
    }
    if(name === 'close_field'){
      // Admins and directors; either director, any field.
      if(!['admin', 'director'].includes(who.role)) return fail('Only an admin or a director can close a field', '42501');
      if(!FIELDS.some(f => f.id === p.p_field)) return fail('That field does not exist', '22023');
      const v = closureInput(p.p_field, p);
      if(v.error) return fail(v.error, '22023');
      const closure = { id: crypto.randomUUID(), field_id: p.p_field, start_date: p.p_start, end_date: p.p_end,
        times: v.times, subfields: v.subfields, weekdays: v.weekdays, reason: v.reason, created_by: who.id, created_at: new Date().toISOString() };
      store.field_closures.push(closure);
      return ok({ closure: { ...closure }, cancelled: applyClosure(closure) });
    }
    if(name === 'edit_closure'){
      // Same field, new everything else; what it newly covers is cancelled.
      if(!['admin', 'director'].includes(who.role)) return fail('Only an admin or a director can change a closure', '42501');
      const old = store.field_closures.find(c => c.id === p.p_id);
      if(!old) return fail('That closure no longer exists', '22023');
      if(old.end_date < iso(new Date())) return fail('That closure has ended', '22023');
      const v = closureInput(old.field_id, p);
      if(v.error) return fail(v.error, '22023');
      Object.assign(old, { start_date: p.p_start, end_date: p.p_end, times: v.times, subfields: v.subfields, weekdays: v.weekdays, reason: v.reason });
      return ok({ closure: { ...old }, cancelled: applyClosure(old) });
    }
    if(name === 'reopen_field'){
      if(!['admin', 'director'].includes(who.role)) return fail('Only an admin or a director can reopen a field', '42501');
      store.field_closures = store.field_closures.filter(c => c.id !== p.p_id);
      return ok(null);
    }
    return fail('Unknown function ' + name, '42883');
  }

  // invite-coach and manage-user are called with fetch, not the client, so
  // they get a stand-in too: same rules as the deployed functions (since
  // 2026-11-05 only admins and directors invite; manage-user still lets a
  // head coach remove their own assistants), applied to the in-memory store.
  // Nothing leaves the page.
  const realFetch = window.fetch.bind(window);
  window.fetch = async (url, opts = {}) => {
    const fn = String(url).match(/\/functions\/v1\/(invite-coach|manage-user)$/);
    if(!fn) return realFetch(url, opts);
    await new Promise(r => setTimeout(r, 350));
    const body = JSON.parse(opts.body || '{}');
    const reply = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });
    const P = store.profiles;
    if(fn[1] === 'invite-coach'){
      if(!['admin', 'director'].includes(who.role)) return reply({ ok: false, error: 'Only directors and admins can invite coaches. Ask your director.' }, 403);
      const role = body.inviteRole === 'director' ? 'director' : body.inviteRole === 'assistant' ? 'assistant' : 'coach';
      if(role === 'director' && who.role !== 'admin') return reply({ ok: false, error: 'Only admins can invite directors' }, 403);
      const team = teams.find(t => t.id === body.teamId);
      if(role !== 'director' && !team) return reply({ ok: false, error: 'Team not found' }, 404);
      if(role !== 'director' && who.role === 'director' && team.gender !== who.gender)
        return reply({ ok: false, error: 'You can only invite coaches for ' + who.gender + ' teams' }, 403);
      if(role === 'assistant' && store.team_members.filter(m => m.team_id === team.id && m.role === 'assistant').length >= 3)
        return reply({ ok: false, error: 'That team already has 3 assistant coaches. Remove one to add another.' }, 409);
      const email = String(body.email || '').trim().toLowerCase();
      if(P.some(x => x.email === email)) return reply({ ok: false, error: 'A user with this email address has already been registered' }, 400);
      const id = crypto.randomUUID();
      P.push({ id, email, role, gender: role === 'director' ? body.gender : team.gender,
        team_id: role === 'director' ? null : team.id, first_name: body.firstName || null, last_name: body.lastName || null, invited_by: who.id });
      // profiles_assign_from_invite: an invited coach heads the team, an assistant assists.
      if(role !== 'director') writeMember(team.id, id, role === 'coach' ? 'head' : 'assistant');
      return reply({ ok: true });
    }
    if(body.action === 'last-seen') return reply({ ok: true, seen: {} });
    if(body.action === 'delete-me') return reply({ ok: true });
    const target = P.find(x => x.id === body.userId);
    if(!target) return reply({ ok: false, error: 'User not found' }, 404);
    if(who.role === 'coach' && !(body.action === 'remove' && target.role === 'assistant' && target.team_id === who.team_id))
      return reply({ ok: false, error: "You can only remove your own team's assistant coaches" }, 403);
    if(body.action === 'remove'){
      const gone = new Set([target.id, ...(target.role === 'coach' ? P.filter(x => x.invited_by === target.id && x.role === 'assistant').map(x => x.id) : [])]);
      for(let i = P.length - 1; i >= 0; i--) if(gone.has(P[i].id)) P.splice(i, 1);
      store.team_members = store.team_members.filter(m => !gone.has(m.profile_id)); // on delete cascade
      return reply({ ok: true, email: target.email, assistantsRemoved: gone.size - 1 });
    }
    if(body.action === 'set-name'){ target.first_name = body.firstName || null; target.last_name = body.lastName || null; return reply({ ok: true }); }
    return reply({ ok: true });
  };

  window.supabase = window.supabase || {};
  window.supabase.createClient = function(){ return client; };

  // Unmistakable on screen: nobody should ever confuse this for real data.
  // &shots=1 drops the banner for App Store screenshot capture, where the
  // frame has to be exactly 1320x2868 and a dev banner would ship to Apple.
  const SHOTS = /[?&]shots=1/.test(location.search);
  addEventListener('DOMContentLoaded', () => {
    if(SHOTS) return;
    const bar = document.createElement('div');
    bar.textContent = 'FIXTURE MODE — sample data, nothing is saved';
    bar.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:9999;background:#b0402a;color:#fff;'
      + 'font:800 11px/1 system-ui,sans-serif;letter-spacing:1px;text-align:center;padding:6px 8px;text-transform:uppercase';
    document.body.appendChild(bar);
  });
})();
