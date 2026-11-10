-- Dispatch HQ — audit follow-ups (Nov 2026)
-- Apply after 20261110_security_hardening.sql, as `audit_followups`. Idempotent: safe to re-run.
--
--  1. Enrollment verification: commissions and the VOF bonus only count facilities the
--     owner has verified (facilities.vof_verified_at)
--  2. Reps can only change call-working fields on their leads
--  3. Google Maps key is readable by the service role only (the lead-sweep Edge Function)
--  4. Audition form: per-IP / per-contact / global rate limits, and an hourly upload cap
--  5. RLS policies evaluate auth.uid() / dhq_*() once per statement instead of per row
--  6. Supporting indexes and the monthly sweep call cap setting

begin;

-- ---------------------------------------------------------------------------
-- 1. Enrollment verification
--    A rep could mark every dealt lead vendor_on_file with made-up contact details,
--    locking commission credit and earning the Fast-Start bonus. Credit now needs the
--    owner's verification stamp. Enrollments that were already credited stay credited.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'facilities' and column_name = 'vof_verified_at') then
    alter table public.facilities
      add column vof_verified_at timestamptz,
      add column vof_verified_by uuid references auth.users(id) on delete set null;
    -- One-time backfill; user triggers are skipped so nothing else is recomputed.
    alter table public.facilities disable trigger user;
    update public.facilities
       set vof_verified_at = coalesce(enrolled_at, closed_at, now())
     where closed_by is not null and vendor_on_file;
    alter table public.facilities enable trigger user;
  end if;
end $$;

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
  v_in public.facilities%rowtype;
begin
  -- Employees (1099 reps): skipped for nested updates made by fn_facility_operator_group_lock.
  if v_role = 'employee' and pg_trigger_depth() = 1 then
    if tg_op = 'INSERT' then
      new.closed_by := null;
      new.closed_at := null;
      new.operator_group := null;
      new.vof_verified_at := null;
      new.vof_verified_by := null;
      if new.assigned_to is distinct from v_uid then
        new.assigned_to := null;
      end if;
    else
      -- Start from the stored row and take only the fields a rep works during a call.
      -- Identity (name, phone, address, place_id), attribution, operator_group and the
      -- verification stamp are the owner's.
      v_in := new;
      new := old;
      new.call_status    := v_in.call_status;
      new.priority       := v_in.priority;
      new.follow_up_date := v_in.follow_up_date;
      new.contact_name   := v_in.contact_name;
      new.current_vendor := v_in.current_vendor;
      new.pain_points    := v_in.pain_points;
      new.notes          := v_in.notes;
      new.updated_at     := v_in.updated_at;
      if old.assigned_to is null and v_in.assigned_to = v_uid then
        new.assigned_to := v_uid;
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

  -- Verification stamp: record who verified; clearing the date clears the verifier.
  if new.vof_verified_at is null then
    new.vof_verified_by := null;
  elsif new.vof_verified_by is null then
    new.vof_verified_by := v_uid;
  end if;

  return new;
end;
$$;

create or replace view public.rep_commissions
with (security_invoker = true) as
select rep_id, facility_id, facility_name, dispatch_id, coordination_fee_usd, requested_at, month, trail_usd, bounty_usd
  from (
    select f.closed_by as rep_id,
           f.id as facility_id,
           f.name as facility_name,
           d.id as dispatch_id,
           d.coordination_fee_usd,
           d.requested_at,
           to_char(coalesce(d.completed_at, d.requested_at), 'YYYY-MM') as month,
           round(d.coordination_fee_usd * (select value::numeric from public.app_settings where key = 'commission_percent') / 100, 2) as trail_usd,
           case when row_number() over (partition by f.id order by d.requested_at) = 1
                then (select value::numeric from public.app_settings where key = 'commission_bounty_usd')
                else 0::numeric end as bounty_usd
      from public.facilities f
      join public.dispatches d on d.facility_id = f.id
     where f.closed_by is not null
       and f.vof_verified_at is not null
       and d.fee_collected = true
       and d.status = 'approved'
       and d.requested_at <= coalesce(f.closed_at, now())
             + make_interval(months => (select value::integer from public.app_settings where key = 'commission_window_months'))
  ) x
 where rep_id = (select auth.uid()) or (select public.dhq_is_owner());

create or replace view public.rep_vof_milestones
with (security_invoker = true) as
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
       and f.vof_verified_at is not null
       and nullif(btrim(f.contact_name), '') is not null
       and nullif(btrim(f.current_vendor), '') is not null
     group by f.closed_by
  ) x
 where rep_id = (select auth.uid()) or (select public.dhq_is_owner());

revoke all on public.rep_commissions, public.rep_vof_milestones from anon;
revoke insert, update, delete, truncate, references, trigger on public.rep_commissions, public.rep_vof_milestones from authenticated;
grant select on public.rep_commissions, public.rep_vof_milestones to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Google Maps key: service role only
--    Previously any script running in the owner's browser session could read the key.
--    The lead-sweep Edge Function now verifies the caller is the owner and then reads
--    the key with its service-role client.
-- ---------------------------------------------------------------------------
create or replace function public.dhq_google_maps_key()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'service role only';
  end if;
  select decrypted_secret into v from vault.decrypted_secrets where name = 'google_maps_api_key' limit 1;
  return v;
end;
$$;
revoke execute on function public.dhq_google_maps_key() from public, anon, authenticated;
grant execute on function public.dhq_google_maps_key() to service_role;

