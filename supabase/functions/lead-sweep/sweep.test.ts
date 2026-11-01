// Run: node --test supabase/functions/lead-sweep/sweep.test.ts   (Node 22.18+)
import { test } from "node:test";
import assert from "node:assert/strict";
import { brandKey, findPain, processPlaces, resolveCities, searchCities, type Place } from "./sweep.ts";

const NOW = new Date("2026-11-01T12:00:00Z");
const daysAgo = (d: number) => new Date(NOW.getTime() - d * 864e5).toISOString();
const place = (id: string, name: string, extra: Partial<Place> = {}): Place => ({
  id,
  displayName: { text: name },
  formattedAddress: "1 Main St",
  addressComponents: [{ longText: "Plano", types: ["locality"] }],
  nationalPhoneNumber: "(972) 555-01" + id.padStart(2, "0").slice(-2),
  location: { latitude: 33.02, longitude: -96.7 },
  businessStatus: "OPERATIONAL",
  types: ["storage"],
  reviews: [],
  ...extra,
});
const noExisting = { placeIds: new Set<string>(), phones: new Set<string>(), nameCity: new Set<string>() };

test("drops blocklisted chains, closed and non-storage places", () => {
  const r = processPlaces([
    place("1", "Public Storage"),
    place("2", "U-Haul Moving & Storage of Plano"),
    place("3", "Closed Storage", { businessStatus: "CLOSED_PERMANENTLY" }),
    place("4", "Two Men and a Truck", { types: ["moving_company"] }),
    place("5", "Mom & Pop Storage"),
  ], ["public storage", "uhaul"], noExisting, NOW);
  assert.deepEqual(r.skipped, { chain: 2, duplicate: 0, closed: 1, not_storage: 1 });
  assert.deepEqual(r.candidates.map((c) => c.name), ["Mom & Pop Storage"]);
});

test("dedupes by place id, phone, and name+city, and across city searches", () => {
  const existing = {
    placeIds: new Set(["a"]),
    phones: new Set(["9725550111"]),
    nameCity: new Set(["oldstorage|plano"]),
  };
  const r = processPlaces([
    place("a", "Already Swept Storage"),
    place("b", "Phone Match Storage", { nationalPhoneNumber: "+1 972-555-0111" }),
    place("c", "Old Storage"),
    place("d", "Brand New Storage"),
    place("d", "Brand New Storage"),
  ], [], existing, NOW);
  assert.equal(r.skipped.duplicate, 3);
  assert.equal(r.found, 4);
  assert.deepEqual(r.candidates.map((c) => c.place_id), ["d"]);
});

test("recent gate-pain review scores higher than an old one; evidence is captured", () => {
  const r = processPlaces([
    place("1", "Recent Pain Storage", { reviews: [{ text: { text: "Nice staff. The gate was stuck open all weekend and the keypad is dead." }, rating: 2, publishTime: daysAgo(40) }] }),
    place("2", "Old Pain Storage", { reviews: [{ text: { text: "Got locked in after hours once." }, rating: 3, publishTime: daysAgo(900) }] }),
    place("3", "No Pain Storage", { reviews: [{ text: { text: "Clean units, friendly manager." }, rating: 5, publishTime: daysAgo(10) }] }),
  ], [], noExisting, NOW);
  const by = Object.fromEntries(r.candidates.map((c) => [c.name, c]));
  assert.equal(by["Recent Pain Storage"].pain_recent, true);
  assert.equal(by["Recent Pain Storage"].score_breakdown.pain, 35);
  assert.match(by["Recent Pain Storage"].pain_evidence[0].snippet, /gate was stuck open/);
  assert.equal(by["Old Pain Storage"].pain_recent, false);
  assert.equal(by["Old Pain Storage"].pain_signal, true);
  assert.equal(by["Old Pain Storage"].score_breakdown.pain, 20);
  assert.equal(by["No Pain Storage"].pain_signal, false);
  assert.ok(by["Recent Pain Storage"].score > by["Old Pain Storage"].score);
  assert.ok(by["Old Pain Storage"].score > by["No Pain Storage"].score);
  assert.equal(r.candidates[0].name, "Recent Pain Storage");
});

test("full score: independent + small operator + callable + low tech + proximity", () => {
  const r = processPlaces([place("1", "Corner Storage")], [], noExisting, NOW);
  assert.equal(r.candidates[0].score, 20 + 15 + 10 + 10 + 10);
  assert.equal(r.candidates[0].score_breakdown.distance_mi, 0.1);
});

test("a brand at 3+ sites is tagged as a regional operator", () => {
  const r = processPlaces([
    place("1", "Securlock Storage at Allen East"),
    place("2", "Securlock Storage - The Colony"),
    place("3", "Securlock Storage Plano"),
    place("4", "Solo Storage"),
  ], [], noExisting, NOW);
  const sec = r.candidates.filter((c) => c.name.startsWith("Securlock"));
  assert.equal(sec.length, 3);
  for (const c of sec) {
    assert.equal(c.score_breakdown.regional_operator, 10);
    assert.equal(c.score_breakdown.brand_sites, 3);
  }
  assert.equal(r.candidates.find((c) => c.name === "Solo Storage")!.score_breakdown.small_operator, 15);
  assert.equal(brandKey("Securlock Storage at Allen East"), "securlock storage");
});

test("pain patterns ignore unrelated mentions", () => {
  assert.equal(findPain([{ text: { text: "Gate code was easy to use and the gate opens fast." }, publishTime: daysAgo(5) }], NOW), null);
  assert.ok(findPain([{ text: { text: "The access code didn't work so we were locked out for an hour." }, publishTime: daysAgo(5) }], NOW));
});

test("search pages up to 3 per city and never exceeds max_calls", async () => {
  let calls = 0;
  const fetchFn = async (_url: string, init: { body: string }) => {
    calls++;
    const b = JSON.parse(init.body);
    const page = b.pageToken ? Number(b.pageToken) : 0;
    return {
      ok: true, status: 200, text: async () => "",
      json: async () => ({ places: [place(`${b.textQuery}-${page}`, "X Storage")], nextPageToken: String(page + 1) }),
    };
  };
  const all = await searchCities({ apiKey: "k", cities: resolveCities(["Plano", "Frisco"]), maxCalls: 100, fetchFn: fetchFn as any });
  assert.equal(all.apiCalls, 6);
  assert.equal(calls, 6);
  calls = 0;
  const capped = await searchCities({ apiKey: "k", cities: resolveCities(), maxCalls: 10, fetchFn: fetchFn as any });
  assert.equal(capped.apiCalls, 10);
  assert.equal(calls, 10);
});

test("a rejected key stops the whole sweep after the first failure", async () => {
  let calls = 0;
  const fetchFn = async () => { calls++; return { ok: false, status: 403, text: async () => "API key not valid", json: async () => ({}) }; };
  const r = await searchCities({ apiKey: "bad", cities: resolveCities(), maxCalls: 150, fetchFn: fetchFn as any, concurrency: 1 });
  assert.equal(calls, 1);
  assert.match(r.errors[0], /403/);
});

test("unknown city names are rejected with the known list", () => {
  assert.throws(() => resolveCities(["Atlantis"]), /Unknown city "Atlantis"/);
});
