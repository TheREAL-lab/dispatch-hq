-- ============================================================================
-- Dispatch HQ — 1099 Sales Force Attribution, Auto-Commissions & Recruiting
-- Target: Supabase project "REAL WORK PROJECT" (teptzyvzuenolwtfosht), schema: public
-- Idempotent migration: safe to run in Supabase SQL Editor or via MCP execute_sql
-- ============================================================================

begin;

-- 1. Ensure attribution & multi-property columns exist on public.facilities
alter table public.facilities
  add column if not exists assigned_to uuid,
  add column if not exists closed_by uuid,
  add column if not exists closed_at timestamptz,
  add column if not exists enrolled_at timestamptz,
  add column if not exists operator_group text,
  add column if not exists fit_notes text,
  add column if not exists vendor_on_file boolean not null default false;

create index if not exists idx_facilities_assigned_to on public.facilities (assigned_to);
create index if not exists idx_facilities_closed_by on public.facilities (closed_by);
create index if not exists idx_facilities_call_status on public.facilities (call_status);

-- 2. Ensure default commission & emergency fee settings exist in public.app_settings
insert into public.app_settings (key, value)
values
  ('booking_fee_usd', '89'),
  ('emergency_fee_usd', '149'),
  ('commission_bounty_usd', '40'),
  ('commission_percent', '20'),
  ('commission_window_months', '12'),
  ('vof_milestone_count', '10'),
  ('vof_milestone_bonus_usd', '50')
on conflict (key) do nothing;

-- 3. Trigger: Auto-claim unassigned facilities & lock closer attribution (closed_by)
create or replace function public.fn_facility_rep_attribution()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text := (select public.dhq_role());
begin
  -- Auto-claim unassigned lead when a rep moves call_status past not_called/no_answer
  if v_uid is not null and v_role = 'employee' then
    if new.assigned_to is null and new.call_status in ('spoke', 'vendor_on_file', 'client', 'declined') then
      new.assigned_to := v_uid;
    end if;
  end if;

  -- Mark vendor_on_file flag and enrolled_at timestamp
  if new.call_status in ('vendor_on_file', 'client') then
    new.vendor_on_file := true;
    if new.enrolled_at is null then
      new.enrolled_at := now();
    end if;
  end if;

  -- Lock closer attribution when facility becomes vendor_on_file or client
  if new.call_status in ('vendor_on_file', 'client') and new.closed_by is null then
    new.closed_by := coalesce(new.assigned_to, v_uid);
    if new.closed_at is null then
      new.closed_at := now();
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_facility_rep_attribution on public.facilities;
create trigger trg_facility_rep_attribution
  before update on public.facilities
  for each row
  execute function public.fn_facility_rep_attribution();

-- 4. Ensure public.rep_commissions exists and has proper indexes & RLS
create table if not exists public.rep_commissions (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid references public.dispatches(id) on delete cascade,
  facility_id uuid references public.facilities(id) on delete set null,
  rep_id uuid not null,
  month text not null, -- YYYY-MM
  bounty_usd numeric(10,2) not null default 0,
  trail_usd numeric(10,2) not null default 0,
  paid boolean not null default false,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (dispatch_id)
);

create index if not exists idx_rep_commissions_rep_month on public.rep_commissions (rep_id, month);
create index if not exists idx_rep_commissions_facility on public.rep_commissions (facility_id);

alter table public.rep_commissions enable row level security;

drop policy if exists "rep_commissions_select" on public.rep_commissions;
create policy "rep_commissions_select"
  on public.rep_commissions
  for select
  to authenticated
  using (
    (select public.dhq_role()) = 'owner'
    or rep_id = (select auth.uid())
  );

drop policy if exists "rep_commissions_owner_write" on public.rep_commissions;
create policy "rep_commissions_owner_write"
  on public.rep_commissions
  for all
  to authenticated
  using ( (select public.dhq_role()) = 'owner' )
  with check ( (select public.dhq_role()) = 'owner' );

-- 5. Trigger: Auto-calculate and credit rep commission when dispatch fee is collected
create or replace function public.fn_dispatch_commission_credit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rep_id uuid;
  v_closed_at timestamptz;
  v_bounty_cfg numeric(10,2);
  v_pct_cfg numeric(10,2);
  v_win_months int;
  v_prior_count int;
  v_bounty numeric(10,2) := 0;
  v_trail numeric(10,2) := 0;
  v_month text;
