-- ============================================================================
--  CatCards — Award Fase 3, Passo 3 (parte 1): nuovi premi SETTIMANALI
--  Da lanciare in Supabase → SQL Editor DOPO le migrazioni 1-4.
--  Aggiunge a award_standings: Ammazza-giganti, Beniamino, Debuttante,
--  Astro nascente, Pantofolaio. Si popolano dai dati registrati da adesso.
-- ============================================================================
create or replace function public.award_standings(p_start timestamptz, p_end timestamptz)
returns table(award text, rank int, serial text, name text, owner text, value numeric, points int)
language sql stable security definer set search_path = public as $$
  with ev as (
    select winner_serial as serial, created_at, 1 as win from matches where created_at >= p_start and created_at < p_end
    union all
    select loser_serial  as serial, created_at, 0 as win from matches where created_at >= p_start and created_at < p_end
  ),
  names as (
    select distinct on (serial) serial, name, owner from (
      select winner_serial serial, winner_name name, winner_owner owner, created_at from matches where created_at >= p_start and created_at < p_end
      union all
      select loser_serial  serial, loser_name  name, loser_owner  owner, created_at from matches where created_at >= p_start and created_at < p_end
    ) t order by serial, created_at desc
  ),
  agg as ( select serial, sum(win) as wins, count(*) as played from ev group by serial ),
  grp as (
    select serial, win, created_at,
      row_number() over (partition by serial order by created_at)
        - row_number() over (partition by serial, win order by created_at) as g
    from ev
  ),
  streaks as ( select serial, count(*) as len from grp where win = 1 group by serial, g ),
  best as ( select serial, max(len) as streak from streaks group by serial )
  -- 🏆 MVP
  select 'mvp', r.rn::int, r.serial, n.name, n.owner, r.wins::numeric, (array[100,60,30,0,0])[r.rn]
  from (select serial, wins, row_number() over (order by wins desc, played asc) rn from agg where wins > 0) r
  join names n using (serial) where r.rn <= 5
  union all
  -- 🥊 Instancabile
  select 'instancabile', r.rn::int, r.serial, n.name, n.owner, r.played::numeric, (array[60,40,20,0,0])[r.rn]
  from (select serial, played, row_number() over (order by played desc) rn from agg) r
  join names n using (serial) where r.rn <= 5
  union all
  -- 🎯 Cecchino
  select 'cecchino', r.rn::int, r.serial, n.name, n.owner, round(r.pct, 3), (array[60,40,20,0,0])[r.rn]
  from (select serial, wins::numeric / played as pct, row_number() over (order by wins::numeric / played desc, wins desc) rn from agg where played >= 5) r
  join names n using (serial) where r.rn <= 5
  union all
  -- 🔥 Dominatore
  select 'dominatore', r.rn::int, r.serial, n.name, n.owner, r.streak::numeric, (array[60,0,0,0,0])[r.rn]
  from (select serial, streak, row_number() over (order by streak desc) rn from best where streak >= 2) r
  join names n using (serial) where r.rn <= 5
  union all
  -- 🗡️ Ammazza-giganti: l'upset più grande (vincitore con Elo più basso dello sconfitto)
  select 'ammazza', r.rn::int, r.serial, n.name, n.owner, r.gap::numeric, (array[50,0,0,0,0])[r.rn]
  from (
    select winner_serial serial, max(loser_elo - winner_elo) gap,
      row_number() over (order by max(loser_elo - winner_elo) desc) rn
    from matches
    where created_at >= p_start and created_at < p_end and winner_elo is not null and loser_elo is not null and winner_elo < loser_elo
    group by winner_serial
  ) r join names n using (serial) where r.rn <= 5
  union all
  -- ⭐ Beniamino: il più sfidato dagli altri (comparso come NON sfidante)
  select 'beniamino', r.rn::int, r.serial, n.name, n.owner, r.cnt::numeric, (array[30,0,0,0,0])[r.rn]
  from (
    select serial, count(*) cnt, row_number() over (order by count(*) desc) rn
    from (
      select winner_serial serial, challenger_serial from matches where created_at >= p_start and created_at < p_end and challenger_serial is not null
      union all
      select loser_serial  serial, challenger_serial from matches where created_at >= p_start and created_at < p_end and challenger_serial is not null
    ) t where serial <> challenger_serial
    group by serial
  ) r join names n using (serial) where r.rn <= 5
  union all
  -- 🆕 Debuttante: miglior carta creata questa settimana (per vittorie)
  select 'debuttante', r.rn::int, r.serial, cc.name, cc.owner, r.wins::numeric, (array[40,0,0,0,0])[r.rn]
  from (
    select e.serial, sum(e.win) wins, row_number() over (order by sum(e.win) desc, count(*) asc) rn
    from ev e join cards c2 on c2.serial = e.serial
    where c2.created_at >= p_start and c2.created_at < p_end
    group by e.serial having sum(e.win) > 0
  ) r join cards cc on cc.serial = r.serial where r.rn <= 5
  union all
  -- 📈 Astro nascente: maggior scalata Elo dall'ultima foto (start settimana)
  select 'astro', r.rn::int, r.serial, cc.name, cc.owner, r.gain::numeric, (array[50,0,0,0,0])[r.rn]
  from (
    select c.serial, (coalesce(c.elo,1000) - s.elo) gain,
      row_number() over (order by (coalesce(c.elo,1000) - s.elo) desc) rn
    from cards c join elo_snapshot s on s.serial = c.serial
    where c.retired is not true and (coalesce(c.elo,1000) - s.elo) > 0
  ) r join cards cc on cc.serial = r.serial where r.rn <= 5
  union all
  -- 😴 Pantofolaio (scherzo): tra chi ha combattuto, chi l'ha fatto meno
  select 'pantofolaio', 1, a.serial, n.name, n.owner, a.played::numeric, 15
  from (select serial, played from agg order by played asc, serial limit 1) a
  join names n using (serial);
$$;
grant execute on function public.award_standings(timestamptz, timestamptz) to anon, authenticated;

-- ---------- fine migrazione 5 ----------
