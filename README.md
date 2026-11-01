# Dispatch HQ — Texas Gate Dispatch

Internal operations dashboard, 1099 sales rep calling console, candidate/lead radar, and legal document kit for **Texas Gate Dispatch** (serving 600+ self-storage facilities across DFW).

## Application Pages

- **[`index.html`](./index.html)** — **Command HQ & 1099 Rep Calling Console (`v2.2`)**
  - **Role-Based Views (`dhq_role()`):**
    - **`owner`:** Full access to Prospects, Active Jobs (`$89` Standard / `$149` Emergency), Tech Roster, Pipeline Analytics, Team & Commissions (`+ Deal 25 Leads` / `Reclaim Uncalled`), Sales Playbook, Radar, and Legal Docs.
    - **`employee` (1099 Sales Rep):** Locked-down calling workstation showing only the rep's personal KPIs (My Calls Today, My Pipeline, My Closed Deals, Fast-Start VOF Milestone `X/10 = +$50`, Pending/Paid Commission), their assigned/open DFW facility leads (`assigned_to`), in-drawer live Call Script & Objection Playbook, 1-click SMS/Email Terms (`DOC 02`), and My Commissions (`Playbook` tab with interactive earnings calculator).
- **[`radar.html`](./radar.html)** — **Owner Targeting & Recruiting Console**
  - Owner-only console (`dhq_role() === 'owner'`) with three pipelines:
    1. **Facility Leads (`lead_candidates`)** — **Run Sweep** searches Google Maps for DFW self-storage (via the `lead-sweep` Edge Function), skips chains and existing leads, and scores Google Review "Recent Gate Pain" evidence. Promote to Prospects or Dismiss.
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

## Install as an App (Laptop & Android)

Dispatch HQ is an installable web app (PWA). Once it's installed it opens in its own window from your desktop, taskbar or home screen, with no browser bar. It updates itself every time we deploy.

Open **https://thereal-lab.github.io/dispatch-hq/** first, then:

- **Laptop (Chrome or Edge on Windows, Mac or Chromebook):** click **⬇ Install app** in the Dispatch HQ header, or the install icon at the right end of the address bar. Then pin it to your taskbar or dock.
- **Android (Chrome):** tap **⬇ Install app**, or ⋮ menu → **Install app** / **Add to Home screen**. Long-press the icon for the Radar and Document Kit shortcuts.
- **iPhone (Safari):** Share → **Add to Home Screen**.

Files: [`manifest.webmanifest`](./manifest.webmanifest), [`sw.js`](./sw.js) (pages are network-first with an offline fallback; Supabase traffic is never cached), [`pwa.js`](./pwa.js) (registers the service worker and runs the install button), [`icons/`](./icons). When you change the cached file list in `sw.js`, bump `VERSION`.

## Database & Recruiting Swarm

- **Supabase Migration:** [`supabase/migrations/20261020_rep_sales_force_and_recruiting.sql`](./supabase/migrations/20261020_rep_sales_force_and_recruiting.sql)
- **Lead Sweep Edge Function:** [`supabase/functions/lead-sweep`](./supabase/functions/lead-sweep) (needs the `GOOGLE_MAPS_API_KEY` Edge Function secret; tests: `node --test supabase/functions/lead-sweep/sweep.test.ts`)
- **Recruiting Agent Swarm:** [`agents/recruiting_swarm.py`](./agents/recruiting_swarm.py) & [`agents/RECRUITING_KIT.md`](./agents/RECRUITING_KIT.md)

© 2026 Texas Gate Dispatch. All rights reserved.
