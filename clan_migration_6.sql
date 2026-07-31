-- ============================================================================
--  CatCards — Clan Fase 3c: MAPPA A ZONE (territori)
--  Da lanciare in Supabase → SQL Editor DOPO clan_migration_1..5.sql.
--  Board 3x3: la casella centrale (Piazza Grande) vale 3x e si raggiunge solo
--  dalle confinanti. Conquista per confine. Zero costi IA.
-- ============================================================================

-- ---------- tabella delle zone (board fisso) ----------
create table if not exists public.clan_zones (
  id              int primary key,
  code            text not null,
  is_capital      boolean default false,
  points_per_day  int default 1,
  neighbors       int[] not null,
  owner_clan      bigint references clans(id) on delete set null   -- se il clan si scioglie, la zona torna libera
);
alter table public.clan_zones enable row level security;
drop policy if exists clan_zones_read on public.clan_zones;
create policy clan_zones_read on public.clan_zones for select using (true);

-- ---------- registro delle battaglie per zona (log + cooldown) ----------
create table if not exists public.zone_wars (
  id            bigint generated always as identity primary key,
  zone          int,
  attacker_clan bigint,
  defender_clan bigint,
  won           boolean,
  created_at    timestamptz default now()
);
alter table public.zone_wars enable row level security;
drop policy if exists zone_wars_read on public.zone_wars;
create policy zone_wars_read on public.zone_wars for select using (true);

-- ---------- seed del board (admin, idempotente) ----------
create or replace function public.admin_seed_zones()
returns int language plpgsql security definer set search_path = public as $$
declare z record; n int := 0;
begin
  if (auth.jwt() ->> 'email') <> 'antocecere77@gmail.com' then raise exception 'solo admin'; end if;
  if exists (select 1 from clan_zones) then return 0; end if;
  insert into clan_zones(id, code, is_capital, points_per_day, neighbors) values
    (0,'porto',    false,1,'{1,3}'),
    (1,'tetti',    false,1,'{0,2,4}'),
    (2,'giardino', false,1,'{1,5}'),
    (3,'vicolo',   false,1,'{0,4,6}'),
    (4,'piazza',   true, 3,'{1,3,5,7}'),
    (5,'mercato',  false,1,'{2,4,8}'),
    (6,'parco',    false,1,'{3,7}'),
    (7,'fontana',  false,1,'{4,6,8}'),
    (8,'molo',     false,1,'{5,7}');
  -- colora subito la mappa: assegna le zone non-capitali a clan a caso (~70%)
  for z in select id from clan_zones where not is_capital loop
    if random() < 0.7 then
      update clan_zones set owner_clan = (select id from clans order by random() limit 1) where id = z.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
grant execute on function public.admin_seed_zones() to authenticated;

-- ---------- la mappa da disegnare (zone + proprietario) ----------
create or replace function public.clan_zones_map()
returns table(id int, code text, is_capital boolean, ppd int, neighbors int[], owner_clan bigint, owner_name text, owner_emblem text)
language sql stable security definer set search_path = public as $$
  select z.id, z.code, z.is_capital, z.points_per_day, z.neighbors, z.owner_clan, c.name, c.emblem
  from clan_zones z left join clans c on c.id = z.owner_clan
  order by z.id;
$$;
grant execute on function public.clan_zones_map() to anon, authenticated;

