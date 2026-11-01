# Texas Gate Dispatch — 1099 Sales Force & Recruiting Swarm Playbook

This playbook governs how **Texas Gate Dispatch (Dispatch HQ)** recruits, auditions, onboards, and pays independent **1099 commission-only B2B sales representatives** calling DFW self-storage facilities.

---

## 1. Unit Economics & Why Commission Reps Stay

The #1 killer of commission-only outbound teams is asking reps to cold-call a high-friction offer where they wait 45 days for their first dollar. Our model eliminates both bottlenecks:

1. **Zero-Friction Pitch (`$0` Upfront to the Storage Facility):**
   - Reps are **not** selling a monthly retainer or software contract.
   - They ask the storage manager to list **Texas Gate Dispatch** as their free backup **Vendor-on-File (`DOC 02`)** for when their primary gate vendor is backed up 4+ days.
2. **Two-Tier Dispatch Coordination Fees (How Texas Gate Dispatch Gets Paid):**
   - **Standard Next-Day Dispatch:** `\$89.00` flat coordination fee.
   - **Same-Day Emergency / After-Hours Lock-Out:** `\$149.00` flat coordination fee.
   - **Collection Flow:** When a facility calls or texts in a broken gate, the Owner assigns a licensed tech (`DPS-lic`), clicks **Invoice (`DOC 03`)** directly from the job row (auto-prefilled with facility, equipment, work-order ID, and fee), and marks the dispatch `paid` (`fee_collected = true`, status `approved`) once settled via Card/Zelle/ACH.
