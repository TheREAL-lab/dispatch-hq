# Dispatch HQ — Go-Live Plan: Hiring 1099 Callers

## Context
You want this session to end with Dispatch HQ ready to **actively recruit, onboard, and pay 1099 commission-only reps** who call DFW self-storage facilities. The rep console, audition portal, Radar recruiting queue, commission views, and DOC 05 already exist and the sales-force migration is live. A read-only check of the code and the live Supabase project (`teptzyvzuenolwtfosht`) found the **funnel is built, but four things block hiring at scale**:

| Area | Live state (2026-11-01) | Why it blocks hiring |
|---|---|---|
| Lead supply | **88** facilities (ads and README claim "600+"); 86 uncalled; 75 already assigned (50 to the owner, 25 to the one rep) → **~13 open leads** | Each new rep gets "+ Deal 25 Leads". Right now there aren't enough leads to seat even one more rep. The ads also overstate the lead count. |
| Fulfillment | **0 active techs** (1 on file), 0 dispatches, 23 unvetted `tech_candidates` | Reps are paid only on *paid dispatches*. With no tech to send when a facility calls, reps earn $0 and quit. It also burns the facilities they signed up. |
| Data access | Reps (`employee`) can **SELECT/UPDATE every facility**, read the whole `outreach_log`, and **insert/update `techs`**. `outreach_log` has **no rep column** | One bad hire can export the entire lead list or edit other reps' leads and the tech roster. Nothing tracks per-rep calls or accountability. |
| Payouts | `rep_commissions` / `rep_vof_milestones` work out what's *owed*. Nothing records what's been *paid*. *(Correction: the view pays $40 + 20% on the first dispatch, which matches DOC 05 §3(2); the recruiting kit's wording and unit-economics table were what was wrong — fixed.)* | You can't run a payout or keep 1099 records. |

Other findings: an `e2e-test@example.com` test candidate is in `rep_candidates`. Security Advisor shows `rep_commissions` and `contractor_performance` are SECURITY DEFINER views, `dhq_*` functions can be called by `anon`, leaked-password protection is off, and the GraphQL schema exposes legacy tables (`posts`, `users`, `bids`…). `docs.html` says contracts are signed by "Taylor Keup d/b/a" until the LLC is filed.

---

## Phase 1 — Lock down data before outsiders get logins (code + migration) — ✅ DONE 2026-11-01
Shipped as `supabase/migrations/20261101_rep_hiring_readiness.sql` (applied live). Item 6 kept the existing commission math (it matches DOC 05). Leaked-password protection is still a dashboard toggle for the owner.

New migration `supabase/migrations/20261101_rep_hiring_readiness.sql`, applied through the Supabase MCP `apply_migration`:
1. **`outreach_log.rep_id uuid default auth.uid() references auth.users`**, plus a backfill (existing rows → owner). Index on `(rep_id, contacted_at)`.
2. **Facilities RLS, split by role.** Owner: unchanged. Employee: SELECT/UPDATE only where `assigned_to = auth.uid() OR closed_by = auth.uid()`. No visibility into the open pool (the owner deals leads). The existing `trg_facility_rep_attribution` attribution trigger stays as the second guard.
3. **outreach_log RLS.** Employee sees and inserts only rows where `rep_id = auth.uid()` and the facility is visible to them. Rows can't be updated after insert (audit trail).
4. **techs.** INSERT/UPDATE goes to owner only. Employees keep SELECT only if the console needs it (otherwise none).
5. **dispatches.** Set reps to `jobs_scope='assigned'` by default. Let reps SELECT dispatches on facilities they closed (so they can see what drives their commission).
6. **Commission correctness.** Recreate `rep_commissions` with `security_invoker = true` and an explicit `rep_id = auth.uid() OR dhq_is_owner()` filter. Set `trail_usd = 0` on the bounty row (match DOC 05).
7. **New `rep_payouts` table** (`rep_id, period, bounty_usd, trail_usd, vof_bonus_usd, total_usd, paid_on, method, reference, created_by`). Owner-only writes; each rep reads their own. Add a `rep_payout_balance` view (owed − paid) that drives "Pending vs Paid" in the console.
8. **New `rep_onboarding` columns on `dispatch_staff`:** `agreement_signed_at`, `w9_received_at`, `payout_method`, `phone`, `last_active_at`. Make `dealLeads` refuse until the agreement and W-9 are both on file.
9. Revoke `anon` EXECUTE on `dhq_*`. Turn on leaked-password protection (dashboard toggle, which you do).
10. Delete the `e2e-test@example.com` candidate.

**UI changes in `index.html`:**
- `logCall` (around line 599) writes `rep_id`. "My Calls Today" and the KPIs filter on `rep_id`.
- Team tab: a per-rep onboarding checklist (agreement / W-9 / payout method). `+ Deal 25 Leads` stays disabled until it's complete. Add calls/day and VOF counts per rep, plus a **Record Payout** action that writes `rep_payouts`.
- Rep view: a "Pending / Paid" panel that reads `rep_payout_balance`.
- `reclaimLeads` (line 730): use `last_active_at` / the last `outreach_log.rep_id` activity for the 72-hour rule.

## Phase 2 — Lead supply (needed before rep #2)
- Target **≥ 400 callable DFW facilities** in `facilities` so each of the first ~10 reps can get 25 leads, with refills after that.
- Extend `FacilityLeadSweeper` in `agents/recruiting_swarm.py` to bulk-import from a CSV the owner provides (Google Maps / SpareFoot / county list export). Dedupe on phone + address and skip chains via the existing `lead_chain_blocklist`. Pushing into `lead_candidates` → Radar "Promote to Facilities" stays the review gate.
- Add an `import-facilities --csv path` CLI command with a dry-run default.
- Until the count is real, change the ad copy and README from "600+" to an accurate number (in `recruiting_swarm.py`, `audition.html`, `README.md`, and the Radar ad kit).

## Phase 3 — Fulfillment bench (in parallel; needed before the first VOF facility calls in)
- Minimum before the first reps start calling: **2 active, DPS-licensed techs with a current COI** covering North DFW (Plano/Frisco/McKinney first). The owner vets them from the 23 `tech_candidates` using DOC 01 and DOC 04.
- A guard in the console: show a "no active techs" banner on the owner Command view and the rep view when `techs where is_active and coi_expires_on > now()` is empty.

## Phase 4 — Recruiting pipeline go-live (owner actions + small code)
1. Owner posts ads (`python3 agents/recruiting_swarm.py generate-ads`) on Craigslist DFW (Tue/Thu 8:30 AM CT), Reddit r/DFWJobs and r/sales, CommissionCrowd, and Indeed.
2. Candidate flow stays as it is: `audition.html` → `rep_candidates` → Radar playback → **Approve & Email DOC 05** → candidate signs up in `index.html` (role `pending`) → owner activates them as `employee`.
3. Code: in `audition.html`, add a required **acknowledgment checkbox** ("I understand this is 1099 commission-only, no base pay") and store it in `rep_candidates.capabilities` or a new `ack_1099_at` column. In Radar, link a `rep_candidates` row to its matching `dispatch_staff` signup by email so the owner sees "applied → signed up → activated" in one row.
4. **Wave plan:** Wave 1 = 3–5 reps, a 2-week trial, kill criteria (fewer than 30 logged calls/week or 0 VOF by day 10 → reclaim leads). Wave 2 starts only after Wave 1 produces ≥ 10 VOFs **and** at least one paid dispatch goes end to end.

## Phase 5 — Legal / compliance checklist (owner, offline; tracked in `RECRUITING_KIT.md`)
- File **Texas Gate Dispatch LLC** before signing DOC 05 with outside reps (`docs.html` already flags this). Get an EIN and a business bank account for payouts.
- A Texas attorney reviews DOC 05, including whether the **Texas telephone-solicitation registration (Bus. & Com. Code ch. 302)** applies or a business-to-business exemption covers you.
- **SMS rule:** reps text DOC 02 only after the manager verbally agrees on the call. Log this as an `outreach_log.channel='sms'` row. No cold texts.
- W-9 before first payout. 1099-NEC at year end (confirm the current reporting threshold with a CPA). Keep `rep_payouts` as the record.
- Reps use their own phone or a free Google Voice number at first. Defer a shared dialer (OpenPhone/Quo) until Wave 2.

## Phase 6 — Docs
Update `agents/RECRUITING_KIT.md` (onboarding gate, payout SOP, wave plan, compliance), `README.md` (accurate counts), and `CLAUDE.md` (new migration, `rep_payouts`, `outreach_log.rep_id`, RLS split).

---

## Critical files
- `supabase/migrations/20261101_rep_hiring_readiness.sql` (new)
- `index.html`: `logCall` (~599), `dealLeads` (~725), `reclaimLeads` (~730), Team tab render (~461–490), rep KPIs
- `radar.html`: Sales Reps tab (candidate ↔ staff link)
- `audition.html`: 1099 acknowledgment
- `agents/recruiting_swarm.py`: `import-facilities`, accurate ad counts
- `agents/RECRUITING_KIT.md`, `README.md`, `CLAUDE.md`

Reuse: the `dhq_is_owner/dhq_is_staff/dhq_can_close` helpers, the `trg_facility_rep_attribution` trigger, the `supabase_rest()` client in `recruiting_swarm.py`, and the existing Radar promote flow.

## Verification
1. `get_advisors(security)` after the migration: the SECURITY DEFINER view error on `rep_commissions` is gone, and anon can't call `dhq_*`.
2. RLS tests through `execute_sql` with `set local role authenticated; set local request.jwt.claims = '{"sub":"<rep uid>"}'`: the rep sees only their 25 facilities, can't update another rep's facility, can't touch `techs`, and sees only their own `outreach_log` and `rep_commissions`.
3. Commission math: insert a test facility closed by a test rep plus 2 approved and collected dispatches inside a transaction. Expect row 1 = $40 bounty / $0 trail and row 2 = $0 / $17.80. Then roll back.
4. End-to-end in a browser (Playwright, pre-installed): audition submit → Radar approve → signup → pending screen → owner activates → Deal 25 is blocked until the checklist is done → rep logs a call (KPI goes up, `rep_id` is set) → owner records a payout → the rep sees it as Paid.
5. `python3 agents/recruiting_swarm.py import-facilities --csv sample.csv` dry run shows the dedupe and skip counts.
6. Commit to `claude/dreamy-noether-7pim51` and push.

## Your decisions / actions (not code)
- Provide or approve a facility source list (CSV) to reach ~400 leads.
- Vet and activate at least 2 techs.
- Choose a payout method (Zelle / ACH / PayPal) and cadence (default: twice a month).
- LLC filing and attorney review before Wave 1 contracts are signed.
