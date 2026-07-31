-- ============================================================================
--  CatCards — Clan v2: scala, invito-per-carta, aperto/chiuso, espelli
--  Da lanciare in Supabase → SQL Editor DOPO clan_migration.sql.
-- ============================================================================

-- nuove colonne
alter table public.clans        add column if not exists open boolean default true;   -- accetta richieste dalla bacheca?
alter table public.clan_invites add column if not exists serial text;                 -- l'invito porta una carta specifica

-- ---------- sfoglia i clan (ricerca + paginazione + conteggi) ----------
create or replace function public.clan_browse(p_search text, p_limit int, p_offset int)
returns table(id bigint, name text, emblem text, open boolean, member_count int, roster_count int)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.emblem, c.open,
    (select count(*)::int from clan_members m where m.clan_id = c.id),
    (select count(*)::int from clan_roster  r where r.clan_id = c.id)
  from clans c
  where p_search is null or p_search = '' or c.name ilike '%' || p_search || '%'
  order by c.created_at desc
  limit coalesce(p_limit, 20) offset coalesce(p_offset, 0);
$$;
grant execute on function public.clan_browse(text,int,int) to anon, authenticated;

-- ---------- cerca giocatori liberi da invitare (distinti, non in un clan) ----------
create or replace function public.player_search(p_search text)
returns table(user_id uuid, owner text)
language sql stable security definer set search_path = public as $$
  select c.owner_id, max(c.owner)
  from cards c
  where c.owner_id is not null
    and c.owner_id not in (select user_id from clan_members)
    and (p_search is null or p_search = '' or c.owner ilike '%' || p_search || '%')
  group by c.owner_id
  order by max(c.owner)
  limit 40;
$$;
grant execute on function public.player_search(text) to anon, authenticated;

-- ---------- il capo apre/chiude il clan ----------
create or replace function public.clan_set_open(p_open boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update clans set open = p_open where leader_id = auth.uid();
end $$;
grant execute on function public.clan_set_open(boolean) to authenticated;

-- ---------- il capo espelle un membro (le sue carte escono dal roster) ----------
create or replace function public.clan_kick(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint;
begin
  select id into v_clan from clans where leader_id = v_uid;
  if v_clan is null then raise exception 'solo il capo'; end if;
  if p_user = v_uid then return; end if;                    -- il capo usa «sciogli», non si autoespelle
  delete from clan_members where clan_id = v_clan and user_id = p_user;
  delete from clan_roster  where clan_id = v_clan and added_by = p_user;
  perform clan_compact(v_clan);
end $$;
grant execute on function public.clan_kick(uuid) to authenticated;

-- ---------- richiedi (bacheca): solo se il clan è APERTO ----------
create or replace function public.clan_apply(p_clan bigint, p_owner text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'login richiesto'; end if;
  if exists (select 1 from clan_members where user_id = v_uid) then raise exception 'sei già in un clan'; end if;
  if not exists (select 1 from clans where id = p_clan and open) then raise exception 'clan chiuso: solo su invito'; end if;
  insert into clan_applications(clan_id, user_id, owner_name) values (p_clan, v_uid, p_owner)
  on conflict (clan_id, user_id) do nothing;
end $$;
grant execute on function public.clan_apply(bigint,text) to authenticated;

-- ---------- invito: ora porta una CARTA specifica dell'utente ----------
drop function if exists public.clan_invite(bigint, uuid, text);
create or replace function public.clan_invite(p_clan bigint, p_to uuid, p_serial text, p_from text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from clans where id = p_clan and leader_id = auth.uid()) then raise exception 'solo il capo'; end if;
  if exists (select 1 from clan_members where user_id = p_to) then raise exception 'utente già in un clan'; end if;
  if p_serial is not null and not exists (select 1 from cards where serial = p_serial and owner_id = p_to) then raise exception 'carta non valida'; end if;
  insert into clan_invites(clan_id, to_user_id, serial, from_name) values (p_clan, p_to, p_serial, p_from)
  on conflict (clan_id, to_user_id) do update set serial = excluded.serial, from_name = excluded.from_name;
end $$;
grant execute on function public.clan_invite(bigint,uuid,text,text) to authenticated;

-- ---------- l'invitato accetta: entra nel clan + la carta invitata va nel roster ----------
create or replace function public.clan_respond_invite(p_inv bigint, p_accept boolean, p_owner text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_to uuid; v_serial text;
begin
  select clan_id, to_user_id, serial into v_clan, v_to, v_serial from clan_invites where id = p_inv;
  if v_clan is null or v_to <> v_uid then return; end if;
  if p_accept and not exists (select 1 from clan_members where user_id = v_uid) then
    if (select count(*) from clan_members where clan_id = v_clan) >= 8 then raise exception 'clan pieno (8)'; end if;
    insert into clan_members(clan_id, user_id, owner_name) values (v_clan, v_uid, p_owner);
    if v_serial is not null
       and exists (select 1 from cards where serial = v_serial and owner_id = v_uid)
       and (select count(*) from clan_roster where clan_id = v_clan) < 20 then
      insert into clan_roster(clan_id, serial, added_by, pos)
      values (v_clan, v_serial, v_uid, coalesce((select max(pos) from clan_roster where clan_id = v_clan), 0) + 1)
      on conflict (clan_id, serial) do nothing;
    end if;
    delete from clan_applications where user_id = v_uid;
  end if;
  delete from clan_invites where id = p_inv;
end $$;
grant execute on function public.clan_respond_invite(bigint,boolean,text) to authenticated;

-- ---------- fine migrazione Clan v2 ----------
