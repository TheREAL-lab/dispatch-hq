-- Dispatch HQ — lead sweep run log
-- One row per run of the `lead-sweep` Edge Function (Radar → Leads → Run Sweep).
-- Used for "last swept" / monthly Google API call counts and troubleshooting.
-- Applied to the live project as `lead_sweeps`.

create table if not exists public.lead_sweeps (
  id uuid primary key default gen_random_uuid(),
  run_by uuid default auth.uid() references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  cities text[] not null default '{}',
  dry_run boolean not null default false,
  api_calls integer not null default 0,
  found integer not null default 0,
  inserted integer not null default 0,
  skipped_chain integer not null default 0,
  skipped_duplicate integer not null default 0,
  skipped_closed integer not null default 0,
  error text
);
create index if not exists lead_sweeps_started_idx on public.lead_sweeps (started_at desc);

alter table public.lead_sweeps enable row level security;
drop policy if exists lead_sweeps_owner_all on public.lead_sweeps;
create policy lead_sweeps_owner_all on public.lead_sweeps for all to authenticated
  using (public.dhq_is_owner()) with check (public.dhq_is_owner());
revoke all on public.lead_sweeps from anon;
grant select, insert, update on public.lead_sweeps to authenticated;
