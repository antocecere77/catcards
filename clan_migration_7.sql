-- ============================================================================
--  CatCards — Clan Fase 3c-bis: RENDITA CONDIVISA + valori zona aggiornati
--  Valore zona/giorno: periferica = 2, Piazza (capitale) = 6.
--  Oltre ai punti-clan, la rendita paga anche i PROPRIETARI delle carte nel
--  roster (portafoglio personale = profiles.points). Prestare una carta rende.
--  Da lanciare in Supabase → SQL Editor DOPO clan_migration_6.sql.
-- ============================================================================

-- allinea anche la colonna informativa (usata per mostrare "rende N/giorno")
update public.clan_zones set points_per_day = case when is_capital then 6 else 2 end;

create or replace function public.clan_zone_daily()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if (auth.jwt() ->> 'email') <> 'antocecere77@gmail.com' then raise exception 'solo admin'; end if;

  -- 1) punti-clan (classifica): periferica 2, Piazza 6
  update clans c set points = coalesce(c.points,0) + agg.pts
  from (select owner_clan, sum(case when is_capital then 6 else 2 end) as pts
        from clan_zones where owner_clan is not null group by owner_clan) agg
  where c.id = agg.owner_clan;

  -- 2) rendita condivisa: il valore giornaliero delle zone del clan viene diviso
  --    tra le carte del roster e accreditato ai LORO proprietari (min 1 a carta).
  --    I bot non hanno profilo → non vengono pagati (join su profiles).
  with clanz as (
    select owner_clan as clan_id, sum(case when is_capital then 6 else 2 end) as val
    from clan_zones where owner_clan is not null group by owner_clan
  ),
  rc as (select clan_id, count(*) as cnt from clan_roster group by clan_id),
  per_card as (
    select r.serial, greatest(1, round(cz.val::numeric / nullif(rc.cnt, 0)))::int as per
    from clan_roster r
    join clanz cz on cz.clan_id = r.clan_id
    join rc on rc.clan_id = r.clan_id
  ),
  per_owner as (
    select c.owner_id, sum(pc.per)::int as pts
    from per_card pc join cards c on c.serial = pc.serial
    where c.owner_id is not null
    group by c.owner_id
  )
  update profiles pr set points = coalesce(pr.points,0) + po.pts, updated_at = now()
  from per_owner po where pr.user_id = po.owner_id;

  select count(*) into n from clan_zones where owner_clan is not null;
  return n;
end $$;
grant execute on function public.clan_zone_daily() to authenticated;

-- ---------- fine migrazione Clan 3c-bis ----------
