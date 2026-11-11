// lead-sweep — owner-only Google Maps sweep for DFW self-storage leads.
// Called from Radar (radar.html → Leads → Run Sweep) via supabase.functions.invoke.
// Google key: the GOOGLE_MAPS_API_KEY Edge Function secret, or the Vault secret
// `google_maps_api_key` read with the service role (never exposed to the browser).
//
// Body: { cities?: string[], dry_run?: boolean, max_calls?: number }

import { createClient } from "jsr:@supabase/supabase-js@2";
import { clampMaxCalls, fetchAllRows, monthlyBudget, nameCityKey, normPhone, processPlaces, resolveCities, searchCities } from "./sweep.ts";

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

  // Edge Function secret first; otherwise the Vault secret `google_maps_api_key`. The caller is a
  // verified owner at this point; the key itself is only readable with the service role.
  let apiKey = Deno.env.get("GOOGLE_MAPS_API_KEY") || "";
  if (!apiKey) {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: vaultKey } = await admin.rpc("dhq_google_maps_key");
    apiKey = typeof vaultKey === "string" ? vaultKey : "";
  }
  if (!apiKey) {
    return json(412, {
      error: "Google Maps key not set. Add GOOGLE_MAPS_API_KEY under Supabase → Edge Functions → Secrets, or store it in Vault as google_maps_api_key.",
      code: "key_not_set",
    });
  }

  let body: { cities?: string[]; dry_run?: boolean; max_calls?: number } = {};
  try { body = (await req.json()) ?? {}; } catch { /* empty body = full sweep */ }
  if (typeof body !== "object" || Array.isArray(body)) return json(400, { error: "Body must be a JSON object." });
  let cities;
  try { cities = resolveCities(body.cities); } catch (e) { return json(400, { error: (e as Error).message }); }
  const dryRun = !!body.dry_run;

  // Spend guards: one sweep at a time, and a monthly cap on Google calls
  // (app_settings.sweep_monthly_call_cap, default 1000; dry runs count too).
  const monthStart = new Date(); monthStart.setUTCDate(1); monthStart.setUTCHours(0, 0, 0, 0);
  const [running, month, capRow] = await Promise.all([
    sb.from("lead_sweeps").select("id").is("finished_at", null).gte("started_at", new Date(Date.now() - 5 * 60_000).toISOString()).limit(1),
    sb.from("lead_sweeps").select("api_calls").gte("started_at", monthStart.toISOString()),
    sb.from("app_settings").select("value").eq("key", "sweep_monthly_call_cap").maybeSingle(),
  ]);
  if (running.error || month.error) return json(500, { error: (running.error || month.error)!.message });
  if (running.data?.length) return json(409, { error: "A sweep is already running. Wait for it to finish, then try again." });
  const usedThisMonth = (month.data || []).reduce((n: number, r: any) => n + (r.api_calls || 0), 0);
  const budget = monthlyBudget(clampMaxCalls(body.max_calls), usedThisMonth, capRow.data?.value);
  if (budget.allowed < 1) {
    return json(429, { error: `Monthly Google call cap reached (${budget.used} of ${budget.monthlyCap}). Raise it in Settings or wait until next month.`, code: "monthly_cap" });
  }
  const maxCalls = budget.allowed;

  const { data: logRow } = await sb.from("lead_sweeps")
    .insert({ cities: cities.map((c) => c.name), dry_run: dryRun }).select("id").single();
  const finish = async (patch: Record<string, unknown>) => {
    if (logRow?.id) await sb.from("lead_sweeps").update({ ...patch, finished_at: new Date().toISOString() }).eq("id", logRow.id);
  };

  try {
    // Paged, so dedupe stays correct past PostgREST's 1000-row page size.
    const [bl, lc, fac] = await Promise.all([
      fetchAllRows<any>((a, b) => sb.from("lead_chain_blocklist").select("pattern").order("id").range(a, b)),
      fetchAllRows<any>((a, b) => sb.from("lead_candidates").select("place_id").order("id").range(a, b)),
      fetchAllRows<any>((a, b) => sb.from("facilities").select("place_id, phone, name, city").order("id").range(a, b)),
    ]);
    const existing = {
      placeIds: new Set<string>([...lc, ...fac].map((r: any) => r.place_id).filter(Boolean)),
      phones: new Set<string>(fac.map((r: any) => normPhone(r.phone)).filter(Boolean)),
      nameCity: new Set<string>(fac.map((r: any) => nameCityKey(r.name, r.city))),
    };

    const search = await searchCities({ apiKey, cities, maxCalls, fetchFn: fetch as any });
    const { candidates, skipped, found } = processPlaces(search.places, bl.map((r: any) => r.pattern), existing);

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
      monthly_calls_used: budget.used + search.apiCalls,
      monthly_call_cap: budget.monthlyCap,
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
