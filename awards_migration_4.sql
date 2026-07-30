-- ============================================================================
--  CatCards — Award Fase 3, Passo 2c+2d+2e: instrumentazione (parte 2)
--  Da lanciare UNA volta in Supabase → SQL Editor (dopo migrazioni 1-3).
--  2c: foto Elo settimanale → Astro nascente
--  2d: storico cinture (trigger su meta) → Regno più lungo, Muro, Pluricampione
--  2e: completamento Sentiero → Le Nove Vite
-- ============================================================================

-- ---------- 2c: foto Elo settimanale ----------
create table if not exists public.elo_snapshot (
  serial   text primary key,
  elo      int,
  taken_at timestamptz default now()
);
alter table public.elo_snapshot enable row level security;
drop policy if exists "elosnap_read" on public.elo_snapshot;
create policy "elosnap_read" on public.elo_snapshot for select using (true);

-- ---------- 2d: storico cinture (regni del campione) ----------
create table if not exists public.champion_reigns (
  id         bigint generated always as identity primary key,
  serial     text, name text, owner text,
  started_at timestamptz default now(),
  ended_at   timestamptz
);
alter table public.champion_reigns enable row level security;
drop policy if exists "reigns_read" on public.champion_reigns;
create policy "reigns_read" on public.champion_reigns for select using (true);

-- ogni volta che cambia il campione (meta k='champion'), chiudi il regno aperto e aprine uno nuovo
create or replace function public.trg_champ_reign() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.k <> 'champion' then return NEW; end if;
  if TG_OP = 'UPDATE' and NEW.v is not distinct from OLD.v then return NEW; end if;
  update champion_reigns set ended_at = now() where ended_at is null;
  if NEW.v is not null and NEW.v <> '' then
    insert into champion_reigns(serial, name, owner)
    values (NEW.v, (select name from cards where serial = NEW.v), (select owner from cards where serial = NEW.v));
  end if;
  return NEW;
end $$;
drop trigger if exists meta_champ_reign on public.meta;
create trigger meta_champ_reign after insert or update on public.meta
  for each row execute function public.trg_champ_reign();

-- seed: registra il regno del campione attuale (se non c'è già un regno aperto)
insert into public.champion_reigns(serial, name, owner, started_at)
select m.v, (select name from cards where serial = m.v), (select owner from cards where serial = m.v), now()
from public.meta m
where m.k = 'champion' and m.v is not null and m.v <> ''
  and not exists (select 1 from public.champion_reigns where ended_at is null);

-- ---------- 2e: completamento Sentiero (prima volta che una carta finisce tutte le tappe) ----------
create table if not exists public.sentiero_done (
  serial  text primary key,
  user_id uuid,
  name    text, owner text,
  done_at timestamptz default now()
);
alter table public.sentiero_done enable row level security;
drop policy if exists "sentdone_read" on public.sentiero_done;
create policy "sentdone_read" on public.sentiero_done for select using (true);
drop policy if exists "sentdone_insert" on public.sentiero_done;
create policy "sentdone_insert" on public.sentiero_done for insert with check (auth.uid() = user_id);

-- ---------- settle_due_weeks: aggiunta della foto Elo a ogni chiusura ----------
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

  if v_count > 0 then
    -- Hall of Fame: record superati durante la settimana
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

    -- foto Elo per Astro nascente (la prossima settimana confronterà con questa)
    delete from elo_snapshot;
    insert into elo_snapshot(serial, elo)
      select serial, coalesce(elo, 1000) from cards where retired is not true;
  end if;

  return v_count;
end $$;
grant execute on function public.settle_due_weeks() to anon, authenticated;

-- ---------- fine migrazione 4 ----------
