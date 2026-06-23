// ================================================================
//  FIT HOUSE — Supabase Edge Function: invite-user
//  Ruta: supabase/functions/invite-user/index.ts
//
//  Propósito: Enviar invitación de Supabase Auth al nuevo atleta.
//  La SERVICE_ROLE KEY nunca sale al frontend — vive aquí de forma segura.
//
//  Deploy: supabase functions deploy invite-user
//  (requiere Supabase CLI instalado: https://supabase.com/docs/guides/cli)
// ================================================================

import { serve }        from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Headers CORS (ajusta el origin a tu dominio en producción)
const CORS_HEADERS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {

  // Pre-flight CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    const { nombre, correo } = await req.json();

    if (!nombre || !correo) {
      return new Response(
        JSON.stringify({ error: "Nombre y correo son obligatorios." }),
        { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }

    // ── Cliente admin (usa SERVICE_ROLE KEY — nunca al frontend) ──
    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    // ── Verificar que el caller sea admin ──────────────────────────
    // El token JWT del usuario que llamó la función viene en Authorization.
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Token de autorización faltante." }),
        { status: 401, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }

    const { data: { user: caller }, error: authErr } = await adminClient.auth.getUser(
      authHeader.replace("Bearer ", "")
    );

    if (authErr || !caller) {
      return new Response(
        JSON.stringify({ error: "Sesión inválida." }),
        { status: 401, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }

    // Verificar rol en la tabla
    const { data: callerProfile } = await adminClient
      .from("miembros_gym")
      .select("rol")
      .eq("id", caller.id)
      .single();

    if (callerProfile?.rol !== "admin") {
      return new Response(
        JSON.stringify({ error: "No tienes permisos para invitar atletas." }),
        { status: 403, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }

    // ── Enviar invitación via Supabase Auth ──────────────────────
    // Supabase envía el email automáticamente usando la plantilla
    // "Invite user" configurada en Authentication → Email Templates.
    // El campo `data` se pasa al trigger `handle_new_user` como
    // raw_user_meta_data para pre-poblar el nombre en miembros_gym.

    const { data: inviteData, error: inviteErr } = await adminClient.auth.admin.inviteUserByEmail(
      correo,
      {
        data: { nombre },                                   // metadata → trigger
        redirectTo: `${Deno.env.get("SITE_URL")}/pages/app.html`  // post-confirm redirect
      }
    );

    if (inviteErr) {
      return new Response(
        JSON.stringify({ error: inviteErr.message }),
        { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ ok: true, userId: inviteData.user?.id }),
      { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
    );

  } catch (err) {
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
    );
  }
});
