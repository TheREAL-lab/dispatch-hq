// Pure lead-sweep logic: Google Places search, filtering, dedupe and scoring.
// No Deno- or Supabase-specific imports, so it can be unit-tested under Node.

export type City = { name: string; lat: number; lng: number };

// North DFW first. Coordinates are city centers used for the search location bias.
export const DEFAULT_CITIES: City[] = [
  { name: "Plano", lat: 33.0198, lng: -96.6989 },
  { name: "Frisco", lat: 33.1507, lng: -96.8236 },
  { name: "McKinney", lat: 33.1972, lng: -96.6398 },
  { name: "Allen", lat: 33.1032, lng: -96.6706 },
  { name: "Prosper", lat: 33.2362, lng: -96.8011 },
  { name: "Celina", lat: 33.3246, lng: -96.7844 },
  { name: "Little Elm", lat: 33.1626, lng: -96.9375 },
  { name: "The Colony", lat: 33.089, lng: -96.8864 },
  { name: "Carrollton", lat: 32.9756, lng: -96.89 },
  { name: "Lewisville", lat: 33.0462, lng: -96.9942 },
  { name: "Flower Mound", lat: 33.0146, lng: -97.097 },
  { name: "Denton", lat: 33.2148, lng: -97.1331 },
  { name: "Wylie", lat: 33.0151, lng: -96.5389 },
  { name: "Murphy", lat: 33.0151, lng: -96.6131 },
  { name: "Sachse", lat: 32.9762, lng: -96.5953 },
  { name: "Garland", lat: 32.9126, lng: -96.6389 },
  { name: "Richardson", lat: 32.9483, lng: -96.7299 },
  { name: "Rowlett", lat: 32.9029, lng: -96.5639 },
  { name: "Rockwall", lat: 32.9312, lng: -96.4597 },
  { name: "Mesquite", lat: 32.7668, lng: -96.5992 },
  { name: "Dallas", lat: 32.7767, lng: -96.797 },
  { name: "Addison", lat: 32.9618, lng: -96.8292 },
  { name: "Irving", lat: 32.814, lng: -96.9489 },
  { name: "Grand Prairie", lat: 32.746, lng: -96.9978 },
  { name: "Arlington", lat: 32.7357, lng: -97.1081 },
  { name: "Fort Worth", lat: 32.7555, lng: -97.3308 },
  { name: "Keller", lat: 32.9346, lng: -97.2517 },
  { name: "Southlake", lat: 32.9412, lng: -97.1342 },
  { name: "Mansfield", lat: 32.5632, lng: -97.1417 },
  { name: "Princeton", lat: 33.1801, lng: -96.4983 },
  { name: "Anna", lat: 33.349, lng: -96.5486 },
  { name: "Melissa", lat: 33.2859, lng: -96.5728 },
  { name: "Forney", lat: 32.7482, lng: -96.4719 },
  { name: "Waxahachie", lat: 32.3866, lng: -96.8483 },
  { name: "Weatherford", lat: 32.7593, lng: -97.7973 },
  { name: "Sherman", lat: 33.6357, lng: -96.6089 },
];

const PLANO = { lat: 33.0198, lng: -96.6989 };
const MAX_PAGES_PER_CITY = 3;
const SEARCH_RADIUS_M = 12000;
const RECENT_DAYS = 365;

export const FIELD_MASK = [
  "places.id",
  "places.displayName",
  "places.formattedAddress",
  "places.addressComponents",
  "places.nationalPhoneNumber",
  "places.websiteUri",
  "places.location",
  "places.rating",
  "places.userRatingCount",
  "places.businessStatus",
  "places.types",
  "places.reviews",
  "nextPageToken",
].join(",");

