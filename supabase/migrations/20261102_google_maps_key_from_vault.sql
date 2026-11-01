-- Dispatch HQ — let the lead-sweep Edge Function read the Google Maps key from Vault.
-- Applied to the live project as `google_maps_key_from_vault`.
--
-- The key itself is NOT in this file. It is stored encrypted in Supabase Vault as
-- `google_maps_api_key` (set once with:
--   select vault.create_secret('<key>', 'google_maps_api_key', 'Google Places API (New) key used by the lead-sweep Edge Function');
-- and rotated with vault.update_secret). The Edge Function prefers the
-- GOOGLE_MAPS_API_KEY Edge Function secret when one is set.

create or replace function public.dhq_google_maps_key()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v text;
begin
  if not public.dhq_is_owner() then
    raise exception 'owner only';
  end if;
  select decrypted_secret into v from vault.decrypted_secrets where name = 'google_maps_api_key' limit 1;
  return v;
end;
$$;
revoke execute on function public.dhq_google_maps_key() from public, anon;
grant execute on function public.dhq_google_maps_key() to authenticated;
