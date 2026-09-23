// Supabase Edge Function: invite-coach
//
// Reference copy of the deployed function, pulled from the dashboard
// 2026-09-18 so the source no longer lives only there.
//
// Despite the name (kept so the deployed URL doesn't change), this now
// handles every account-creation flow (public sign-up is OFF; this is the
// only way in):
//   - An ADMIN can invite a DIRECTOR (any gender), or a COACH or ASSISTANT
//     (any team).
//   - A DIRECTOR can invite a COACH or ASSISTANT, but only onto a team in
//     their own gender.
//   - A HEAD COACH can invite ASSISTANT coaches onto their own team only, by
//     email only (no passwords), at most MAX_ASSISTANTS per team. Assistants
//     are view-only; the database refuses their writes (see
//     supabase/assistant_role_2026_09_22.sql).
//   - Either can, instead of sending an email invite, set a PASSWORD directly
//     and create the account outright — for when email isn't reliable or the
//     person isn't reachable by email at all. The caller is shown the
//     password once and is responsible for sharing it themselves.
//
// WHY THIS HAS TO BE A SERVER FUNCTION: inviting/creating a user requires
// the Supabase service role key, which can create accounts and bypass every
// RLS policy. That key must never be shipped to the browser. This function
// holds it as a server-side secret and only ever uses it after confirming
// the caller's own role.
//
// REQUEST BODY:
//   Inviting a coach:    { "email": "...", "inviteRole": "coach", "teamId": "<uuid>" }
//   Inviting a director: { "email": "...", "inviteRole": "director", "gender": "boys"|"girls" }
//   Adding an assistant: { "email": "...", "inviteRole": "assistant", "teamId": "<uuid>" }
//                        (a head coach's own team is used whatever teamId says)
//   Optional on any:     "firstName", "lastName"
//   Add "password": "<8+ chars>" to any of the above to create the account
//   directly with that password instead of emailing an invite link.
//   (inviteRole defaults to "coach" if omitted, for backward compatibility)
// RESPONSE: { "ok": true } or { "ok": false, "error": "..." }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// JJ, 2026-09-22: a head coach may add up to 3. Directors and admins aren't capped.
const MAX_ASSISTANTS = 3;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ ok: false, error: "Use POST" }, 405);
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const SITE_URL = Deno.env.get("SITE_URL");

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ ok: false, error: "Function is missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY secrets" }, 500);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return json({ ok: false, error: "Missing Authorization header" }, 401);
  }
  const callerToken = authHeader.replace(/^Bearer\s+/i, "");

  const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    global: { headers: { Authorization: "Bearer " + callerToken } },
  });

  const { data: userData, error: userErr } = await callerClient.auth.getUser(callerToken);
  if (userErr || !userData?.user) {
    return json({ ok: false, error: "Could not verify caller identity" }, 401);
  }
  const callerId = userData.user.id;

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: callerProfile, error: profileErr } = await admin
    .from("profiles")
    .select("role, gender, team_id")
    .eq("id", callerId)
    .single();

  if (profileErr || !callerProfile || !["director", "admin", "coach"].includes(callerProfile.role)) {
    return json({ ok: false, error: "Only directors, admins and head coaches can send invites" }, 403);
  }
  const isHeadCoach = callerProfile.role === "coach";

  let body: {
    email?: string; inviteRole?: string; teamId?: string; gender?: string; password?: string;
    firstName?: string; lastName?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "Invalid JSON body" }, 400);
  }
  const email = (body.email || "").trim().toLowerCase();
  const inviteRole = body.inviteRole === "director" ? "director"
    : body.inviteRole === "assistant" ? "assistant" : "coach";
  if (!email) {
    return json({ ok: false, error: "email is required" }, 400);
  }
  const password = typeof body.password === "string" ? body.password : null;
  if (password !== null && password.length < 8) {
    return json({ ok: false, error: "password must be at least 8 characters" }, 400);
  }
  if (isHeadCoach && inviteRole !== "assistant") {
    return json({ ok: false, error: "Head coaches can only add assistant coaches" }, 403);
  }
  if (isHeadCoach && password !== null) {
    // A head coach never chooses someone else's password: the invite email lets
    // the assistant set their own.
    return json({ ok: false, error: "Assistant coaches are invited by email" }, 403);
  }
  const clean = (v: unknown) => (typeof v === "string" ? v.trim().slice(0, 40) : "");
  const firstName = clean(body.firstName);
  const lastName = clean(body.lastName);

  let newProfile: { role: string; gender: string; team_id: string | null };

  if (inviteRole === "director") {
    if (callerProfile.role !== "admin") {
      return json({ ok: false, error: "Only admins can invite directors" }, 403);
    }
    const gender = body.gender;
    if (gender !== "boys" && gender !== "girls") {
      return json({ ok: false, error: "gender must be 'boys' or 'girls'" }, 400);
    }
    newProfile = { role: "director", gender, team_id: null };
  } else {
    // A head coach adds to their own team, whatever the request says.
    const teamId = isHeadCoach ? callerProfile.team_id : body.teamId;
    if (!teamId) {
      return json({ ok: false, error: "teamId is required to invite a coach" }, 400);
    }
    const { data: team, error: teamErr } = await admin
      .from("teams")
      .select("id, gender, grade")
      .eq("id", teamId)
      .single();
    if (teamErr || !team) {
      return json({ ok: false, error: "Team not found" }, 404);
    }
    if (callerProfile.role === "director" && team.gender !== callerProfile.gender) {
      return json({ ok: false, error: "You can only invite coaches for " + callerProfile.gender + " teams" }, 403);
    }
    if (isHeadCoach) {
      const { count } = await admin.from("profiles")
        .select("id", { count: "exact", head: true })
        .eq("role", "assistant").eq("team_id", team.id);
      if ((count ?? 0) >= MAX_ASSISTANTS) {
        return json({ ok: false, error: `Your team already has ${MAX_ASSISTANTS} assistant coaches. Remove one to add another.` }, 409);
      }
    }
    newProfile = { role: inviteRole, gender: team.gender, team_id: team.id };
  }

  let newUserId: string;
  if (password) {
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (createErr || !created?.user) {
      return json({ ok: false, error: createErr?.message || "Could not create account" }, 400);
    }
    newUserId = created.user.id;
  } else {
    const { data: invited, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo: SITE_URL || undefined,
    });
    if (inviteErr || !invited?.user) {
      return json({ ok: false, error: inviteErr?.message || "Invite failed" }, 400);
    }
    newUserId = invited.user.id;
  }

  const { error: upsertErr } = await admin.from("profiles").upsert({
    id: newUserId,
    email,
    ...newProfile,
    invited_by: callerId,
    ...(firstName ? { first_name: firstName } : {}),
    ...(lastName ? { last_name: lastName } : {}),
  });

  if (upsertErr) {
    // A login with no profile can't see anything, but it shouldn't exist either.
    await admin.auth.admin.deleteUser(newUserId);
    return json({ ok: false, error: "Could not set up the account: " + upsertErr.message }, 500);
  }

  return json({ ok: true });
});