3. **Three-Stack 1099 Rep Compensation (`DOC 05`):**
   - **Fast-Start VOF Milestone (`\$50` Bonus):** Paid when a new rep completes their first **10 verified Vendor-on-File (`vendor_on_file = true`) enrollments** (requires manager name, direct phone/email, and `DOC 02` sent). Caps customer acquisition cost at **\$5/enrolled facility** while giving new reps a guaranteed Week-1 win.
   - **First-Dispatch Bounty (`\$40.00` Flat):** Paid the first time any facility closed by that rep completes a paid dispatch (`\$89` or `\$149`).
   - **12-Month Trailing Residual (`20%`):** Paid on every paid dispatch from that facility — including the first one, on top of the `\$40` bounty (DOC 05 §3(2)) — for 12 full months (`\$17.80` on Standard `\$89`; `\$29.80` on Emergency `\$149`).
   - **Multi-Property Operator Multiplier:** Regional storage supervisors frequently oversee **5 to 15 DFW locations**. When a rep signs a regional manager, every facility roof under that `operator_group` is credited to the closing rep (`closed_by` = the rep's user id), earning the `\$40` first-dispatch bounty + `20%` 12-month residual across **every single property**.

| Metric | Standard Dispatch (`\$89`) | Emergency Same-Day (`\$149`) |
| :--- | :---: | :---: |
| **First Paid Dispatch (`\$40` Bounty + `20%` to Rep)** | **\$31.20 Net to House (35%)** | **\$79.20 Net to House (53%)** |
| **Repeat Dispatch (`20%` Residual to Rep)** | **\$71.20 Net to House (80%)** | **\$119.20 Net to House (80%)** |

---

## 2. The 4-Agent Recruiting & Pipeline Swarm (`agents/recruiting_swarm.py`)

Never read resumes or run 30-minute Zoom interviews with unvetted cold callers. Every recruiting channel funnels directly into **[`audition.html`](../audition.html)**, where candidates test the interactive commission calculator and record a **30-second live storage manager opener** in their browser.

### Quick CLI Commands

```bash
# 1. Check Supabase connection & live portal URLs
python3 agents/recruiting_swarm.py status

# 2. Generate ready-to-post ads for Craigslist DFW, CommissionCrowd, Reddit, and Upwork/Indeed
python3 agents/recruiting_swarm.py generate-ads

# 3. Score a sourced rep candidate (0-100) and generate a custom DM/SMS invite
python3 agents/recruiting_swarm.py score-rep \
  --name "Marcus Vance" \
  --hrs 25 \
  --tags "b2b_cold_calling,property_management,commission_only,texas_local" \
  --notes "6 yrs commercial roofing & lot striping cold caller in DFW" \
  --voice

# 4. Seed or push sample 1099 rep candidates into Radar (`public.rep_candidates`)
python3 agents/recruiting_swarm.py seed-reps --push

# 5. Facility lead sweeps run in Radar (see "Owner SOP: Lead Sweep" below)
python3 agents/recruiting_swarm.py sweep-leads   # prints the instructions
```

### Target Sourcing Channels & Cadence

1. **CommissionCrowd & RepHunter (Highest Multi-Site Quality):**
   - Target independent B2B reps who already call on commercial property managers, roofing, paving, or security accounts in Texas.
2. **Craigslist DFW (`dallas.craigslist.org` → `sales / biz dev` & `gigs → talent`):**
   - Post Tuesday & Thursday mornings at 8:30 AM CT using the `craigslist_dfw` template from `recruiting_swarm.py generate-ads` (or copy directly from **Radar → Sales Reps → Recruiting Ad Kit**).
3. **Reddit (`r/forhire`, `r/sales`, `r/DFWJobs`, `r/telemarketing`):**
   - Post the `[Hiring]` brief and DM active B2B cold callers with the `audition.html` link.
4. **Upwork / Indeed ("Milestone Opener" Structure):**
   - Frame Milestone 1 as the **\$50 Fast-Start (10 Verified Vendor-on-File Enrollments)** so the listing complies with milestone/deliverable rules while staying 100% performance-based.


**Nothing posts these ads or finds applicants automatically.** Applicants reach Radar only when someone submits `audition.html`. Always use the tracked link for each channel (`audition.html?src=craigslist_dfw | commission_crowd | reddit_sales | upwork | indeed_zip | direct_invite`). The Radar Ad Kit copy buttons and `generate-ads` add it for you, and Radar shows "By ad" counts so you can see which channel is working. New applicants since your last visit get a **NEW** chip and a count on the Sales Reps tab (Radar refreshes every 60s).

---

## 3. Owner SOP: Auditing & Onboarding a Rep in 60 Seconds

1. **Listen in Radar (`radar.html` → `Sales Reps (1099)` tab):**
   - Play the candidate's 60-second voice audition inline.
   - Check that they sound sharp, unscripted, and natural delivering the *"keep our card on the corkboard as your free backup"* hook.
2. **1-Click Approve & Invite:**
   - Click **Approve & Text Onboarding** or **Approve & Email DOC 05**.
   - This automatically marks the candidate `promoted` and opens a pre-filled message containing [`docs.html?doc=d5`](../docs.html) (Independent Sales Rep Agreement) and the [`index.html`](../index.html) Console link.
3. **Activate in Command HQ (`index.html` → `Team` tab):**
   - Add the rep's email under **Staff Roster** with role `employee` (displayed as `1099 Sales Rep`).
   - Click **Approve as 1099 Rep**, then the rep's **Onboarding** checklist button: record the date DOC 05 was signed, the date the W-9 was received, their payout method and cell. **`+ Deal 25 Leads` stays locked until DOC 05 and W-9 are both recorded.**
   - Click **`+ Deal 25 Leads`** next to their name to assign 25 uncalled, top-scored DFW storage facilities exclusively to their queue (`assigned_to` = the rep's user id). Reps only ever see facilities dealt to them or closed by them — there is no open pool on the rep side.
   - The Team table shows each rep's **Calls 7d** and **Last active** (stamped whenever they log a call). If a rep goes inactive for 72+ hours, click **`Reclaim Uncalled`** to return their untouched leads back to the open pool.

---

## 4. Owner SOP: Monthly Payout (by the 10th, per DOC 05 §3)

1. Open **Team** — the **Unpaid** column is `rep_payout_balance.balance_usd` (commission earned + VOF bonuses − payouts recorded).
2. Confirm a W-9 is on file (the payout drawer warns if not).
3. Send the payment (Zelle / ACH / PayPal), then click **Record Payout**, split the amount into commission vs. VOF bonus, and paste the confirmation number. The rep sees it immediately under **My Pay → Payouts**.
4. `rep_payouts` is the year-end 1099-NEC record — confirm the current reporting threshold with your CPA.

## 5. What reps can and can't touch (enforced in the database)

- **Facilities / call log:** only leads assigned to or closed by them; every logged touch is stamped with their user id (`outreach_log.rep_id`) and can't be edited afterwards.
- **Dispatches:** they can request one ($89 / $149 only) and add notes; status, fee, fee-collected, tech and QA fields are owner-only. They can see dispatches on facilities they closed.
- **Off-limits:** tech roster, Radar lead/tech candidate queues, other reps' commissions and payouts.

---

## 6. Owner SOP: Lead Sweep (Google Maps → Radar)

The rep pipeline is only as good as the lead pool: every new rep needs 25 fresh facilities. Sweep weekly, or whenever **Team** warns the unassigned pool is under 25.

1. Open **Radar → Facility Leads**.
2. **Test (dry run)** with one city (e.g. `Plano`): confirms the key works and shows what would be added; saves nothing.
3. **Sweep City** to add one city, or **Run Sweep (all DFW)** for all ~36 cities (≤150 Google calls, 1–2 minutes).
4. Review the new cards (highest score first). Cards tagged **Recent gate pain** quote the Google review. **Promote to Prospects** creates the facility (HOT if recent pain, WARM if older pain, else STANDARD); **Dismiss** hides it for good.
5. Then deal leads from **Command HQ → Team → + Deal 25 Leads**.

**What the sweep does** (`supabase/functions/lead-sweep`): searches "self storage in {city}, TX" on Google Places (New), up to 3 pages per city; drops closed businesses, non-storage results, and anything matching `lead_chain_blocklist` (big chains with national gate contracts); skips anything already in Radar or your facilities (matched by Google place ID, phone, or name + city); scores gate pain in reviews (+35 recent / +20 older), independent (+20), small operator (+15) or regional operator at 3+ sites (+10, a Multi-Property Multiplier target), phone (+10), no website (+10), and distance from Plano (+10 ≤15 mi / +5 ≤30 mi). Re-sweeping never resurrects leads you promoted or dismissed. Every run is logged in `lead_sweeps`.

**Key & cost:** the Google key lives only in Supabase, encrypted in Vault as `google_maps_api_key` (an Edge Functions → Secrets → `GOOGLE_MAPS_API_KEY` entry would take priority), and should be restricted to Places API (New) in Google Cloud. Asking Google for reviews bills each search at its top Places tier, which has its own free monthly allowance; a weekly full sweep (~110 calls) should stay near or within it. Keep the daily quota cap and $10 budget alert in Google Cloud. Radar shows Google calls used this month next to the sweep buttons. Google returns at most 5 reviews per place, so a facility with no gate-pain quote may still have gate problems.
