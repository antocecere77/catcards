-- ============================================================================
--  CatCards — Clan Fase 4: modello CARD-CENTRICO (prestito carte tra clan)
--  Ora l'unità è la CARTA, non la persona:
--    · guidi al più 1 clan (leader_id)
--    · puoi mettere tue carte in QUALSIASI clan (il tuo o altrui)
--    · una carta sta in 1 solo clan alla volta
--    · "membro" = chi ha carte nel roster
--  Richiesta e invito portano una CARTA specifica.
--  Da lanciare in Supabase → SQL Editor DOPO clan_migration_1..8.sql.
-- ============================================================================

-- una carta in un solo clan (globale)
alter table public.clan_roster drop constraint if exists clan_roster_serial_key;
alter table public.clan_roster add  constraint clan_roster_serial_key unique (serial);

-- le richieste portano una carta
alter table public.clan_applications add column if not exists serial text;

-- ---------- crea clan: uno per CAPO (non più uno per persona) ----------
create or replace function public.clan_create(p_name text, p_emblem text, p_owner text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id bigint;
begin
  if v_uid is null then raise exception 'login richiesto'; end if;
  if exists (select 1 from clans where leader_id = v_uid) then raise exception 'guidi già un clan'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'nome mancante'; end if;
  insert into clans(name, emblem, leader_id) values (left(trim(p_name), 24), coalesce(nullif(p_emblem, ''), '🛡️'), v_uid) returning id into v_id;
  return v_id;
end $$;

-- ---------- sciogli il clan (solo il capo). Le carte tornano ai proprietari (cascade). ----------
create or replace function public.clan_leave()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint;
begin
  select id into v_clan from clans where leader_id = v_uid;
  if v_clan is null then return; end if;
  delete from clans where id = v_clan;   -- cascade: roster, inviti, richieste
end $$;

-- ---------- richiedi di entrare con una TUA carta ----------
drop function if exists public.clan_apply(bigint, text);
create or replace function public.clan_apply(p_clan bigint, p_serial text, p_owner text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'login richiesto'; end if;
  if not exists (select 1 from clans where id = p_clan and open) then raise exception 'clan chiuso: solo su invito'; end if;
  if not exists (select 1 from cards where serial = p_serial and owner_id = v_uid) then raise exception 'non è una tua carta'; end if;
  if exists (select 1 from clan_roster where serial = p_serial) then raise exception 'questa carta è già in un clan'; end if;
  insert into clan_applications(clan_id, user_id, owner_name, serial) values (p_clan, v_uid, p_owner, p_serial)
  on conflict (clan_id, user_id) do update set serial = excluded.serial, owner_name = excluded.owner_name;
end $$;

-- ---------- il capo accetta: la carta entra nel roster ----------
create or replace function public.clan_respond_application(p_app bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_serial text; v_by uuid;
begin
  select clan_id, serial, user_id into v_clan, v_serial, v_by from clan_applications where id = p_app;
  if v_clan is null then return; end if;
  if not exists (select 1 from clans where id = v_clan and leader_id = v_uid) then raise exception 'solo il capo'; end if;
  if p_accept and v_serial is not null
     and exists (select 1 from cards where serial = v_serial and owner_id = v_by)
     and not exists (select 1 from clan_roster where serial = v_serial)
     and (select count(*) from clan_roster where clan_id = v_clan) < 20 then
    insert into clan_roster(clan_id, serial, added_by, pos)
    values (v_clan, v_serial, v_by, coalesce((select max(pos) from clan_roster where clan_id = v_clan), 0) + 1);
  end if;
  delete from clan_applications where id = p_app;
end $$;

-- ---------- invito per carta (senza più il vincolo "utente già in un clan") ----------
create or replace function public.clan_invite(p_clan bigint, p_to uuid, p_serial text, p_from text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from clans where id = p_clan and leader_id = auth.uid()) then raise exception 'solo il capo'; end if;
  if p_serial is not null and not exists (select 1 from cards where serial = p_serial and owner_id = p_to) then raise exception 'carta non valida'; end if;
  if exists (select 1 from clan_roster where serial = p_serial) then raise exception 'carta già in un clan'; end if;
  insert into clan_invites(clan_id, to_user_id, serial, from_name) values (p_clan, p_to, p_serial, p_from)
  on conflict (clan_id, to_user_id) do update set serial = excluded.serial, from_name = excluded.from_name;
end $$;

-- ---------- l'invitato accetta: la carta va nel roster (niente membership) ----------
create or replace function public.clan_respond_invite(p_inv bigint, p_accept boolean, p_owner text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_to uuid; v_serial text;
begin
  select clan_id, to_user_id, serial into v_clan, v_to, v_serial from clan_invites where id = p_inv;
  if v_clan is null or v_to <> v_uid then return; end if;
  if p_accept and v_serial is not null
     and exists (select 1 from cards where serial = v_serial and owner_id = v_uid)
     and not exists (select 1 from clan_roster where serial = v_serial)
     and (select count(*) from clan_roster where clan_id = v_clan) < 20 then
    insert into clan_roster(clan_id, serial, added_by, pos)
    values (v_clan, v_serial, v_uid, coalesce((select max(pos) from clan_roster where clan_id = v_clan), 0) + 1);
  end if;
  delete from clan_invites where id = p_inv;
end $$;

-- ---------- aggiungi una TUA carta al clan che GUIDI ----------
create or replace function public.clan_roster_add(p_serial text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint;
begin
  select id into v_clan from clans where leader_id = v_uid;
  if v_clan is null then raise exception 'non guidi un clan'; end if;
  if not exists (select 1 from cards where serial = p_serial and owner_id = v_uid) then raise exception 'non è una tua carta'; end if;
  if exists (select 1 from clan_roster where serial = p_serial) then raise exception 'carta già in un clan'; end if;
  if (select count(*) from clan_roster where clan_id = v_clan) >= 20 then raise exception 'roster pieno (20)'; end if;
  insert into clan_roster(clan_id, serial, added_by, pos)
  values (v_clan, p_serial, v_uid, coalesce((select max(pos) from clan_roster where clan_id = v_clan), 0) + 1);
end $$;

-- ---------- togli una carta: il proprietario (added_by) o il capo del clan dove sta ----------
create or replace function public.clan_roster_remove(p_serial text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_by uuid;
begin
  select clan_id, added_by into v_clan, v_by from clan_roster where serial = p_serial;
  if v_clan is null then return; end if;
  if v_uid <> v_by and not exists (select 1 from clans where id = v_clan and leader_id = v_uid) then raise exception 'solo il proprietario o il capo'; end if;
  delete from clan_roster where serial = p_serial;
  perform clan_compact(v_clan);
end $$;

-- ---------- kick: il capo rimuove tutte le carte di un proprietario dal suo clan ----------
create or replace function public.clan_kick(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint;
begin
  select id into v_clan from clans where leader_id = v_uid;
  if v_clan is null then raise exception 'solo il capo'; end if;
  delete from clan_roster where clan_id = v_clan and added_by = p_user;
  perform clan_compact(v_clan);
end $$;

-- ---------- sfoglia i clan: member_count = proprietari distinti nel roster ----------
drop function if exists public.clan_browse(text, int, int);
create or replace function public.clan_browse(p_search text, p_limit int, p_offset int)
returns table(id bigint, name text, emblem text, open boolean, points int, member_count int, roster_count int)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.emblem, c.open, coalesce(c.points,0),
    (select count(distinct r.added_by)::int from clan_roster r where r.clan_id = c.id),
    (select count(*)::int from clan_roster r where r.clan_id = c.id)
  from clans c
  where p_search is null or p_search = '' or c.name ilike '%' || p_search || '%'
  order by coalesce(c.points,0) desc, c.created_at desc
  limit coalesce(p_limit, 20) offset coalesce(p_offset, 0);
$$;
grant execute on function public.clan_browse(text,int,int) to anon, authenticated;

-- ---------- cerca giocatori con almeno una carta libera (invitabili) ----------
create or replace function public.player_search(p_search text)
returns table(user_id uuid, owner text)
language sql stable security definer set search_path = public as $$
  select c.owner_id, max(c.owner)
  from cards c
  where c.owner_id is not null and c.owner_id <> auth.uid()
    and (p_search is null or p_search = '' or c.owner ilike '%' || p_search || '%')
    and exists (select 1 from cards cc where cc.owner_id = c.owner_id and not exists (select 1 from clan_roster r where r.serial = cc.serial))
  group by c.owner_id
  order by max(c.owner)
  limit 40;
$$;
grant execute on function public.player_search(text) to anon, authenticated;

grant execute on function public.clan_create(text,text,text)              to authenticated;
grant execute on function public.clan_leave()                             to authenticated;
grant execute on function public.clan_apply(bigint,text,text)             to authenticated;
grant execute on function public.clan_respond_application(bigint,boolean) to authenticated;
grant execute on function public.clan_invite(bigint,uuid,text,text)       to authenticated;
grant execute on function public.clan_respond_invite(bigint,boolean,text) to authenticated;
grant execute on function public.clan_roster_add(text)                    to authenticated;
grant execute on function public.clan_roster_remove(text)                 to authenticated;
grant execute on function public.clan_kick(uuid)                          to authenticated;

-- ---------- fine migrazione Clan Fase 4 (card-centrico) ----------
