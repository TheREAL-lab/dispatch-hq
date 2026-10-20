# Dispatch HQ — Claude Code & Antigravity Project Guide

See also the workspace master guide at [`../CLAUDE.md`](../CLAUDE.md).

## 1. Supabase Architecture (`REAL WORK PROJECT` — `teptzyvzuenolwtfosht`)
- **Schema:** `public` ONLY. (Never touch `flowsync` schema).
- **Core Tables:**
  - `facilities` — DFW self-storage facilities (`status`, `vendor_on_file`, `assigned_to`, `closed_by`, `closed_at`, `enrolled_at`, `operator_group`, `fit_notes`, `score`, `pain_recent`).
  - `outreach_log` — Call outcomes logged by Owner or 1099 reps (`called_by`).
  - `dispatches` — Work orders (`fee_charged` default `$89` Standard / `$149` Emergency, `fee_paid`).
  - `techs` — Licensed gate technicians (`dps_license`, `insured`, `active`).
  - `dispatch_staff` — Role mapping (`email`, `role` in `'owner' | 'employee'`, `name`, `active`).
  - `rep_commissions` — Automated commission ledger (`$40` `first_fee` bounty + `20%` `residual_20pct` for 12 months).
  - `lead_candidates`, `tech_candidates`, `rep_candidates` — Radar sourcing queues.

## 2. Applying the 1099 Sales Force SQL Migration
Run [`supabase/migrations/20261020_rep_sales_force_and_recruiting.sql`](./supabase/migrations/20261020_rep_sales_force_and_recruiting.sql) in the Supabase SQL Editor (or via Supabase CLI/MCP) to ensure:
1. `facilities` has `assigned_to`, `closed_by`, `closed_at`, `enrolled_at`, `operator_group`, `fit_notes`, `vendor_on_file`.
2. Triggers `trg_facility_rep_attribution` and `trg_dispatch_commission_credit` automatically attribute deals and generate `$40` / `20%` rows in `rep_commissions` when a dispatch is marked `paid`.
3. `rep_candidates` table and RLS policies are active for `audition.html` and `radar.html`.
*(Note: `index.html`, `radar.html`, and `audition.html` also include client-side fallbacks so the UI works seamlessly even before the migration is run).*