-- ---------- esito di un attacco a una zona (giocatore, animato lato client) ----------
create or replace function public.clan_zone_report(p_zone int, p_won boolean, p_serials text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_att bigint; z clan_zones%rowtype; have_zones boolean;
begin
  select id into v_att from clans where leader_id = v_uid;
  if v_att is null then raise exception 'solo il capo puo attaccare'; end if;
  select * into z from clan_zones where id = p_zone;
  if z.id is null then raise exception 'zona inesistente'; end if;
  if z.owner_clan = v_att then raise exception 'zona gia tua'; end if;
  have_zones := exists (select 1 from clan_zones where owner_clan = v_att);
  if have_zones then
    if not exists (select 1 from clan_zones o where o.owner_clan = v_att and p_zone = any(o.neighbors)) then
      raise exception 'zona non confinante';
    end if;
  else
    -- primo sbarco: se non possiedi zone puoi prendere solo una zona libera (se ce ne sono)
    if z.owner_clan is not null and exists (select 1 from clan_zones where owner_clan is null) then
      raise exception 'inizia da una zona libera';
    end if;
  end if;
  if exists (select 1 from zone_wars where zone = p_zone and attacker_clan = v_att and created_at > now() - interval '15 minutes') then
    raise exception 'zona in cooldown: riprova piu tardi';
  end if;
  insert into zone_wars(zone, attacker_clan, defender_clan, won) values (p_zone, v_att, z.owner_clan, p_won);
  if p_won then
    update clan_zones set owner_clan = v_att where id = p_zone;
    update clans set points = coalesce(points,0) + (case when z.is_capital then 30 else 15 end) where id = v_att;
    if z.owner_clan is not null then update clans set points = coalesce(points,0) + 3 where id = z.owner_clan; end if;
  end if;
  if p_serials is not null then update cards set rest_until = now() + interval '1 hour' where serial = any(p_serials); end if;
end $$;
grant execute on function public.clan_zone_report(int, boolean, text[]) to authenticated;

-- ---------- ondata di conquiste dei clan-bot (admin, simulata lato server) ----------
create or replace function public.sim_zone_wars(p_rounds int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  att record; z clan_zones%rowtype; ownerclan bigint; a_ser text[]; b_ser text[]; r jsonb; awon boolean;
  results jsonb := '[]'::jsonb; done int := 0; k int; dz int;
begin
  if (auth.jwt() ->> 'email') <> 'antocecere77@gmail.com' then raise exception 'solo admin'; end if;
  for k in 1..greatest(1, coalesce(p_rounds, 6)) loop
    select c.id, c.name into att from clans c
      where not exists (select 1 from profiles p where p.user_id = c.leader_id)
      order by random() limit 1;
    if att.id is null then exit; end if;
    -- zona bersaglio: confinante con una zona del bot; se il bot non ha zone, una libera
    if exists (select 1 from clan_zones where owner_clan = att.id) then
      select * into z from clan_zones zz
        where zz.owner_clan is distinct from att.id
          and exists (select 1 from clan_zones o where o.owner_clan = att.id and zz.id = any(o.neighbors))
        order by random() limit 1;
    else
      select * into z from clan_zones zz where zz.owner_clan is null order by random() limit 1;
    end if;
    if z.id is null then continue; end if;
    if exists (select 1 from zone_wars where zone = z.id and attacker_clan = att.id and created_at > now() - interval '15 minutes') then continue; end if;
    select array_agg(serial order by pos) into a_ser from (select serial, pos from clan_roster where clan_id = att.id order by pos limit 3) x;
    if a_ser is null then continue; end if;
    ownerclan := z.owner_clan;
    if ownerclan is null then
      awon := true;
    else
      select coalesce(def_size, 3) into dz from clans where id = ownerclan;
      select array_agg(serial order by pos) into b_ser from (select serial, pos from clan_roster where clan_id = ownerclan order by pos limit dz) x;
      if b_ser is null then awon := true;
      else r := _sim_staffetta(a_ser, b_ser); awon := (r ->> 'winner') = 'A'; end if;
    end if;
    insert into zone_wars(zone, attacker_clan, defender_clan, won) values (z.id, att.id, ownerclan, awon);
    if awon then
      update clan_zones set owner_clan = att.id where id = z.id;
      update clans set points = coalesce(points,0) + (case when z.is_capital then 30 else 15 end) where id = att.id;
      if ownerclan is not null then update clans set points = coalesce(points,0) + 3 where id = ownerclan; end if;
    else
      update clans set points = coalesce(points,0) + 3 where id = att.id;
    end if;
    results := results || jsonb_build_object('att', att.name, 'zone', z.code, 'won', awon, 'cap', z.is_capital);
    done := done + 1;
  end loop;
  return jsonb_build_object('rounds', done, 'wars', results);
end $$;
grant execute on function public.sim_zone_wars(int) to authenticated;

-- ---------- rendita giornaliera: ogni zona controllata dà punti (capitale 3x) ----------
create or replace function public.clan_zone_daily()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if (auth.jwt() ->> 'email') <> 'antocecere77@gmail.com' then raise exception 'solo admin'; end if;
  update clans c set points = coalesce(c.points,0) + agg.pts
  from (select owner_clan, sum(case when is_capital then 3 else 1 end) as pts
        from clan_zones where owner_clan is not null group by owner_clan) agg
  where c.id = agg.owner_clan;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.clan_zone_daily() to authenticated;

-- ---------- log recente delle guerre per zona (per la bacheca) ----------
create or replace function public.zone_war_log(p_limit int)
returns table(created_at timestamptz, zone_code text, attacker text, won boolean, is_capital boolean)
language sql stable security definer set search_path = public as $$
  select w.created_at, z.code, ca.name, w.won, z.is_capital
  from zone_wars w
  join clan_zones z on z.id = w.zone
  left join clans ca on ca.id = w.attacker_clan
  order by w.created_at desc
  limit coalesce(p_limit, 10);
$$;
grant execute on function public.zone_war_log(int) to anon, authenticated;

-- ---------- fine migrazione Clan 3c ----------
