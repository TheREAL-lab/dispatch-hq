-- Dispatch HQ — 1099 rep hiring readiness
-- Locks down what reps (role 'employee') can see/change before outside hires get
-- logins, attributes every call to a rep, and adds a payout ledger.
--
--  1. outreach_log.rep_id (who logged the touch) + rep last-activity tracking
--  2. facilities: reps see/update only leads assigned to or closed by them
--  3. outreach_log: reps see their own touches + history on their leads; append-only
--  4. techs, lead_candidates, tech_candidates: owner-only (Radar / roster)
--  5. dispatches: reps see dispatches on facilities they closed; can't edit fees,
--     collection, tech or QA fields; employees default to jobs_scope 'assigned'
--  6. rep_commissions -> security_invoker (filtering already by rep_id)
--  7. rep_payouts ledger + rep_payout_balance view
--  8. dispatch_staff onboarding columns (agreement, W-9, payout method, phone)
--  9. revoke anon EXECUTE on dhq_* helpers
-- 10. remove the e2e test applicant
--
-- Applied to the live project as `rep_hiring_readiness`, `dispatch_rep_guard_employee_only` and `dhq_dispatch_ready`.

-- ---------------------------------------------------------------------------
-- 1. Call attribution
-- ---------------------------------------------------------------------------
alter table public.outreach_log
  add column if not exists rep_id uuid default auth.uid() references auth.users(id) on delete set null;
create index if not exists outreach_log_rep_contacted_idx on public.outreach_log (rep_id, contacted_at desc);

alter table public.dispatch_staff
  add column if not exists phone text,
  add column if not exists agreement_signed_at timestamptz,
  add column if not exists w9_received_at timestamptz,
  add column if not exists payout_method text,
  add column if not exists last_active_at timestamptz;

-- Reps can't log a touch as someone else; stamp last activity for the 72h reclaim rule.
create or replace function public.fn_outreach_log_stamp()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.dhq_role() = 'employee' or new.rep_id is null then
    new.rep_id := coalesce(auth.uid(), new.rep_id);
  end if;
  if new.rep_id is not null then
    update public.dispatch_staff set last_active_at = now() where user_id = new.rep_id;
  end if;
  return new;
end;
$$;
revoke all on function public.fn_outreach_log_stamp() from public, anon, authenticated;

drop trigger if exists trg_outreach_log_stamp on public.outreach_log;
create trigger trg_outreach_log_stamp
  before insert on public.outreach_log
  for each row execute function public.fn_outreach_log_stamp();

-- ---------------------------------------------------------------------------
-- 2. Facilities: reps only see their own book
-- ---------------------------------------------------------------------------
drop policy if exists facilities_select on public.facilities;
drop policy if exists facilities_update on public.facilities;
drop policy if exists facilities_insert on public.facilities;

create policy facilities_select on public.facilities for select
  using (public.dhq_is_owner()
         or (public.dhq_is_staff() and (assigned_to = auth.uid() or closed_by = auth.uid())));

create policy facilities_update on public.facilities for update
  using (public.dhq_is_owner()
         or (public.dhq_is_staff() and (assigned_to = auth.uid() or closed_by = auth.uid())))
  with check (public.dhq_is_owner()
         or (public.dhq_is_staff() and (assigned_to = auth.uid() or closed_by = auth.uid())));

create policy facilities_insert on public.facilities for insert
  with check (public.dhq_is_owner());

-- ---------------------------------------------------------------------------
-- 3. Outreach log: own touches + history on own leads; append-only for reps
-- ---------------------------------------------------------------------------
drop policy if exists outreach_select on public.outreach_log;
drop policy if exists outreach_insert on public.outreach_log;
drop policy if exists outreach_update on public.outreach_log;

create policy outreach_select on public.outreach_log for select
  using (public.dhq_is_owner()
         or (public.dhq_is_staff() and (
               rep_id = auth.uid()
               or exists (select 1 from public.facilities f
                           where f.id = outreach_log.facility_id
                             and (f.assigned_to = auth.uid() or f.closed_by = auth.uid())))));

create policy outreach_insert on public.outreach_log for insert
  with check (public.dhq_is_owner()
         or (public.dhq_is_staff()
             and rep_id = auth.uid()
             and exists (select 1 from public.facilities f
                          where f.id = outreach_log.facility_id
                            and (f.assigned_to = auth.uid() or f.closed_by = auth.uid()))));

