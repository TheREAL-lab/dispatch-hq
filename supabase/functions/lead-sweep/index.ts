// lead-sweep — owner-only Google Maps sweep for DFW self-storage leads.
// Called from Radar (radar.html → Leads → Run Sweep) via supabase.functions.invoke.
// Requires the GOOGLE_MAPS_API_KEY Edge Function secret (Places API (New) enabled).
//
// Body: { cities?: string[], dry_run?: boolean, max_calls?: number }

import { createClient } from "jsr:@supabase/supabase-js@2";
import { nameCityKey, normPhone, processPlaces, resolveCities, searchCities } from "./sweep.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json(401, { error: "Sign in first." });

  // Every query runs as the caller, so RLS applies (lead_candidates / lead_sweeps are owner-only).
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await sb.auth.getUser(auth.slice(7));
  if (userErr || !userData?.user) return json(401, { error: "Session expired. Sign in again." });
  const { data: isOwner } = await sb.rpc("dhq_is_owner");
  if (!isOwner) return json(403, { error: "Only the owner can run a lead sweep." });

  // Edge Function secret first; otherwise the owner-only Vault secret `google_maps_api_key`.
  let apiKey = Deno.env.get("GOOGLE_MAPS_API_KEY") || "";
  if (!apiKey) {
    const { data: vaultKey } = await sb.rpc("dhq_google_maps_key");
    apiKey = typeof vaultKey === "string" ? vaultKey : "";
  }
  if (!apiKey) {
    return json(412, {
      error: "Google Maps key not set. Add GOOGLE_MAPS_API_KEY under Supabase → Edge Functions → Secrets, or store it in Vault as google_maps_api_key.",
      code: "key_not_set",
    });
  }

  let body: { cities?: string[]; dry_run?: boolean; max_calls?: number } = {};
  try { body = await req.json(); } catch { /* empty body = full sweep */ }
  let cities;
  try { cities = resolveCities(body.cities); } catch (e) { return json(400, { error: (e as Error).message }); }
  const dryRun = !!body.dry_run;
  const maxCalls = Math.max(1, Math.min(300, Math.floor(body.max_calls ?? 150)));

  const { data: logRow } = await sb.from("lead_sweeps")
    .insert({ cities: cities.map((c) => c.name), dry_run: dryRun }).select("id").single();
  const finish = async (patch: Record<string, unknown>) => {
    if (logRow?.id) await sb.from("lead_sweeps").update({ ...patch, finished_at: new Date().toISOString() }).eq("id", logRow.id);
  };

  try {
    const [bl, lc, fac] = await Promise.all([
      sb.from("lead_chain_blocklist").select("pattern"),
      sb.from("lead_candidates").select("place_id"),
      sb.from("facilities").select("place_id, phone, name, city"),
    ]);
    for (const r of [bl, lc, fac]) if (r.error) throw new Error(r.error.message);
    const existing = {
      placeIds: new Set<string>([...(lc.data || []), ...(fac.data || [])].map((r: any) => r.place_id).filter(Boolean)),
      phones: new Set<string>((fac.data || []).map((r: any) => normPhone(r.phone)).filter(Boolean)),
      nameCity: new Set<string>((fac.data || []).map((r: any) => nameCityKey(r.name, r.city))),
    };

    const search = await searchCities({ apiKey, cities, maxCalls, fetchFn: fetch as any });
    const { candidates, skipped, found } = processPlaces(search.places, (bl.data || []).map((r: any) => r.pattern), existing);

    let inserted = 0;
    if (!dryRun && candidates.length) {
      const { data, error } = await sb.from("lead_candidates")
        .upsert(candidates.map((c) => ({ ...c, swept_at: new Date().toISOString() })), { onConflict: "place_id", ignoreDuplicates: true })
        .select("id");
      if (error) throw new Error(error.message);
      inserted = data?.length || 0;
    }

    const summary = {
      dry_run: dryRun,
      cities: cities.length,
      api_calls: search.apiCalls,
      hit_call_cap: search.apiCalls >= maxCalls,
      found,
      new_candidates: candidates.length,
      inserted,
      skipped_chain: skipped.chain,
      skipped_duplicate: skipped.duplicate,
      skipped_closed: skipped.closed,
      skipped_not_storage: skipped.not_storage,
      with_gate_pain: candidates.filter((c) => c.pain_signal).length,
      top: candidates.slice(0, 5).map((c) => ({ name: c.name, city: c.city, score: c.score, pain_recent: c.pain_recent })),
      errors: search.errors,
    };
    await finish({
      api_calls: search.apiCalls, found, inserted,
      skipped_chain: skipped.chain, skipped_duplicate: skipped.duplicate, skipped_closed: skipped.closed,
      error: search.errors.length ? search.errors.join("\n").slice(0, 2000) : null,
    });
    // A rejected key / billing problem stops the sweep on the first call: surface it as an error.
    if (search.errors.length && search.apiCalls <= 1 && !search.places.length) {
      return json(502, { error: "Google rejected the request: " + search.errors[0], summary });
    }
    return json(200, summary);
  } catch (e) {
    await finish({ error: (e as Error).message.slice(0, 2000) });
    return json(500, { error: (e as Error).message });
  }
});
