-- ============================================================================
-- Dispatch HQ — 1099 Sales Force Attribution, VOF Milestones & Recruiting
-- Target: Supabase project "REAL WORK PROJECT" (teptzyvzuenolwtfosht), schema: public
--
-- Builds on the live schema from earlier migrations:
--   * public.rep_commissions is a VIEW (sales_team_leads_and_commissions) that
--     derives the $40 first-dispatch bounty + 20% trail from approved,
--     fee_collected dispatches on facilities with closed_by set. It is left as-is;
--     commissions are never inserted by hand.
--   * public.facilities already has assigned_to, closed_by, closed_at,
--     vendor_on_file, fit_notes.
-- Idempotent: safe to re-run.
-- ============================================================================

begin;

-- 1. Remaining attribution & multi-property columns on public.facilities
alter table public.facilities
  add column if not exists enrolled_at timestamptz,
  add column if not exists operator_group text;

create index if not exists idx_facilities_assigned_to on public.facilities (assigned_to);
create index if not exists idx_facilities_closed_by on public.facilities (closed_by);
create index if not exists idx_facilities_operator_group on public.facilities (lower(btrim(operator_group)))
  where operator_group is not null;

-- 2. Settings used by index.html that were never seeded
insert into public.app_settings (key, value)
values
  ('emergency_fee_usd', '149'),
  ('vof_milestone_count', '10'),
  ('vof_milestone_bonus_usd', '50')
on conflict (key) do nothing;

-- 3. Attribution trigger (replaces f_set_closed_by / trg_facilities_closed_by)
create or replace function public.fn_facility_rep_attribution()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_role text := public.dhq_role();
  v_group_rep uuid;
begin
  -- Employees (1099 reps) may claim an unassigned lead but not reassign or
  -- re-attribute anyone else's, and only the owner sets operator_group (it drives
  -- cross-crediting below, so a rep retagging a facility could otherwise claim a
  -- whole group they never worked). Skipped for nested updates made by
  -- fn_facility_operator_group_lock below.
  if v_role = 'employee' and pg_trigger_depth() = 1 then
    if tg_op = 'INSERT' then
      new.closed_by := null;
      new.closed_at := null;
      new.operator_group := null;
      if new.assigned_to is distinct from v_uid then
        new.assigned_to := null;
      end if;
    else
      new.closed_by := old.closed_by;
      new.closed_at := old.closed_at;
      new.operator_group := old.operator_group;
      if new.assigned_to is distinct from old.assigned_to
         and not (old.assigned_to is null and new.assigned_to = v_uid) then
        new.assigned_to := old.assigned_to;
      end if;
    end if;
  end if;

  -- Auto-claim an unassigned lead when a rep works it
  if v_role = 'employee' and new.assigned_to is null
     and new.call_status in ('spoke', 'vendor_on_file', 'client', 'declined') then
    new.assigned_to := v_uid;
  end if;

  -- Enrollment flags
  if new.call_status in ('vendor_on_file', 'client') then
    new.vendor_on_file := true;
    new.enrolled_at := coalesce(new.enrolled_at, now());
  end if;

  -- A facility joining an operator group that a rep already closed inherits that rep
  if new.closed_by is null and nullif(btrim(new.operator_group), '') is not null then
    select f.closed_by into v_group_rep
      from public.facilities f
     where lower(btrim(f.operator_group)) = lower(btrim(new.operator_group))
       and f.closed_by is not null
       and f.id <> new.id
     order by f.closed_at nulls last
     limit 1;
    if v_group_rep is not null then
      new.closed_by := v_group_rep;
      new.closed_at := now();
    end if;
  end if;

  -- Lock closer attribution on enrollment
  if new.call_status in ('vendor_on_file', 'client') and new.closed_by is null then
    new.closed_by := coalesce(new.assigned_to, v_uid);
    new.closed_at := coalesce(new.closed_at, now());
  end if;

  return new;
end;
$$;

drop trigger if exists trg_facilities_closed_by on public.facilities;
drop trigger if exists trg_facility_rep_attribution on public.facilities;
create trigger trg_facility_rep_attribution
  before insert or update on public.facilities
  for each row
  execute function public.fn_facility_rep_attribution();

drop function if exists public.f_set_closed_by();

-- 4. Multi-Property Operator Multiplier (DOC 05 §3): once one location in an
--    operator_group is closed, every other unattributed location in that group
--    is credited to the same rep, so each earns its own bounty + trail via the
--    rep_commissions view.
create or replace function public.fn_facility_operator_group_lock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.facilities f
     set closed_by = new.closed_by,
         closed_at = now()
   where lower(btrim(f.operator_group)) = lower(btrim(new.operator_group))
     and f.closed_by is null
     and f.id <> new.id;
  return null;
end;
$$;

revoke all on function public.fn_facility_operator_group_lock() from public, anon, authenticated;

-- Compares OLD/NEW rather than using UPDATE OF, because closed_by is usually set
-- by trg_facility_rep_attribution, not named in the client's SET list.
drop trigger if exists trg_facility_operator_group_lock on public.facilities;
drop trigger if exists trg_facility_operator_group_lock_ins on public.facilities;
create trigger trg_facility_operator_group_lock_ins
  after insert on public.facilities
  for each row
  when (new.closed_by is not null and nullif(btrim(new.operator_group), '') is not null)
  execute function public.fn_facility_operator_group_lock();

