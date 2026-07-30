-- ============================================================================
--  CatCards — Award, migrazione 2: rilevamento "record di sempre superato"
--  Da lanciare UNA volta in Supabase → SQL Editor (dopo awards_migration.sql).
--  Fotografa la Hall of Fame a ogni chiusura settimanale e, se un record
--  è stato battuto durante la settimana, lo segna così la cerimonia può gridare
--  "È caduto un record!". Idempotente, server-side, zero costi.
-- ============================================================================

-- fotografia della Hall of Fame all'ultima chiusura (una riga per record)
create table if not exists public.hall_snapshot (
  award      text primary key,
  serial     text, name text, owner text, value numeric,
  updated_at timestamptz default now()
);
alter table public.hall_snapshot enable row level security;
-- nessuna policy: solo le funzioni SECURITY DEFINER la toccano

-- classifiche fino al 5° posto: 1-3 a podio (con punti), 4-5 "in lizza" (0 punti)
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
  select 'mvp', r.rn::int, r.serial, n.name, n.owner, r.wins::numeric, (array[100,60,30,0,0])[r.rn]
  from (select serial, wins, row_number() over (order by wins desc, played asc) rn from agg where wins > 0) r
  join names n using (serial) where r.rn <= 5
  union all
  select 'instancabile', r.rn::int, r.serial, n.name, n.owner, r.played::numeric, (array[60,40,20,0,0])[r.rn]
  from (select serial, played, row_number() over (order by played desc) rn from agg) r
  join names n using (serial) where r.rn <= 5
  union all
  select 'cecchino', r.rn::int, r.serial, n.name, n.owner, round(r.pct, 3), (array[60,40,20,0,0])[r.rn]
  from (
    select serial, wins::numeric / played as pct,
      row_number() over (order by wins::numeric / played desc, wins desc) rn
    from agg where played >= 5
  ) r join names n using (serial) where r.rn <= 5
  union all
  select 'dominatore', r.rn::int, r.serial, n.name, n.owner, r.streak::numeric, (array[60,0,0,0,0])[r.rn]
  from (select serial, streak, row_number() over (order by streak desc) rn from best where streak >= 2) r
  join names n using (serial) where r.rn <= 5;
$$;
grant execute on function public.award_standings(timestamptz, timestamptz) to anon, authenticated;

-- chiusura settimanale + assegnazione punti + rilevamento record caduti
create or replace function public.settle_due_weeks()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_close   timestamptz;
  v_start   timestamptz;
  v_genesis timestamptz;
  v_wid     text;
  v_newest  text := null;
  v_count   int := 0;
  rec record; old_val numeric; had_snapshot boolean;
begin
  select genesis into v_genesis from award_config where id = 1;
  if v_genesis is null then return 0; end if;

  v_close := public.award_next_close(now()) - interval '7 days';

  for i in 1..8 loop
    exit when v_close < v_genesis;
    v_wid := to_char((v_close at time zone 'Europe/Rome')::date, 'YYYY-MM-DD');
    exit when exists (select 1 from awards where week_id = v_wid);
    if v_newest is null then v_newest := v_wid; end if;

    v_start := v_close - interval '7 days';
    insert into awards(week_id, award, rank, serial, name, owner, value, points)
      select v_wid, s.award, s.rank, s.serial, s.name, s.owner, s.value, s.points
      from public.award_standings(v_start, v_close) s
    on conflict (week_id, award, rank) do nothing;

    update profiles p set points = points + agg.pts, updated_at = now()
    from (
      select c.owner_id, sum(a.points) pts
      from awards a join cards c on c.serial = a.serial
      where a.week_id = v_wid and a.points > 0 and c.owner_id is not null
      group by c.owner_id
    ) agg
    where p.user_id = agg.owner_id;

    v_count := v_count + 1;
    v_close := v_close - interval '7 days';
  end loop;

  -- Hall of Fame: confronta con la fotografia precedente; i record migliorati
  -- diventano righe 'hall_<record>' dell'edizione più recente (0 punti, solo onore).
  if v_count > 0 then
    select exists(select 1 from hall_snapshot) into had_snapshot;
    for rec in select * from public.hall_of_fame() loop
      select value into old_val from hall_snapshot where award = rec.award;
      if had_snapshot and old_val is not null and rec.value > old_val then
        insert into awards(week_id, award, rank, serial, name, owner, value, points)
        values (v_newest, 'hall_' || rec.award, 1, rec.serial, rec.name, rec.owner, rec.value, 0)
        on conflict (week_id, award, rank) do nothing;
      end if;
    end loop;
    delete from hall_snapshot;
    insert into hall_snapshot(award, serial, name, owner, value)
      select award, serial, name, owner, value from public.hall_of_fame();
  end if;

  return v_count;
end $$;
grant execute on function public.settle_due_weeks() to anon, authenticated;

-- ---------- fine migrazione 2 ----------
