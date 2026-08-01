-- ============================================================================
--  CatCards — Clan Fase 3c-ter: SCHEDULE AUTOMATICO (pg_cron)
--  Il mondo si muove da solo: rendita giornaliera + ondate di conquiste dei bot,
--  eseguite dentro Postgres senza client e senza costi.
--  Da lanciare in Supabase → SQL Editor DOPO clan_migration_1..7.sql.
--
--  NOTA: serve l'estensione pg_cron. Se la CREATE qui sotto dà errore,
--  abilitala prima da Dashboard → Database → Extensions → cerca "pg_cron".
-- ============================================================================

create extension if not exists pg_cron;

-- ---------- worker interni (NIENTE gate admin): li chiama solo lo scheduler ----------

-- rendita giornaliera: punti-clan + rendita condivisa ai proprietari (come clan_zone_daily, senza check admin)
create or replace function public._zone_daily_run()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update clans c set points = coalesce(c.points,0) + agg.pts
  from (select owner_clan, sum(case when is_capital then 6 else 2 end) as pts
        from clan_zones where owner_clan is not null group by owner_clan) agg
  where c.id = agg.owner_clan;

  with clanz as (
    select owner_clan as clan_id, sum(case when is_capital then 6 else 2 end) as val
    from clan_zones where owner_clan is not null group by owner_clan
  ),
  rc as (select clan_id, count(*) as cnt from clan_roster group by clan_id),
  per_card as (
    select r.serial, greatest(1, round(cz.val::numeric / nullif(rc.cnt, 0)))::int as per
    from clan_roster r join clanz cz on cz.clan_id = r.clan_id join rc on rc.clan_id = r.clan_id
  ),
  per_owner as (
    select c.owner_id, sum(pc.per)::int as pts
    from per_card pc join cards c on c.serial = pc.serial
    where c.owner_id is not null group by c.owner_id
  )
  update profiles pr set points = coalesce(pr.points,0) + po.pts, updated_at = now()
  from per_owner po where pr.user_id = po.owner_id;

  select count(*) into n from clan_zones where owner_clan is not null;
  return n;
end $$;

-- ondata di conquiste dei bot (come sim_zone_wars, senza check admin)
create or replace function public._zone_wars_run(p_rounds int)
returns int language plpgsql security definer set search_path = public as $$
declare
  att record; z clan_zones%rowtype; ownerclan bigint; a_ser text[]; b_ser text[]; r jsonb; awon boolean; done int := 0; k int; dz int;
begin
  for k in 1..greatest(1, coalesce(p_rounds, 6)) loop
    select c.id, c.name into att from clans c
      where not exists (select 1 from profiles p where p.user_id = c.leader_id)
      order by random() limit 1;
    if att.id is null then exit; end if;
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
    if ownerclan is null then awon := true;
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
    done := done + 1;
  end loop;
  return done;
end $$;

-- solo il database (pg_cron) può eseguirli: niente accesso ai client
revoke all on function public._zone_daily_run()   from public;
revoke all on function public._zone_wars_run(int)  from public;

-- ---------- pianificazione (orari in UTC) ----------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'catcards_zone_daily') then perform cron.unschedule('catcards_zone_daily'); end if;
  if exists (select 1 from cron.job where jobname = 'catcards_zone_wars')  then perform cron.unschedule('catcards_zone_wars');  end if;
end $$;

-- rendita giornaliera: ogni giorno alle 06:00 UTC
select cron.schedule('catcards_zone_daily', '0 6 * * *', $$ select public._zone_daily_run(); $$);
-- conquiste dei bot: ogni 4 ore, 6 scontri per ondata
select cron.schedule('catcards_zone_wars', '0 */4 * * *', $$ select public._zone_wars_run(6); $$);

-- Per vedere i lavori pianificati:      select jobname, schedule, active from cron.job;
-- Per vedere gli ultimi esiti:          select jobname, status, return_message, start_time from cron.job_run_details order by start_time desc limit 10;
-- ---------- fine migrazione Clan 3c-ter ----------