-- ---------------------------------------------------------------------------
-- 4. Audition form rate limits
-- ---------------------------------------------------------------------------
alter table public.rep_candidates add column if not exists submit_ip_hash text;
create index if not exists idx_rep_candidates_created on public.rep_candidates (created_at desc);

create or replace function public.fn_rep_candidate_submit_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_headers json;
  v_ip text;
begin
  -- Only web callers that are not the owner are restricted.
  if coalesce(auth.role(), '') not in ('anon', 'authenticated') or public.dhq_is_owner() then
    return new;
  end if;

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  v_ip := nullif(btrim(coalesce(v_headers ->> 'cf-connecting-ip', split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1))), '');
  new.submit_ip_hash := case when v_ip is null then null else md5('dhq-audition:' || v_ip) end;

  if (new.submit_ip_hash is not null and
        (select count(*) from public.rep_candidates c
          where c.submit_ip_hash = new.submit_ip_hash and c.created_at > now() - interval '1 hour') >= 5)
     or (select count(*) from public.rep_candidates c
          where c.created_at > now() - interval '24 hours'
            and ((nullif(btrim(new.email), '') is not null and lower(btrim(c.email)) = lower(btrim(new.email)))
              or (nullif(btrim(new.phone), '') is not null and c.phone = new.phone))) >= 3
     or (select count(*) from public.rep_candidates c
          where c.submit_ip_hash is not null and c.created_at > now() - interval '1 hour') >= 40 then
    raise exception 'Too many audition submissions right now. Please try again later.' using errcode = 'P0001';
  end if;

  new.id := gen_random_uuid();
  new.created_at := now();
  new.notes := null;                                    -- owner's field
  new.score := least(100, greatest(0, coalesce(new.score, 50)));
  if length(coalesce(new.score_breakdown, '{}'::jsonb)::text) > 1000 then
    new.score_breakdown := '{}'::jsonb;
  end if;
  -- Recording: an object in the private rep-auditions bucket, or an https link.
  if new.voice_sample_url is not null
     and new.voice_sample_url !~ '^auditions/[A-Za-z0-9._-]+$'
     and new.voice_sample_url !~* '^https://[^[:space:]]+$' then
    new.voice_sample_url := null;
  end if;
  new.status := case when new.voice_sample_url is null then 'new' else 'auditioned' end;
  if new.profile_url is not null and new.profile_url !~* '^https://[^[:space:]]+$' then
    new.profile_url := null;
  end if;
  return new;
end;
$$;
revoke all on function public.fn_rep_candidate_submit_guard() from public, anon, authenticated;

-- Hourly cap on anonymous recordings (3 MB each) so the bucket can't be filled by a script.
create or replace function public.dhq_audition_upload_ok()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*) < 40 from storage.objects
   where bucket_id = 'rep-auditions' and created_at > now() - interval '1 hour';
$$;
revoke execute on function public.dhq_audition_upload_ok() from public;
grant execute on function public.dhq_audition_upload_ok() to anon, authenticated;

drop policy if exists "rep_auditions_public_upload" on storage.objects;
create policy "rep_auditions_public_upload"
  on storage.objects
  for insert
  to anon, authenticated
  with check ( bucket_id = 'rep-auditions'
               and (storage.foldername(name))[1] = 'auditions'
               and (select public.dhq_audition_upload_ok()) );

-- ---------------------------------------------------------------------------
-- 5. RLS: evaluate auth.uid() and dhq_*() once per statement
--    Rewrites each Dispatch HQ policy in place, wrapping the calls in a scalar
--    sub-select so Postgres caches them instead of re-running them for every row.
--    Already-wrapped calls are left alone.
-- ---------------------------------------------------------------------------
do $$
declare
  p record;
  v_using text;
  v_check text;
  v_sql text;
begin
  for p in
    select tablename, policyname, qual, with_check
      from pg_policies
     where schemaname = 'public'
       and tablename in ('app_settings', 'dispatch_staff', 'dispatches', 'facilities', 'outreach_log',
                         'techs', 'lead_candidates', 'tech_candidates', 'lead_chain_blocklist',
                         'tech_chain_blocklist', 'lead_sweeps', 'rep_candidates', 'rep_payouts')
  loop
    v_using := regexp_replace(p.qual, '(?<!SELECT )(?<!public\.)\m(auth\.uid|dhq_is_owner|dhq_is_staff|dhq_can_close|dhq_jobs_scope)\(\)', '(select \1())', 'g');
    v_check := regexp_replace(p.with_check, '(?<!SELECT )(?<!public\.)\m(auth\.uid|dhq_is_owner|dhq_is_staff|dhq_can_close|dhq_jobs_scope)\(\)', '(select \1())', 'g');
    if v_using is distinct from p.qual or v_check is distinct from p.with_check then
      v_sql := format('alter policy %I on public.%I', p.policyname, p.tablename)
               || coalesce(' using (' || v_using || ')', '')
               || coalesce(' with check (' || v_check || ')', '');
      execute v_sql;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Indexes and settings
-- ---------------------------------------------------------------------------
create index if not exists idx_dispatches_assigned_to on public.dispatches (assigned_to);
create index if not exists idx_outreach_contacted_at on public.outreach_log (contacted_at desc);
create index if not exists idx_facilities_unverified on public.facilities (closed_by)
  where vendor_on_file and vof_verified_at is null;

insert into public.app_settings (key, value) values ('sweep_monthly_call_cap', '1000')
on conflict (key) do nothing;

commit;