create policy outreach_update on public.outreach_log for update
  using (public.dhq_is_owner()) with check (public.dhq_is_owner());

-- ---------------------------------------------------------------------------
-- 4. Owner-only tables: tech roster and Radar sourcing queues
-- ---------------------------------------------------------------------------
drop policy if exists techs_select on public.techs;
drop policy if exists techs_insert on public.techs;
drop policy if exists techs_update on public.techs;
create policy techs_select on public.techs for select using (public.dhq_is_owner());
create policy techs_insert on public.techs for insert with check (public.dhq_is_owner());
create policy techs_update on public.techs for update using (public.dhq_is_owner()) with check (public.dhq_is_owner());

drop policy if exists lead_candidates_select on public.lead_candidates;
drop policy if exists lead_candidates_insert on public.lead_candidates;
drop policy if exists lead_candidates_update on public.lead_candidates;
create policy lead_candidates_select on public.lead_candidates for select using (public.dhq_is_owner());
create policy lead_candidates_insert on public.lead_candidates for insert with check (public.dhq_is_owner());
create policy lead_candidates_update on public.lead_candidates for update using (public.dhq_is_owner()) with check (public.dhq_is_owner());

drop policy if exists tech_candidates_select on public.tech_candidates;
drop policy if exists tech_candidates_insert on public.tech_candidates;
drop policy if exists tech_candidates_update on public.tech_candidates;
create policy tech_candidates_select on public.tech_candidates for select using (public.dhq_is_owner());
create policy tech_candidates_insert on public.tech_candidates for insert with check (public.dhq_is_owner());
create policy tech_candidates_update on public.tech_candidates for update using (public.dhq_is_owner()) with check (public.dhq_is_owner());

