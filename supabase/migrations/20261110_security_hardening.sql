-- Dispatch HQ — security hardening from the Nov 2026 audit
-- Applied to the live project as `security_hardening`.
-- Idempotent: safe to re-run.
--
--  1. dispatch_staff: self-signup rows can no longer pre-set privileged/onboarding fields
--  2. rep_candidates: public (audition.html) submissions are sanitised server-side
--  3. dispatches: reps can only open dispatches on facilities in their own book
--  4. anon loses table privileges it never needed (RLS already blocked it; defence in depth)

begin;

-- ---------------------------------------------------------------------------
-- 1. dispatch_staff self-signup guard
--    dstaff_insert lets any signed-in user insert their own row with role 'pending',
--    but did not constrain the other columns. A new signup could therefore pre-set
--    is_primary (row becomes undeletable from the app and counts as "onboarded"),
--    jobs_scope 'all' (sees every dispatch once approved), agreement_signed_at /
--    w9_received_at (skips the onboarding gate), or another person's email.
-- ---------------------------------------------------------------------------
create or replace function public.fn_dispatch_staff_signup_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Owner, service role and the SQL editor pass through.
  if auth.uid() is null or public.dhq_is_owner() then
    return new;
  end if;
  new.user_id := auth.uid();
  new.role := 'pending';
  new.is_primary := false;
  new.jobs_scope := 'assigned';
  new.agreement_signed_at := null;
  new.w9_received_at := null;
  new.payout_method := null;
  new.last_active_at := null;
  -- The email shown to the owner is the one the account actually signed up with.
  new.email := coalesce(nullif(auth.jwt() ->> 'email', ''), new.email);
  new.full_name := nullif(left(btrim(coalesce(new.full_name, '')), 120), '');
  new.phone := nullif(left(btrim(coalesce(new.phone, '')), 40), '');
  return new;
end;
$$;
revoke all on function public.fn_dispatch_staff_signup_guard() from public, anon, authenticated;

drop trigger if exists trg_dispatch_staff_signup_guard on public.dispatch_staff;
create trigger trg_dispatch_staff_signup_guard
  before insert on public.dispatch_staff
  for each row execute function public.fn_dispatch_staff_signup_guard();

-- ---------------------------------------------------------------------------
-- 2. rep_candidates public-submit guard
--    The audition form is open to the internet. Applicants could set their own
--    score (unbounded), owner-only notes, an arbitrary score_breakdown blob, and
--    any URL scheme for the recording / profile link.
-- ---------------------------------------------------------------------------
create or replace function public.fn_rep_candidate_submit_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Only web callers that are not the owner are restricted.
  if coalesce(auth.role(), '') not in ('anon', 'authenticated') or public.dhq_is_owner() then
    return new;
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

drop trigger if exists trg_rep_candidate_submit_guard on public.rep_candidates;
create trigger trg_rep_candidate_submit_guard
  before insert on public.rep_candidates
  for each row execute function public.fn_rep_candidate_submit_guard();

-- ---------------------------------------------------------------------------
-- 3. Reps may only request dispatches on facilities assigned to / closed by them.
--    (Previously any facility id was accepted as long as assigned_to was the rep.)
-- ---------------------------------------------------------------------------
drop policy if exists dispatches_insert on public.dispatches;
create policy dispatches_insert on public.dispatches for insert
  with check (public.dhq_is_staff() and (
           public.dhq_can_close()
           or public.dhq_jobs_scope() = 'all'
           or (assigned_to = auth.uid()
               and exists (select 1 from public.facilities f
                            where f.id = dispatches.facility_id
                              and (f.assigned_to = auth.uid() or f.closed_by = auth.uid())))));

-- ---------------------------------------------------------------------------
-- 4. anon never needs direct access to Dispatch HQ tables or views.
--    (audition.html only INSERTs into rep_candidates, which keeps its grant.)
-- ---------------------------------------------------------------------------
revoke all on public.app_settings, public.dispatch_staff, public.dispatches, public.facilities,
  public.outreach_log, public.techs, public.lead_candidates, public.tech_candidates,
  public.lead_chain_blocklist, public.tech_chain_blocklist, public.tech_compliance_board
  from anon;

commit;