drop trigger if exists trg_facility_operator_group_lock_upd on public.facilities;
create trigger trg_facility_operator_group_lock_upd
  after update on public.facilities
  for each row
  when (new.closed_by is not null and nullif(btrim(new.operator_group), '') is not null
        and (old.closed_by is distinct from new.closed_by or old.operator_group is distinct from new.operator_group))
  execute function public.fn_facility_operator_group_lock();

-- Backfill enrollment flags for facilities enrolled before this migration
update public.facilities
   set vendor_on_file = true,
       enrolled_at = coalesce(enrolled_at, closed_at, updated_at)
 where call_status in ('vendor_on_file', 'client')
   and (vendor_on_file is distinct from true or enrolled_at is null);

-- 5. Fast-Start VOF milestone: every N verified enrollments (decision-maker name
--    and current vendor logged) earns the milestone bonus. Same visibility rule as
--    rep_commissions: a rep sees their own row, the owner sees all.
create or replace view public.rep_vof_milestones as
select rep_id,
       verified_vof,
       milestone_count,
       milestones_earned,
       milestones_earned * milestone_bonus_usd as bonus_usd,
       verified_vof % milestone_count as progress
  from (
    select f.closed_by as rep_id,
           count(*)::int as verified_vof,
           greatest(1, coalesce((select value::int from public.app_settings where key = 'vof_milestone_count'), 10)) as milestone_count,
           coalesce((select value::numeric from public.app_settings where key = 'vof_milestone_bonus_usd'), 50) as milestone_bonus_usd,
           count(*)::int / greatest(1, coalesce((select value::int from public.app_settings where key = 'vof_milestone_count'), 10)) as milestones_earned
      from public.facilities f
     where f.closed_by is not null
       and f.vendor_on_file
       and nullif(btrim(f.contact_name), '') is not null
       and nullif(btrim(f.current_vendor), '') is not null
     group by f.closed_by
  ) x
 where rep_id = auth.uid() or public.dhq_is_owner();

-- Only reads facilities, which every staff member can already select, so it can
-- run with the caller's permissions.
alter view public.rep_vof_milestones set (security_invoker = true);
revoke all on public.rep_vof_milestones from anon;
grant select on public.rep_vof_milestones to authenticated;

-- 6. Rep recruiting pipeline (radar.html + audition.html)
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
  created_at timestamptz not null default now(),
  -- Recordings live in the rep-auditions bucket; only a path or link is stored here.
  constraint rep_candidates_field_lengths check (
    length(coalesce(email, '')) <= 254
    and length(coalesce(phone, '')) <= 40
    and length(coalesce(city, '')) <= 120
    and length(coalesce(source, '')) <= 60
    and length(coalesce(profile_url, '')) <= 500
    and length(coalesce(experience_summary, '')) <= 4000
    and length(coalesce(voice_sample_url, '')) <= 500
    and length(coalesce(notes, '')) <= 4000
    and coalesce(array_length(capabilities, 1), 0) <= 20
    and hours_per_week between 0 and 80
  )
);

create index if not exists idx_rep_candidates_status_score on public.rep_candidates (status, score desc);

alter table public.rep_candidates enable row level security;

drop policy if exists "rep_candidates_public_submit" on public.rep_candidates;
create policy "rep_candidates_public_submit"
  on public.rep_candidates
  for insert
  to anon, authenticated
  with check (
    status in ('new', 'auditioned')
    and length(coalesce(name, '')) between 2 and 120
  );

drop policy if exists "rep_candidates_owner_all" on public.rep_candidates;
create policy "rep_candidates_owner_all"
  on public.rep_candidates
  for all
  to authenticated
  using ( public.dhq_is_owner() )
  with check ( public.dhq_is_owner() );

revoke all on public.rep_candidates from anon;
grant insert on public.rep_candidates to anon, authenticated;
grant select, update, delete on public.rep_candidates to authenticated;

-- 7. Private bucket for voice auditions: applicants may upload (size/type capped),
--    only the owner can listen.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rep-auditions', 'rep-auditions', false, 3145728,
        array['audio/webm', 'audio/ogg', 'audio/mp4', 'audio/mpeg', 'audio/wav', 'audio/x-m4a'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "rep_auditions_public_upload" on storage.objects;
create policy "rep_auditions_public_upload"
  on storage.objects
  for insert
  to anon, authenticated
  with check ( bucket_id = 'rep-auditions' and (storage.foldername(name))[1] = 'auditions' );

drop policy if exists "rep_auditions_owner_read" on storage.objects;
create policy "rep_auditions_owner_read"
  on storage.objects
  for select
  to authenticated
  using ( bucket_id = 'rep-auditions' and public.dhq_is_owner() );

drop policy if exists "rep_auditions_owner_delete" on storage.objects;
create policy "rep_auditions_owner_delete"
  on storage.objects
  for delete
  to authenticated
  using ( bucket_id = 'rep-auditions' and public.dhq_is_owner() );

commit;
