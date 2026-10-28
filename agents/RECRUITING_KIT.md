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
   - **Collection Flow:** When a facility calls or texts in a broken gate, the Owner assigns a licensed tech (`DPS-lic`), clicks **Invoice (`DOC 03`)** directly from the job row (auto-prefilled with facility, equipment, work-order ID, and fee), and marks the dispatch `paid` (`fee_paid = true`) once settled via Card/Zelle/ACH.
3. **Three-Stack 1099 Rep Compensation (`DOC 05`):**
   - **Fast-Start VOF Milestone (`\$50` Bonus):** Paid when a new rep completes their first **10 verified Vendor-on-File (`vendor_on_file = true`) enrollments** (requires manager name, direct phone/email, and `DOC 02` sent). Caps customer acquisition cost at **\$5/enrolled facility** while giving new reps a guaranteed Week-1 win.
   - **First-Dispatch Bounty (`\$40.00` Flat):** Paid the first time any facility closed by that rep completes a paid dispatch (`\$89` or `\$149`).
   - **12-Month Trailing Residual (`20%`):** Paid on every subsequent paid dispatch from that facility for 12 full months (`\$17.80` on Standard `\$89`; `\$29.80` on Emergency `\$149`).
   - **Multi-Property Operator Multiplier:** Regional storage supervisors frequently oversee **5 to 15 DFW locations**. When a rep signs a regional manager, every facility roof under that `operator_group` is locked to `closed_by = <rep_email>`, earning the `\$40` first-dispatch bounty + `20%` 12-month residual across **every single property**.

| Metric | Standard Dispatch (`\$89`) | Emergency Same-Day (`\$149`) |
| :--- | :---: | :---: |
| **First Paid Dispatch (`\$40` Bounty to Rep)** | **\$49.00 Net to House (55%)** | **\$109.00 Net to House (73%)** |
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

# 5. Run the DFW Gate-Pain Facility Lead Sweeper
python3 agents/recruiting_swarm.py sweep-leads --push
```

### Target Sourcing Channels & Cadence

1. **CommissionCrowd & RepHunter (Highest Multi-Site Quality):**
   - Target independent B2B reps who already call on commercial property managers, roofing, paving, or security accounts in Texas.
2. **Craigslist DFW (`dallas.craigslist.org` → `sales / biz dev` & `gigs → talent`):**
   - Post Tuesday & Thursday mornings at 8:30 AM CT using the `craigslist_dfw` template from `recruiting_swarm.py generate-ads` (or copy directly from **Radar → Sales Reps → Recruiting Ads & Swarm Kit**).
3. **Reddit (`r/forhire`, `r/sales`, `r/DFWJobs`, `r/telemarketing`):**
   - Post the `[Hiring]` brief and DM active B2B cold callers with the `audition.html` link.
4. **Upwork / Indeed ("Milestone Opener" Structure):**
   - Frame Milestone 1 as the **\$50 Fast-Start (10 Verified Vendor-on-File Enrollments)** so the listing complies with milestone/deliverable rules while staying 100% performance-based.

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
   - Click **`+ Deal 25 Leads`** next to their name to assign 25 uncalled, top-scored DFW storage facilities exclusively to their queue (`assigned_to = <rep_email>`).
   - If a rep goes inactive for 72+ hours, click **`Reclaim Uncalled`** to return their untouched leads back to the open pool.
