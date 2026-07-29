-- ============================================================================
--  CatCards — Award & Hall of Fame  (Fase 1: fondamenta server-side)
--  Da lanciare UNA volta in Supabase → SQL Editor.
--  Tutto il calcolo vive qui: il client chiama le funzioni e mostra il risultato.
--  Chiusura settimana: sabato 21:00 ora italiana (Europe/Rome).
--  Punti al proprietario della carta vincitrice. Idempotente: niente doppioni.
-- ============================================================================

-- ---------- tabella albo d'oro (una riga per premio/rango di ogni edizione) ----------
create table if not exists public.awards (
  id         bigint generated always as identity primary key,
  week_id    text    not null,               -- data del sabato di chiusura, es. '2026-08-08'
  award      text    not null,               -- 'mvp','instancabile','cecchino','dominatore',...
  rank       int     not null default 1,     -- 1=oro, 2=argento, 3=bronzo
  serial     text,
  name       text,
  owner      text,
  value      numeric,                        -- vittorie / incontri / % / lunghezza striscia
  points     int     not null default 0,
  created_at timestamptz not null default now(),
  unique (week_id, award, rank)
);
alter table public.awards enable row level security;
drop policy if exists "awards_public_read" on public.awards;
create policy "awards_public_read" on public.awards for select using (true);
-- Nessuna policy INSERT/UPDATE: il client NON può scrivere. Scrive solo la funzione qui sotto (SECURITY DEFINER).

-- ---------- configurazione: da quando parte il conteggio (evita saldi retroattivi) ----------
create table if not exists public.award_config (
  id      int primary key default 1,
  genesis timestamptz not null
);

-- ---------- prossima chiusura: sabato 21:00 Europe/Rome, come timestamptz ----------
create or replace function public.award_next_close(p_now timestamptz default now())
returns timestamptz
language plpgsql immutable as $$
declare loc timestamp; d timestamp;
begin
  loc := p_now at time zone 'Europe/Rome';                 -- ora locale di Roma (senza tz)
  d := date_trunc('day', loc)
       + (((6 - extract(dow from loc)::int) + 7) % 7) * interval '1 day'  -- sabato di questa settimana
       + interval '21 hours';
  if d <= loc then d := d + interval '7 days'; end if;      -- se è già passato, il prossimo
  return d at time zone 'Europe/Rome';                      -- torna timestamptz
end $$;

-- genesis = prima chiusura futura al momento della migrazione (la 1ª edizione è il primo sabato dopo il lancio)
insert into public.award_config(id, genesis)
values (1, public.award_next_close(now()))
on conflict (id) do nothing;

-- ---------- classifiche di una finestra temporale [p_start, p_end) ----------
create or replace function public.award_standings(p_start timestamptz, p_end timestamptz)
returns table(award text, rank int, serial text, name text, owner text, value numeric, points int)
language sql stable security definer set search_path = public as $$
  with ev as (   -- un evento per (carta, incontro): win=1 vinto, win=0 perso
    select winner_serial as serial, created_at, 1 as win from matches where created_at >= p_start and created_at < p_end
    union all
    select loser_serial  as serial, created_at, 0 as win from matches where created_at >= p_start and created_at < p_end
  ),
  names as (     -- nome/proprietario più recente visto negli incontri della settimana
    select distinct on (serial) serial, name, owner from (
      select winner_serial serial, winner_name name, winner_owner owner, created_at from matches where created_at >= p_start and created_at < p_end
      union all
      select loser_serial  serial, loser_name  name, loser_owner  owner, created_at from matches where created_at >= p_start and created_at < p_end
    ) t order by serial, created_at desc
  ),
  agg as (
    select serial, sum(win) as wins, count(*) as played from ev group by serial
  ),
  -- isole di vittorie consecutive per la striscia (gaps-and-islands)
  grp as (
    select serial, win, created_at,
      row_number() over (partition by serial order by created_at)
        - row_number() over (partition by serial, win order by created_at) as g
    from ev
  ),
  streaks as (
    select serial, count(*) as len from grp where win = 1 group by serial, g
  ),
  best as (
    select serial, max(len) as streak from streaks group by serial
  )
  -- 🏆 MVP: più vittorie (podio)
  select 'mvp', r.rn::int, r.serial, n.name, n.owner, r.wins::numeric, (array[100,60,30])[r.rn]
  from (select serial, wins, row_number() over (order by wins desc, played asc) rn from agg where wins > 0) r
  join names n using (serial) where r.rn <= 3
  union all
  -- 🥊 Instancabile: più incontri (podio)
  select 'instancabile', r.rn::int, r.serial, n.name, n.owner, r.played::numeric, (array[60,40,20])[r.rn]
  from (select serial, played, row_number() over (order by played desc) rn from agg) r
  join names n using (serial) where r.rn <= 3
  union all
  -- 🎯 Cecchino: miglior % vittorie, min 5 incontri (podio)
  select 'cecchino', r.rn::int, r.serial, n.name, n.owner, round(r.pct, 3), (array[60,40,20])[r.rn]
  from (
    select serial, wins::numeric / played as pct,
      row_number() over (order by wins::numeric / played desc, wins desc) rn
    from agg where played >= 5
  ) r join names n using (serial) where r.rn <= 3
  union all
  -- 🔥 Dominatore: striscia più lunga della settimana (solo oro, min 2)
  select 'dominatore', 1, d.serial, n.name, n.owner, d.streak::numeric, 60
  from (select serial, streak from best where streak >= 2 order by streak desc limit 1) d
  join names n using (serial);
