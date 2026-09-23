// Supabase Edge Function: manage-user
//
// Reference copy of the deployed function. (invite-coach's source lives only
// in the dashboard — that's a fragility; new functions get a copy here.)
//
// Removing a user and resetting someone's password both need the service
// role key, which can bypass every RLS policy and must never reach a
// browser. This function holds it server-side and only acts after checking
// the caller's own role — the same scoping the invite flow uses:
//   - ADMIN may act on any director, coach or assistant.
//   - DIRECTOR may act only on coaches and assistants in their own gender.
//   - HEAD COACH may only REMOVE assistants on their own team.
//   - Removing a head coach also removes the assistants they added.
//   - Nobody may act on themselves (that's how you lock yourself out),
//     except delete-me and naming yourself, which ANY signed-in user may do.
//     (Until 2026-09-22 the director/admin gate ran first, so a coach could
//     neither delete their own account nor save their name.)
//
// REQUEST BODY:
//   { "action": "reset-password", "userId": "<uuid>", "password": "<8+ chars>" }
//   { "action": "remove",         "userId": "<uuid>" }
//   { "action": "set-name",       "userId": "<uuid>", "firstName": "...", "lastName": "..." }
//   { "action": "last-seen" }   -> { ok, seen: { "<uuid>": "<iso>" | null } }
//   { "action": "delete-me" }   -> deletes the CALLER's own account
//
// delete-me exists because the App Store requires an app that has accounts to
// let a person delete their own from inside the app (guideline 5.1.1(v)).
// It is the one action that is allowed to target the caller.
// RESPONSE: { "ok": true, ... } or { "ok": false, "error": "..." }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ ok: false, error: "Use POST" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ ok: false, error: "Function is missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY secrets" }, 500);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ ok: false, error: "Missing Authorization header" }, 401);
  const callerToken = authHeader.replace(/^Bearer\s+/i, "");

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: userData, error: userErr } = await admin.auth.getUser(callerToken);
  if (userErr || !userData?.user) return json({ ok: false, error: "Could not verify caller identity" }, 401);
  const callerId = userData.user.id;

  const { data: caller, error: callerErr } = await admin
    .from("profiles").select("role, gender, team_id, email").eq("id", callerId).single();
  if (callerErr || !caller) return json({ ok: false, error: "Could not find your account" }, 403);
  // Deleting your own account (App Store 5.1.1(v)) and naming yourself are
  // for everyone. Anything that touches another person needs a manager.
  const isManager = caller.role === "director" || caller.role === "admin";
  const isHeadCoach = caller.role === "coach";
  const notManager = () => json({ ok: false, error: "Only directors and admins can manage users" }, 403);

  let body: { action?: string; userId?: string; password?: string; firstName?: string; lastName?: string };
  try { body = await req.json(); } catch { return json({ ok: false, error: "Invalid JSON body" }, 400); }

  const action = body.action;

  if (action === "delete-me") {
    // Their bookings belong to the team, not to them (same rule as "remove"),
    // so they move to an admin rather than vanishing with the account.
    const { data: admins } = await admin
      .from("profiles").select("id").eq("role", "admin").neq("id", callerId).limit(1);
    const heir = admins?.[0]?.id;
    if (!heir) {
      return json({ ok: false, error: "You are the only admin. Make someone else an admin first." }, 400);
    }
    const { error: moveErr } = await admin
      .from("bookings").update({ booked_by: heir }).eq("booked_by", callerId);
    if (moveErr) return json({ ok: false, error: "Could not reassign your bookings: " + moveErr.message }, 500);
    await admin.from("app_settings").update({ locked_by: null }).eq("locked_by", callerId);
    const { error: delErr } = await admin.auth.admin.deleteUser(callerId);
    if (delErr) return json({ ok: false, error: delErr.message }, 400);
    return json({ ok: true });
  }

  if (action === "last-seen") {
    if (!isManager) return notManager();
    // auth.users.last_sign_in_at is maintained by Supabase itself, so there is
    // no column to add and nothing for a client to fake. It lives in the auth
    // schema, which only the service role can read - hence this detour.
    const { data, error } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    if (error) return json({ ok: false, error: error.message }, 400);
    const seen: Record<string, string | null> = {};
    for (const u of data.users) seen[u.id] = u.last_sign_in_at ?? null;
    return json({ ok: true, seen });
  }

  const userId = (body.userId || "").trim();
  if (!userId) return json({ ok: false, error: "userId is required" }, 400);
  // Acting on yourself is how you lock yourself out - except for naming
  // yourself, which is the one thing you should always be allowed to do.
  if (userId === callerId && action !== "set-name") {
    return json({ ok: false, error: "You can't do that to your own account" }, 403);
  }
  // A head coach's one power over other people: removing their own assistants.
  if (!isManager && userId !== callerId && !(isHeadCoach && action === "remove")) return notManager();

  const { data: target, error: targetErr } = await admin
    .from("profiles").select("id, email, role, gender, team_id").eq("id", userId).single();
  if (targetErr || !target) return json({ ok: false, error: "User not found" }, 404);

  // Authorize against the target, mirroring who may invite whom.
  if (userId === callerId) {
    // naming yourself: always allowed (the only self-action that gets here)
  } else if (isHeadCoach) {
    if (target.role !== "assistant" || target.team_id !== caller.team_id) {
      return json({ ok: false, error: "You can only remove your own team's assistant coaches" }, 403);
    }
  } else if (caller.role === "director") {
    if (target.role !== "coach" && target.role !== "assistant") {
      return json({ ok: false, error: "Directors can only manage coaches" }, 403);
    }
    if (target.gender !== caller.gender) {
      return json({ ok: false, error: `You can only manage ${caller.gender} coaches` }, 403);
    }
  } else if (!["coach", "director", "assistant"].includes(target.role)) {
    // Admins manage directors, coaches and assistants; other admins are off limits.
    return json({ ok: false, error: "Admins can't be managed here" }, 403);
  }

  // Written here rather than by a trigger: an account deleted through the
  // admin API has no signed-in user for a trigger to name.
  const logRemoval = (a: { email: string; team_id: string | null; gender: string | null }, note = "") =>
    admin.from("activity_log").insert({
      actor_id: callerId, actor_email: caller.email, action: "removed assistant",
      team_id: a.team_id, gender: a.gender, detail: a.email + note,
    });

  if (action === "reset-password") {
    const password = body.password;
    if (typeof password !== "string" || password.length < 8) {
      return json({ ok: false, error: "password must be at least 8 characters" }, 400);
    }
    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) return json({ ok: false, error: error.message }, 400);
    return json({ ok: true, email: target.email });
  }

  if (action === "set-name") {
    // Writing a name onto someone else's profile needs the service role, and
    // this function already establishes who the caller may act on. Routing it
    // here means invite-coach — whose source lives only in the dashboard — does
    // not have to change.
    const first = (body.firstName || "").trim();
    const last = (body.lastName || "").trim();
    if (!first && !last) return json({ ok: false, error: "A first or last name is required" }, 400);
    const { error } = await admin.from("profiles")
      .update({ first_name: first || null, last_name: last || null }).eq("id", userId);
    if (error) return json({ ok: false, error: error.message }, 400);
    return json({ ok: true, firstName: first, lastName: last });
  }

  if (action === "remove") {
    // A booking belongs to the TEAM, not to whoever happened to click Book.
    // bookings.booked_by is ON DELETE NO ACTION, so deleting the account
    // outright would fail — and cascading it would silently wipe the team's
    // season. Hand ownership to whoever is doing the removal instead.
    const { data: moved, error: moveErr } = await admin
      .from("bookings").update({ booked_by: callerId }).eq("booked_by", userId).select("id");
    if (moveErr) {
      return json({ ok: false, error: "Could not reassign their bookings: " + moveErr.message }, 500);
    }
    // app_settings.locked_by is also NO ACTION; clear it if it points at them.
    await admin.from("app_settings").update({ locked_by: null }).eq("locked_by", userId);

    // A head coach's assistants go with them: they were added on that coach's
    // say-so, and nobody else has vouched for them.
    let assistantsRemoved = 0;
    if (target.role === "coach") {
      const { data: theirs } = await admin.from("profiles")
        .select("id, email, team_id, gender").eq("role", "assistant").eq("invited_by", userId);
      for (const a of theirs || []) {
        const { error } = await admin.auth.admin.deleteUser(a.id);
        if (!error) { assistantsRemoved++; await logRemoval(a, " (with their head coach)"); }
      }
    }

    // profiles and waitlist rows cascade from auth.users.
    const { error: delErr } = await admin.auth.admin.deleteUser(userId);
    if (delErr) return json({ ok: false, error: delErr.message }, 400);
    if (target.role === "assistant") await logRemoval(target);

    return json({ ok: true, email: target.email, bookingsReassigned: (moved || []).length, assistantsRemoved });
  }

  return json({ ok: false, error: "Unknown action" }, 400);
});
