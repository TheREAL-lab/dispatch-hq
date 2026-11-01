# Dispatch HQ — Claude Code & Antigravity Project Guide

See also the workspace master guide at [`../CLAUDE.md`](../CLAUDE.md).

## 1. Supabase Architecture (`REAL WORK PROJECT` — `teptzyvzuenolwtfosht`)
- **Schema:** `public` ONLY. (Never touch `flowsync` schema).
- **Core Tables:**
  - `facilities` — DFW self-storage facilities (`call_status` in `not_called | no_answer | spoke | vendor_on_file | declined | client`, `vendor_on_file`, `assigned_to`, `closed_by`, `closed_at`, `enrolled_at`, `operator_group`, `contact_name`, `current_vendor`, `fit_notes`, `priority`). `assigned_to` / `closed_by` are `auth.users` ids.
  - `outreach_log` — Call outcomes logged by the Owner or 1099 reps. `rep_id` (defaults to `auth.uid()`, forced for reps by `trg_outreach_log_stamp`, which also sets `dispatch_staff.last_active_at`).
  - `dispatches` — Work orders (`coordination_fee_usd` default `$89`; `$149` Emergency via `app_settings.emergency_fee_usd`; `fee_collected`; `status` in `requested | dispatched | on_site | completed | approved | cancelled`).
  - `techs` — Licensed gate technicians (`dps_license_number`, `tops_verified_on`, `coi_expires_on`, `is_active`).
  - `dispatch_staff` — Role mapping (`user_id`, `email`, `full_name`, `role` in `'owner' | 'employee' | 'pending'`, `jobs_scope` (default `assigned`), `is_primary`, onboarding: `agreement_signed_at`, `w9_received_at`, `payout_method`, `phone`, `last_active_at`).
  - `rep_payouts` — Owner-recorded commission/VOF payouts (`total_usd` generated). Reps read their own.
  - `app_settings` — Key/value pricing & commission plan (`booking_fee_usd`, `emergency_fee_usd`, `commission_bounty_usd`, `commission_percent`, `commission_window_months`, `vof_milestone_count`, `vof_milestone_bonus_usd`).
  - `rep_candidates` — 1099 rep recruiting queue (`hours_per_week`, `capabilities`, `voice_sample_url`, `status` in `new | invited | auditioned | promoted | dismissed`).
  - `lead_candidates`, `tech_candidates` — Radar sourcing queues. `lead_candidates` is filled by the `lead-sweep` Edge Function (unique `place_id`); `lead_promote()` turns one into a facility.
  - `lead_sweeps` — One row per sweep run (api_calls, found, inserted, skips, error). Owner-only.
  - `lead_chain_blocklist` — Name patterns of chains the sweep skips.
- **Views (read-only, never insert into them):**
  - `rep_commissions` — `$40` first-dispatch bounty + `20%` trail for 12 months, derived from `approved` + `fee_collected` dispatches on facilities with `closed_by` set.
  - `rep_payout_balance` — Per-rep earned (commission + VOF bonus) vs. paid vs. balance. `security_invoker`.
  - `rep_vof_milestones` — Fast-Start bonus: every `vof_milestone_count` verified VOF enrollments (contact + current vendor logged) earns `vof_milestone_bonus_usd`.
- **Storage:** private bucket `rep-auditions` — applicants upload to `auditions/…`; only the owner can read (Radar uses signed URLs).

## 2. Sales Force Migration
[`supabase/migrations/20261020_rep_sales_force_and_recruiting.sql`](./supabase/migrations/20261020_rep_sales_force_and_recruiting.sql) is **applied** to the live project (as `rep_sales_force_and_recruiting`, `rep_vof_milestones_security_invoker` and `operator_group_owner_only`). It provides:
1. `facilities.enrolled_at` / `operator_group` and the `trg_facility_rep_attribution` trigger: reps auto-claim unassigned leads they work, closer attribution locks on `vendor_on_file`/`client`, and reps cannot reassign or re-attribute other reps' facilities or change `operator_group` (owner-only).
2. Multi-Property Operator Multiplier (`trg_facility_operator_group_lock_*`): closing one location credits every unattributed location in the same `operator_group` to that rep.
3. `rep_vof_milestones` view, `rep_candidates` table + RLS, and the `rep-auditions` bucket + policies.

## 3. Rep Hiring Readiness Migration
[`supabase/migrations/20261101_rep_hiring_readiness.sql`](./supabase/migrations/20261101_rep_hiring_readiness.sql) is **applied** (as `rep_hiring_readiness`, `dispatch_rep_guard_employee_only`, `dhq_dispatch_ready`):
1. RLS split: reps (`employee`) see/update only facilities with `assigned_to` or `closed_by` = them; `outreach_log` is own + history on own leads, append-only; `techs`, `lead_candidates`, `tech_candidates` are owner-only; reps also see dispatches on facilities they closed.
2. `trg_dispatch_rep_guard`: for reps, inserts are forced to `requested`, `$89`/`$149`, uncollected, no tech; updates can only change `notes`/`issue`.
3. `rep_commissions` is `security_invoker`; `rep_payouts` + `rep_payout_balance`; `dhq_dispatch_ready()` RPC; `dhq_*` helpers not executable by `anon`.
4. Commission math (unchanged, matches DOC 05 §3): first paid dispatch = `$40` bounty **plus** `20%` trail; later dispatches in the window = `20%`.

## 4. Lead Sweep (Edge Function `lead-sweep`)
- Source: [`supabase/functions/lead-sweep/`](./supabase/functions/lead-sweep/) — `index.ts` (handler: owner check via `dhq_is_owner`, runs as the caller so RLS applies) and `sweep.ts` (pure search/filter/score logic). Tests: `node --test supabase/functions/lead-sweep/sweep.test.ts`. Deploy with `verify_jwt: true`, both files.
- Key: Google Places API (New). The function uses the `GOOGLE_MAPS_API_KEY` Edge Function secret if set, otherwise the Vault secret `google_maps_api_key` via the owner-only RPC `dhq_google_maps_key()` ([`20261102_google_maps_key_from_vault.sql`](./supabase/migrations/20261102_google_maps_key_from_vault.sql), applied). **Currently stored in Vault.** Rotate with `vault.update_secret`. Never commit the key or put it in the pages.
- Called from Radar → Facility Leads (`runSweep()`); body `{ cities?, dry_run?, max_calls? }` (cities must be from `DEFAULT_CITIES`; `max_calls` default 150, max 300).
- Migration [`20261102_lead_sweeps.sql`](./supabase/migrations/20261102_lead_sweeps.sql) is **applied** (as `lead_sweeps`).