$$;
grant execute on function public.award_standings(timestamptz, timestamptz) to anon, authenticated;

-- ---------- classifiche della settimana IN CORSO (il client chiama questa) ----------
create or replace function public.award_standings_current()
returns table(award text, rank int, serial text, name text, owner text, value numeric, points int)
language sql stable security definer set search_path = public as $$
  select * from public.award_standings(public.award_next_close(now()) - interval '7 days', public.award_next_close(now()));
$$;
grant execute on function public.award_standings_current() to anon, authenticated;

-- ---------- Hall of Fame: record di sempre (un solo detentore per record) ----------
create or replace function public.hall_of_fame()
returns table(award text, serial text, name text, owner text, value numeric)
language sql stable security definer set search_path = public as $$
  (select 'striscia', serial, name, owner, best_streak::numeric
   from cards where coalesce(best_streak,0) > 1 order by best_streak desc, wins desc limit 1)
  union all
  (select 'veterano', serial, name, owner, (coalesce(wins,0)+coalesce(losses,0))::numeric
   from cards where (coalesce(wins,0)+coalesce(losses,0)) > 0 order by (coalesce(wins,0)+coalesce(losses,0)) desc limit 1)
  union all
  (select 'recordman', serial, name, owner, coalesce(wins,0)::numeric
   from cards where coalesce(wins,0) > 0 order by wins desc limit 1)
  union all
  (select 'winrate', serial, name, owner, round(wins::numeric / nullif(wins+losses,0), 3)
   from cards where (coalesce(wins,0)+coalesce(losses,0)) >= 10 order by wins::numeric / nullif(wins+losses,0) desc, wins desc limit 1);
$$;
grant execute on function public.hall_of_fame() to anon, authenticated;

-- ---------- chiusura settimanale idempotente: congela + assegna punti ----------
create or replace function public.settle_due_weeks()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_close   timestamptz;
  v_start   timestamptz;
  v_genesis timestamptz;
  v_wid     text;
  v_count   int := 0;
begin
  select genesis into v_genesis from award_config where id = 1;
  if v_genesis is null then return 0; end if;

  v_close := public.award_next_close(now()) - interval '7 days';   -- l'ultima chiusura già passata

  for i in 1..8 loop                                               -- salda anche settimane eventualmente saltate
    exit when v_close < v_genesis;                                 -- mai prima del lancio
    v_wid := to_char((v_close at time zone 'Europe/Rome')::date, 'YYYY-MM-DD');
    exit when exists (select 1 from awards where week_id = v_wid);  -- già saldata: stop

    v_start := v_close - interval '7 days';
    insert into awards(week_id, award, rank, serial, name, owner, value, points)
      select v_wid, s.award, s.rank, s.serial, s.name, s.owner, s.value, s.points
      from public.award_standings(v_start, v_close) s
    on conflict (week_id, award, rank) do nothing;

    -- accredita i punti al proprietario (account) della carta vincitrice
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
  return v_count;   -- quante edizioni sono state chiuse in questa chiamata
end $$;
grant execute on function public.settle_due_weeks() to anon, authenticated;

-- ---------- fine migrazione ----------