begin
  -- Only credit when fee_collected is true and status is not cancelled
  if new.fee_collected is distinct from true or new.status = 'cancelled' then
    return new;
  end if;

  select coalesce(f.closed_by, f.assigned_to), coalesce(f.closed_at, f.enrolled_at, f.created_at, now())
    into v_rep_id, v_closed_at
    from public.facilities f
   where f.id = new.facility_id;

  if v_rep_id is null then
    return new;
  end if;

  -- Skip auto-commission if the closer is the primary owner (unless desired)
  if exists (
    select 1 from public.dispatch_staff s
     where s.user_id = v_rep_id and s.is_primary = true
  ) then
    return new;
  end if;

  select coalesce((select value::numeric from public.app_settings where key = 'commission_bounty_usd'), 40),
         coalesce((select value::numeric from public.app_settings where key = 'commission_percent'), 20),
         coalesce((select value::int from public.app_settings where key = 'commission_window_months'), 12)
    into v_bounty_cfg, v_pct_cfg, v_win_months;

  -- Check if this is the first collected commission for this facility
  select count(*)
    into v_prior_count
    from public.rep_commissions rc
   where rc.facility_id = new.facility_id
     and rc.dispatch_id is distinct from new.id
     and rc.bounty_usd > 0;

  if v_prior_count = 0 then
    v_bounty := v_bounty_cfg;
  end if;

  -- Check if within trailing commission window
  if now() <= (v_closed_at + (v_win_months || ' months')::interval) then
    v_trail := round((coalesce(new.coordination_fee_usd, 0) * (v_pct_cfg / 100.0))::numeric, 2);
  end if;

  v_month := to_char(coalesce(new.completed_at, now()), 'YYYY-MM');

  insert into public.rep_commissions (dispatch_id, facility_id, rep_id, month, bounty_usd, trail_usd)
  values (new.id, new.facility_id, v_rep_id, v_month, v_bounty, v_trail)
  on conflict (dispatch_id) do update
    set bounty_usd = excluded.bounty_usd,
        trail_usd = excluded.trail_usd,
        rep_id = excluded.rep_id,
        month = excluded.month;

  -- Also ensure the facility is marked as 'client'
  update public.facilities
     set call_status = 'client',
         vendor_on_file = true,
         closed_by = coalesce(closed_by, v_rep_id),
         closed_at = coalesce(closed_at, now())
   where id = new.facility_id;

  return new;
end;
$$;

revoke all on function public.fn_dispatch_commission_credit() from public, anon;

drop trigger if exists trg_dispatch_commission_credit on public.dispatches;
create trigger trg_dispatch_commission_credit
  after insert or update of fee_collected, status, coordination_fee_usd on public.dispatches
  for each row
  execute function public.fn_dispatch_commission_credit();

-- 6. Create public.rep_candidates table for Radar Recruiting Pipeline & Audition Portal
create table if not exists public.rep_candidates (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  city text,
  timezone text default 'America/Chicago',
  source text default 'audition_portal',
  profile_url text,
  hours_per_week int default 15,
  capabilities text[] default '{}',
  experience_summary text,
  voice_sample_url text,
  score int not null default 50,
  score_breakdown jsonb default '{}'::jsonb,
  status text not null default 'new' check (status in ('new', 'invited', 'auditioned', 'promoted', 'dismissed')),
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists idx_rep_candidates_status_score on public.rep_candidates (status, score desc);

alter table public.rep_candidates enable row level security;

-- Public applicants (anon or authenticated) can submit their audition into rep_candidates
drop policy if exists "rep_candidates_public_submit" on public.rep_candidates;
create policy "rep_candidates_public_submit"
  on public.rep_candidates
  for insert
  to anon, authenticated
  with check (
    status in ('new', 'auditioned')
    and length(coalesce(name, '')) between 2 and 120
  );

-- Only Owner can view, update, promote, or dismiss rep_candidates
drop policy if exists "rep_candidates_owner_all" on public.rep_candidates;
create policy "rep_candidates_owner_all"
  on public.rep_candidates
  for all
  to authenticated
  using ( (select public.dhq_role()) = 'owner' )
  with check ( (select public.dhq_role()) = 'owner' );

grant insert on public.rep_candidates to anon, authenticated;
grant select, update, delete on public.rep_candidates to authenticated;

commit;