// Gate / access-control pain phrases (superset of PAIN_PATTERNS in agents/recruiting_swarm.py).
export const PAIN_PATTERNS: RegExp[] = [
  /gate\s+(?:has\s+been\s+|is\s+|was\s+|keeps?\s+|kept\s+)?(?:broken|broke|stuck|open|down|not\s+(?:working|opening|closing)|malfunction\w*|out\s+of\s+order)\b/i,
  /(?:broken|stuck|faulty|malfunctioning)\s+(?:security\s+|front\s+|entry\s+|exit\s+|main\s+)?gate/i,
  /(?:keypad|key\s*pad|gate\s+code|access\s+code|code\s+box)\s+(?:is\s+|was\s+)?(?:broken|dead|not\s+working|didn'?t\s+work|wouldn'?t\s+work|out|blank)\b/i,
  /(?:locked|trapped|stuck)\s+(?:in|inside|out|outside)\b/i,
  /couldn'?t\s+(?:get|drive)\s+(?:in|out|through\s+the\s+gate)/i,
  /(?:gate\s+)?(?:opener|operator|motor|arm|sensor|photo[\s-]?eye|remote)\s+(?:is\s+|was\s+)?(?:broken|not\s+working|out|dead|stuck)\b/i,
  /chain\s+(?:off|broke|broken|came\s+off)|hit\s+the\s+gate/i,
  /security\s+gate\s+(?:has\s+been\s+|is\s+|was\s+)?(?:open|down)\s+for\s+(?:days|weeks|months)/i,
];

export type PlaceReview = { text?: { text?: string }; originalText?: { text?: string }; rating?: number; publishTime?: string };
export type Place = {
  id: string;
  displayName?: { text?: string };
  formattedAddress?: string;
  addressComponents?: { longText?: string; shortText?: string; types?: string[] }[];
  nationalPhoneNumber?: string;
  websiteUri?: string;
  location?: { latitude: number; longitude: number };
  rating?: number;
  userRatingCount?: number;
  businessStatus?: string;
  types?: string[];
  reviews?: PlaceReview[];
};

export type Existing = {
  placeIds: Set<string>;
  phones: Set<string>;
  nameCity: Set<string>;
};

export type Candidate = {
  place_id: string;
  name: string;
  address: string | null;
  city: string | null;
  phone: string | null;
  website: string | null;
  lat: number | null;
  lng: number | null;
  rating: number | null;
  review_count: number | null;
  business_status: string | null;
  pain_signal: boolean;
  pain_recent: boolean;
  pain_evidence: { snippet: string; rating: number | null; published: string | null }[];
  score: number;
  score_breakdown: Record<string, number | string>;
  status: "new";
};

export type Skips = { chain: number; duplicate: number; closed: number; not_storage: number };

export const normPhone = (p?: string | null) => {
  const d = (p || "").replace(/\D/g, "");
  return d.length >= 10 ? d.slice(-10) : "";
};
export const normName = (s?: string | null) => (s || "").toLowerCase().replace(/[^a-z0-9]/g, "");
export const nameCityKey = (name?: string | null, city?: string | null) => normName(name) + "|" + normName(city);