-- ---------------------------------------------------------------------------
-- 5. Dispatches
-- ---------------------------------------------------------------------------
-- Reps also see dispatches on facilities they closed (that's what pays them).
drop policy if exists dispatches_select on public.dispatches;
create policy dispatches_select on public.dispatches for select
  using (public.dhq_is_staff() and (
           public.dhq_can_close()
           or public.dhq_jobs_scope() = 'all'
           or assigned_to = auth.uid()
           or exists (select 1 from public.facilities f
                       where f.id = dispatches.facility_id and f.closed_by = auth.uid())));

-- Reps can request dispatches and add notes, but money / QA / tech fields are the owner's.
create or replace function public.fn_dispatch_rep_guard()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_std numeric;
  v_rush numeric;
begin
  -- Only 1099 reps are restricted; owner, service role and SQL editor pass through.
  if public.dhq_role() is distinct from 'employee' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    select value::numeric into v_std from public.app_settings where key = 'booking_fee_usd';
    select value::numeric into v_rush from public.app_settings where key = 'emergency_fee_usd';
    v_std := coalesce(v_std, 89);
    v_rush := coalesce(v_rush, 149);
    if new.coordination_fee_usd is distinct from v_std and new.coordination_fee_usd is distinct from v_rush then
      new.coordination_fee_usd := v_std;
    end if;
    new.status := 'requested';
    new.fee_collected := false;
    new.tech_id := null;
    new.assigned_to := auth.uid();
    new.on_time := null;
    new.first_try_approval := null;
    new.repair_cost_usd := null;
  else
    new.facility_id := old.facility_id;
    new.coordination_fee_usd := old.coordination_fee_usd;
    new.fee_collected := old.fee_collected;
    new.tech_id := old.tech_id;
    new.assigned_to := old.assigned_to;
    new.status := old.status;
    new.on_time := old.on_time;
    new.first_try_approval := old.first_try_approval;
    new.repair_cost_usd := old.repair_cost_usd;
    new.dispatched_at := old.dispatched_at;
    new.completed_at := old.completed_at;
    new.photo_evidence_url := old.photo_evidence_url;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dispatch_rep_guard on public.dispatches;
create trigger trg_dispatch_rep_guard
  before insert or update on public.dispatches
  for each row execute function public.fn_dispatch_rep_guard();

update public.dispatch_staff set jobs_scope = 'assigned' where role = 'employee';
alter table public.dispatch_staff alter column jobs_scope set default 'assigned';

-- ---------------------------------------------------------------------------
-- 6. Commission view runs with the caller's permissions
-- ---------------------------------------------------------------------------
alter view public.rep_commissions set (security_invoker = true);
revoke all on public.rep_commissions from anon;
revoke insert, update, delete, truncate, references, trigger on public.rep_commissions from authenticated;
revoke all on public.rep_vof_milestones from anon;
revoke insert, update, delete, truncate, references, trigger on public.rep_vof_milestones from authenticated;

-- ---------------------------------------------------------------------------
-- 7. Payout ledger
-- ---------------------------------------------------------------------------
create table if not exists public.rep_payouts (
  id uuid primary key default gen_random_uuid(),
  rep_id uuid not null references auth.users(id) on delete restrict,
  period_start date,
  period_end date,
  commission_usd numeric(10,2) not null default 0 check (commission_usd >= 0),
  vof_bonus_usd numeric(10,2) not null default 0 check (vof_bonus_usd >= 0),
  total_usd numeric(10,2) generated always as (commission_usd + vof_bonus_usd) stored,
  paid_on date not null default current_date,
  method text,
  reference text,
  notes text,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (commission_usd + vof_bonus_usd > 0)
);
create index if not exists rep_payouts_rep_idx on public.rep_payouts (rep_id, paid_on desc);

alter table public.rep_payouts enable row level security;
drop policy if exists rep_payouts_select on public.rep_payouts;
drop policy if exists rep_payouts_owner_write on public.rep_payouts;
create policy rep_payouts_select on public.rep_payouts for select to authenticated
  using (public.dhq_is_owner() or rep_id = auth.uid());
create policy rep_payouts_owner_write on public.rep_payouts for all to authenticated
  using (public.dhq_is_owner()) with check (public.dhq_is_owner());
revoke all on public.rep_payouts from anon;
grant select, insert, update, delete on public.rep_payouts to authenticated;

create or replace view public.rep_payout_balance
with (security_invoker = true) as
with earned as (
  select rep_id, sum(bounty_usd + trail_usd) as amt from public.rep_commissions group by rep_id
), vof as (
  select rep_id, bonus_usd from public.rep_vof_milestones
), paid as (
  select rep_id, sum(total_usd) as amt, max(paid_on) as last_paid_on from public.rep_payouts group by rep_id
), reps as (
  select rep_id from earned union select rep_id from vof union select rep_id from paid
)
select r.rep_id,
       coalesce(e.amt, 0)::numeric(10,2) as commission_earned_usd,
       coalesce(v.bonus_usd, 0)::numeric(10,2) as vof_bonus_earned_usd,
       (coalesce(e.amt, 0) + coalesce(v.bonus_usd, 0))::numeric(10,2) as total_earned_usd,
       coalesce(p.amt, 0)::numeric(10,2) as paid_usd,
       (coalesce(e.amt, 0) + coalesce(v.bonus_usd, 0) - coalesce(p.amt, 0))::numeric(10,2) as balance_usd,
       p.last_paid_on
  from reps r
  left join earned e on e.rep_id = r.rep_id
  left join vof v on v.rep_id = r.rep_id
  left join paid p on p.rep_id = r.rep_id
 where r.rep_id is not null;
revoke all on public.rep_payout_balance from anon;
grant select on public.rep_payout_balance to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Helper functions: signed-in only
-- ---------------------------------------------------------------------------
revoke execute on function public.dhq_role() from public, anon;
revoke execute on function public.dhq_is_owner() from public, anon;
revoke execute on function public.dhq_is_staff() from public, anon;
revoke execute on function public.dhq_can_close() from public, anon;
revoke execute on function public.dhq_jobs_scope() from public, anon;
grant execute on function public.dhq_role(), public.dhq_is_owner(), public.dhq_is_staff(),
  public.dhq_can_close(), public.dhq_jobs_scope() to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Test data
-- ---------------------------------------------------------------------------
delete from public.rep_candidates where email = 'e2e-test@example.com';

-- ---------------------------------------------------------------------------
-- 11. Dispatch capacity check (applied as `dhq_dispatch_ready`)
--     Lets the rep console show a "tech bench is being staffed" banner without
--     granting reps SELECT on the tech roster.
-- ---------------------------------------------------------------------------
create or replace function public.dhq_dispatch_ready()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.dhq_is_staff() and exists (
    select 1 from public.techs
     where is_active and coi_expires_on is not null and coi_expires_on >= current_date);
$$;
revoke execute on function public.dhq_dispatch_ready() from public, anon;
grant execute on function public.dhq_dispatch_ready() to authenticated;
