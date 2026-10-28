# Dispatch HQ — Claude Code & Antigravity Project Guide

See also the workspace master guide at [`../CLAUDE.md`](../CLAUDE.md).

## 1. Supabase Architecture (`REAL WORK PROJECT` — `teptzyvzuenolwtfosht`)
- **Schema:** `public` ONLY. (Never touch `flowsync` schema).
- **Core Tables:**
  - `facilities` — DFW self-storage facilities (`call_status` in `not_called | no_answer | spoke | vendor_on_file | declined | client`, `vendor_on_file`, `assigned_to`, `closed_by`, `closed_at`, `enrolled_at`, `operator_group`, `contact_name`, `current_vendor`, `fit_notes`, `priority`). `assigned_to` / `closed_by` are `auth.users` ids.
  - `outreach_log` — Call outcomes logged by the Owner or 1099 reps.
  - `dispatches` — Work orders (`coordination_fee_usd` default `$89`; `$149` Emergency via `app_settings.emergency_fee_usd`; `fee_collected`; `status` in `requested | dispatched | on_site | completed | approved | cancelled`).
  - `techs` — Licensed gate technicians (`dps_license_number`, `tops_verified_on`, `coi_expires_on`, `is_active`).
  - `dispatch_staff` — Role mapping (`user_id`, `email`, `full_name`, `role` in `'owner' | 'employee' | 'pending'`, `jobs_scope`, `is_primary`).
  - `app_settings` — Key/value pricing & commission plan (`booking_fee_usd`, `emergency_fee_usd`, `commission_bounty_usd`, `commission_percent`, `commission_window_months`, `vof_milestone_count`, `vof_milestone_bonus_usd`).
  - `rep_candidates` — 1099 rep recruiting queue (`hours_per_week`, `capabilities`, `voice_sample_url`, `status` in `new | invited | auditioned | promoted | dismissed`).
  - `lead_candidates`, `tech_candidates` — Radar sourcing queues.
- **Views (read-only, never insert into them):**
  - `rep_commissions` — `$40` first-dispatch bounty + `20%` trail for 12 months, derived from `approved` + `fee_collected` dispatches on facilities with `closed_by` set.
  - `rep_vof_milestones` — Fast-Start bonus: every `vof_milestone_count` verified VOF enrollments (contact + current vendor logged) earns `vof_milestone_bonus_usd`.
- **Storage:** private bucket `rep-auditions` — applicants upload to `auditions/…`; only the owner can read (Radar uses signed URLs).

## 2. Sales Force Migration
[`supabase/migrations/20261020_rep_sales_force_and_recruiting.sql`](./supabase/migrations/20261020_rep_sales_force_and_recruiting.sql) is **applied** to the live project (as `rep_sales_force_and_recruiting`, `rep_vof_milestones_security_invoker` and `operator_group_owner_only`). It provides:
1. `facilities.enrolled_at` / `operator_group` and the `trg_facility_rep_attribution` trigger: reps auto-claim unassigned leads they work, closer attribution locks on `vendor_on_file`/`client`, and reps cannot reassign or re-attribute other reps' facilities or change `operator_group` (owner-only).
2. Multi-Property Operator Multiplier (`trg_facility_operator_group_lock_*`): closing one location credits every unattributed location in the same `operator_group` to that rep.
3. `rep_vof_milestones` view, `rep_candidates` table + RLS, and the `rep-auditions` bucket + policies.