export function milesBetween(a: { lat: number; lng: number }, b: { lat: number; lng: number }) {
  const R = 3958.8, rad = (x: number) => (x * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export function cityOf(p: Place): string | null {
  const c = (p.addressComponents || []).find((x) => (x.types || []).includes("locality"));
  return c?.longText || c?.shortText || null;
}

export function isChain(name: string, patterns: string[]) {
  const n = name.toLowerCase();
  const compact = n.replace(/[^a-z0-9]/g, "");
  return patterns.some((p) => {
    const pl = p.toLowerCase().trim();
    return pl && (n.includes(pl) || compact.includes(pl.replace(/[^a-z0-9]/g, "")));
  });
}

export function isStorage(p: Place) {
  return (p.types || []).includes("storage") || /stor|mini\s*warehouse|boat\s*&?\s*rv|rv\s*&?\s*boat/i.test(p.displayName?.text || "");
}

const CITY_WORDS = new Set(DEFAULT_CITIES.flatMap((c) => c.name.toLowerCase().split(" ")).concat(["tx", "texas", "dfw"]));
const DIRECTION_WORDS = new Set(["north", "south", "east", "west", "central", "downtown"]);

// Brand key used to count how many sites one operator runs, e.g.
// "Securlock Storage at Allen East" and "Securlock Storage - The Colony" -> "securlock storage".
export function brandKey(name: string) {
  let n = name.toLowerCase().split(/\s+(?:-|–|\||@|at)\s+/)[0];
  n = n.replace(/[^a-z0-9& ]/g, " ");
  const words = n.split(/\s+/).filter((w) => w && !CITY_WORDS.has(w) && !DIRECTION_WORDS.has(w) && !/^\d+$/.test(w) && w !== "of");
  return words.join(" ");
}

export function findPain(reviews: PlaceReview[] | undefined, now: Date) {
  let best: { snippet: string; rating: number | null; published: string | null; recent: boolean } | null = null;
  for (const r of reviews || []) {
    const text = r.text?.text || r.originalText?.text || "";
    for (const re of PAIN_PATTERNS) {
      const m = text.match(re);
      if (!m || m.index === undefined) continue;
      const published = r.publishTime || null;
      const recent = !!published && (now.getTime() - new Date(published).getTime()) / 864e5 <= RECENT_DAYS;
      const start = Math.max(0, m.index - 120);
      let snippet = text.slice(start, start + 300).replace(/\s+/g, " ").trim();
      if (start > 0) snippet = "…" + snippet;
      if (start + 300 < text.length) snippet += "…";
      const hit = { snippet, rating: r.rating ?? null, published, recent };
      if (!best || (recent && !best.recent)) best = hit;
      break;
    }
    if (best?.recent) break;
  }
  return best;
}

export function scorePlace(p: Place, brandSites: number, now: Date): Candidate {
  const bd: Record<string, number | string> = {};
  let score = 0;
  const add = (k: string, v: number) => { bd[k] = v; score += v; };

  const pain = findPain(p.reviews, now);
  if (pain?.recent) add("pain", 35);
  else if (pain) add("pain", 20);
  else add("pain", 0);

  add("independent", 20);
  if (brandSites >= 3) { add("regional_operator", 10); bd.brand_sites = brandSites; }
  else add("small_operator", 15);
  if (p.nationalPhoneNumber) add("callable", 10);
  if (!p.websiteUri) add("low_tech", 10);
  if (p.location) {
    const mi = milesBetween(PLANO, { lat: p.location.latitude, lng: p.location.longitude });
    bd.distance_mi = Math.round(mi * 10) / 10;
    if (mi <= 15) add("proximity", 10);
    else if (mi <= 30) add("proximity", 5);
  }

  return {
    place_id: p.id,
    name: p.displayName?.text || "Unnamed facility",
    address: p.formattedAddress || null,
    city: cityOf(p),
    phone: p.nationalPhoneNumber || null,
    website: p.websiteUri || null,
    lat: p.location?.latitude ?? null,
    lng: p.location?.longitude ?? null,
    rating: p.rating ?? null,
    review_count: p.userRatingCount ?? null,
    business_status: p.businessStatus || null,
    pain_signal: !!pain,
    pain_recent: !!pain?.recent,
    pain_evidence: pain ? [{ snippet: pain.snippet, rating: pain.rating, published: pain.published }] : [],
    score: Math.min(99, score),
    score_breakdown: bd,
    status: "new",
  };
}

// Filters, dedupes and scores raw Places results.
export function processPlaces(places: Place[], blocklist: string[], existing: Existing, now = new Date()) {
  const skipped: Skips = { chain: 0, duplicate: 0, closed: 0, not_storage: 0 };
  const seen = new Set<string>();
  const usable: Place[] = [];
  for (const p of places) {
    if (!p?.id || seen.has(p.id)) continue; // same place returned by neighbouring city searches
    seen.add(p.id);
    const name = p.displayName?.text || "";
    if (p.businessStatus && p.businessStatus !== "OPERATIONAL") { skipped.closed++; continue; }
    if (!isStorage(p)) { skipped.not_storage++; continue; }
    if (isChain(name, blocklist)) { skipped.chain++; continue; }
    usable.push(p);
  }
  // Brand site counts include facilities we already have, so a regional operator is still recognised.
  const brandCounts = new Map<string, number>();
  for (const p of usable) {
    const k = brandKey(p.displayName?.text || "");
    if (k) brandCounts.set(k, (brandCounts.get(k) || 0) + 1);
  }
  const candidates: Candidate[] = [];
  for (const p of usable) {
    const phone = normPhone(p.nationalPhoneNumber);
    if (existing.placeIds.has(p.id) || (phone && existing.phones.has(phone)) ||
        existing.nameCity.has(nameCityKey(p.displayName?.text, cityOf(p)))) {
      skipped.duplicate++;
      continue;
    }
    const sites = brandCounts.get(brandKey(p.displayName?.text || "")) || 1;
    candidates.push(scorePlace(p, sites, now));
  }
  candidates.sort((a, b) => b.score - a.score);
  return { candidates, skipped, found: seen.size };
}

type FetchFn = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{ ok: boolean; status: number; json(): Promise<any>; text(): Promise<string> }>;

// Runs Places Text Search for each city (up to 3 pages each), never exceeding maxCalls.
export async function searchCities(opts: { apiKey: string; cities: City[]; maxCalls: number; fetchFn: FetchFn; concurrency?: number }) {
  const places: Place[] = [];
  const errors: string[] = [];
  let calls = 0;
  const queue = opts.cities.slice();
  const worker = async () => {
    while (queue.length) {
      const city = queue.shift()!;
      let pageToken: string | undefined;
      for (let page = 0; page < MAX_PAGES_PER_CITY; page++) {
        if (calls >= opts.maxCalls) return;
        calls++;
        const body: Record<string, unknown> = {
          textQuery: `self storage in ${city.name}, TX`,
          pageSize: 20,
          locationBias: { circle: { center: { latitude: city.lat, longitude: city.lng }, radius: SEARCH_RADIUS_M } },
        };
        if (pageToken) body.pageToken = pageToken;
        const res = await opts.fetchFn("https://places.googleapis.com/v1/places:searchText", {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Goog-Api-Key": opts.apiKey, "X-Goog-FieldMask": FIELD_MASK },
          body: JSON.stringify(body),
        });
        if (!res.ok) {
          const t = await res.text();
          errors.push(`${city.name}: HTTP ${res.status} ${t.slice(0, 200)}`);
          if (res.status === 400 || res.status === 401 || res.status === 403) { queue.length = 0; return; } // bad key/billing: stop everything
          break;
        }
        const data = await res.json();
        places.push(...(data.places || []));
        pageToken = data.nextPageToken;
        if (!pageToken) break;
      }
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, opts.concurrency ?? 6) }, worker));
  return { places, apiCalls: calls, errors };
}

