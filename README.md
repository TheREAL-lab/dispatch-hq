# Dispatch HQ — Texas Gate Dispatch

Internal operations dashboard, 1099 sales rep calling console, candidate/lead radar, and legal document kit for **Texas Gate Dispatch** (serving 600+ self-storage facilities across DFW).

## Application Pages

- **[`index.html`](./index.html)** — **Command HQ & 1099 Rep Calling Console (`v2.2`)**
  - **Role-Based Views (`dhq_role()`):**
    - **`owner`:** Full access to Prospects, Active Jobs (`$89` Standard / `$149` Emergency), Tech Roster, Pipeline Analytics, Team & Commissions (`+ Deal 25 Leads` / `Reclaim Uncalled`), Sales Playbook, Radar, and Legal Docs.
    - **`employee` (1099 Sales Rep):** Locked-down calling workstation showing only the rep's personal KPIs (My Calls Today, My Pipeline, My Closed Deals, Fast-Start VOF Milestone `X/10 = +$50`, Pending/Paid Commission), their assigned/open DFW facility leads (`assigned_to`), in-drawer live Call Script & Objection Playbook, 1-click SMS/Email Terms (`DOC 02`), and My Commissions (`Playbook` tab with interactive earnings calculator).
- **[`radar.html`](./radar.html)** — **Owner Targeting & Recruiting Console**
  - Owner-only console (`dhq_role() === 'owner'`) with three pipelines:
    1. **Facility Leads (`lead_candidates`)** — Scored DFW self-storage facilities with Google Review "Recent Gate Pain" evidence.
    2. **Gate Techs (`tech_candidates`)** — Vetted commercial gate/access-control contractors with Texas DPS TOPS license verification links.
    3. **Sales Reps (`rep_candidates`)** — 1099 outbound rep audition queue with inline 60-second voice playback, 1-click SMS/Email onboarding invites, and built-in Recruiting Ad Kit.
- **[`audition.html`](./audition.html)** — **Self-Serve 60-Second 1099 Voice Audition Portal**
  - Public recruiting landing page with interactive commission calculator (`$50` Fast-Start + `$40` First-Dispatch Bounty + `20%` 12-Month Residuals + Multi-Property Operator Multiplier) and in-browser `MediaRecorder` voice audition that submits directly into `public.rep_candidates`.
- **[`docs.html`](./docs.html)** — **Legal, Invoice & Onboarding Kit (`DOC 01` – `DOC 05`)**
  - `DOC 01`: Subcontractor Service Agreement (Gate Techs)
  - `DOC 02`: Facility Dispatch Terms (`$89` Standard / `$149` Emergency, `$0` upfront Vendor-on-File)
  - `DOC 03`: Service Dispatch & Coordination Invoice (supports URL auto-prefill from `index.html` job rows)
  - `DOC 04`: Subcontractor Onboarding Packet (W-9, COI, DPS License)
  - `DOC 05`: Independent Sales Rep Agreement (1099 Commission-Only + Multi-Property Portfolio Attribution)

## Database & Recruiting Swarm

- **Supabase Migration:** [`supabase/migrations/20261020_rep_sales_force_and_recruiting.sql`](./supabase/migrations/20261020_rep_sales_force_and_recruiting.sql)
- **Recruiting & Lead-Sweep Agent Swarm:** [`agents/recruiting_swarm.py`](./agents/recruiting_swarm.py) & [`agents/RECRUITING_KIT.md`](./agents/RECRUITING_KIT.md)

© 2026 Texas Gate Dispatch. All rights reserved.
