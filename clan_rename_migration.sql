-- ============================================================================
--  CatCards — Clan: rinomina (solo il capo). Il nome vive in clans.name, quindi
--  la modifica si riflette ovunque (bacheca, mappa, registri, carte nei clan).
--  Da lanciare in Supabase → SQL Editor.
-- ============================================================================
create or replace function public.clan_rename(p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'nome mancante'; end if;
  update clans set name = left(trim(p_name), 24) where leader_id = auth.uid();
end $$;
grant execute on function public.clan_rename(text) to authenticated;
-- ---------- fine ----------