// Clamps the caller-supplied call budget to 1..300. Anything that is not a finite number
// (missing, "abc", null) falls back to the default instead of becoming NaN, which would
// make every `calls >= maxCalls` check false and disable the cap.
export function clampMaxCalls(v: unknown, dflt = 150, max = 300): number {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() ? Number(v) : NaN;
  return Math.max(1, Math.min(max, Math.floor(Number.isFinite(n) ? n : dflt)));
}

// How many Google calls this run may make, given what has already been spent this month.
// A missing or invalid cap falls back to the default; 0 remaining means "do not run".
export const DEFAULT_MONTHLY_CALL_CAP = 1000;
export function monthlyBudget(requested: number, usedThisMonth: number, cap: unknown) {
  const c = typeof cap === "string" && cap.trim() ? Number(cap) : typeof cap === "number" ? cap : NaN;
  const monthlyCap = Number.isFinite(c) && c >= 0 ? Math.floor(c) : DEFAULT_MONTHLY_CALL_CAP;
  const used = Number.isFinite(usedThisMonth) && usedThisMonth > 0 ? Math.floor(usedThisMonth) : 0;
  const remaining = Math.max(0, monthlyCap - used);
  return { monthlyCap, used, remaining, allowed: Math.min(requested, remaining) };
}

// PostgREST returns at most 1000 rows per request; page through until a short page.
export async function fetchAllRows<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>, size = 1000): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += size) {
    const { data, error } = await page(from, from + size - 1);
    if (error) throw new Error(error.message);
    out.push(...(data || []));
    if (!data || data.length < size) return out;
  }
}

export function resolveCities(names?: unknown): City[] {
  if (names === undefined || names === null) return DEFAULT_CITIES;
  if (!Array.isArray(names) || names.some((n) => typeof n !== "string")) throw new Error("cities must be a list of city names");
  if (!names.length) return DEFAULT_CITIES;
  return (names as string[]).map((n) => {
    const hit = DEFAULT_CITIES.find((c) => c.name.toLowerCase() === n.trim().toLowerCase());
    if (!hit) throw new Error(`Unknown city "${n}". Known: ${DEFAULT_CITIES.map((c) => c.name).join(", ")}`);
    return hit;
  });
}
