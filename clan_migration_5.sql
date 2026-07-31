-- ============================================================================
--  CatCards — Clan Fase 3b: schieramenti + simulazione server delle guerre
--  Da lanciare in Supabase → SQL Editor DOPO clan_migration_1..4.sql.
--  Obiettivo: il capo pre-imposta la DIFESA; il server SIMULA le guerre
--  (staffetta per formula calibrata) così i clan-bot possono attaccare
--  anche quando nessuno è online. Zero costi IA.
-- ============================================================================

-- quante carte difendono il clan quando viene attaccato (il roster ordinato = priorità)
alter table public.clans add column if not exists def_size int default 3;

-- il capo imposta la dimensione della squadra di difesa (1..5)
create or replace function public.clan_set_defense(p_size int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update clans set def_size = greatest(1, least(5, coalesce(p_size, 3))) where leader_id = auth.uid();
end $$;
grant execute on function public.clan_set_defense(int) to authenticated;

-- ---------- motore: simula una staffetta tra due schieramenti ----------
-- Forza = Elo della carta (misura già calibrata). Ogni scontro è una moneta
-- truccata: P(vince A) = 1 / (1 + 10^((EloB-EloA)/200)). Il vincitore resta,
-- il perdente esce, finché una squadra è finita. Ritorna vincitore + log.
create or replace function public._sim_staffetta(a text[], b text[])
returns jsonb language plpgsql volatile set search_path = public as $$
declare
  pa numeric[] := '{}'; pb numeric[] := '{}'; s text;
  i int := 1; j int := 1; na int; nb int; prob numeric; awin boolean;
  steps jsonb := '[]'::jsonb;
begin
  foreach s in array a loop pa := pa || coalesce((select elo from cards where serial = s), 1000)::numeric; end loop;
  foreach s in array b loop pb := pb || coalesce((select elo from cards where serial = s), 1000)::numeric; end loop;
  na := array_length(pa, 1); nb := array_length(pb, 1);
  if na is null then return jsonb_build_object('winner', 'B', 'steps', steps); end if;
  if nb is null then return jsonb_build_object('winner', 'A', 'steps', steps); end if;
  while i <= na and j <= nb loop
    prob := 1.0 / (1.0 + power(10.0, (pb[j] - pa[i]) / 200.0));
    awin := random() < prob;
    steps := steps || jsonb_build_object('a', a[i], 'b', b[j], 'aw', awin);
    if awin then j := j + 1; else i := i + 1; end if;
  end loop;
  return jsonb_build_object('winner', case when i <= na then 'A' else 'B' end,
                            'steps', steps, 'aleft', na - i + 1, 'bleft', nb - j + 1);
end $$;
grant execute on function public._sim_staffetta(text[], text[]) to authenticated;

-- ---------- ondata di guerre dei clan-bot (admin) ----------
-- Ogni round: un clan-bot a caso attacca un altro clan a caso (anche il tuo!).
-- L'attaccante schiera le prime 3 del roster; il difensore le prime def_size.
-- Assegna i punti (+30 vincitore / +5 sconfitto) e registra la guerra.
create or replace function public.sim_clan_wars(p_rounds int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  att record; def record; a_ser text[]; b_ser text[]; r jsonb; awon boolean;
  results jsonb := '[]'::jsonb; done int := 0; k int;
begin
  if (auth.jwt() ->> 'email') <> 'antocecere77@gmail.com' then raise exception 'solo admin'; end if;
  for k in 1..greatest(1, coalesce(p_rounds, 5)) loop
    -- attaccante: un clan-bot (capo senza profilo reale)
    select c.id, c.name into att
      from clans c
      where not exists (select 1 from profiles p where p.user_id = c.leader_id)
      order by random() limit 1;
    if att.id is null then exit; end if;
    -- difensore: un altro clan qualsiasi
    select c.id, c.name, coalesce(c.def_size, 3) as dz into def
      from clans c where c.id <> att.id order by random() limit 1;
    if def.id is null then continue; end if;
    -- niente doppioni ravvicinati sulla stessa coppia
    if exists (select 1 from clan_wars where attacker_clan = att.id and defender_clan = def.id and created_at > now() - interval '30 minutes') then continue; end if;
    select array_agg(serial order by pos) into a_ser from (select serial, pos from clan_roster where clan_id = att.id order by pos limit 3) x;
    select array_agg(serial order by pos) into b_ser from (select serial, pos from clan_roster where clan_id = def.id order by pos limit def.dz) x;
    if a_ser is null or b_ser is null then continue; end if;
    r := _sim_staffetta(a_ser, b_ser);
    awon := (r ->> 'winner') = 'A';
    insert into clan_wars(attacker_clan, defender_clan, winner_clan)
      values (att.id, def.id, case when awon then att.id else def.id end);
    update clans set points = coalesce(points, 0) + 30 where id = case when awon then att.id else def.id end;
    update clans set points = coalesce(points, 0) + 5  where id = case when awon then def.id else att.id end;
    results := results || jsonb_build_object('att', att.name, 'def', def.name, 'att_won', awon);
    done := done + 1;
  end loop;
  return jsonb_build_object('rounds', done, 'wars', results);
end $$;
grant execute on function public.sim_clan_wars(int) to authenticated;

-- ---------- registro guerre leggibile (nomi + esito) per la bacheca ----------
create or replace function public.clan_war_log(p_clan bigint, p_limit int)
returns table(created_at timestamptz, attacker text, defender text, att_won boolean, is_me boolean)
language sql stable security definer set search_path = public as $$
  select w.created_at, ca.name, cd.name, (w.winner_clan = w.attacker_clan),
         (w.attacker_clan = p_clan)
  from clan_wars w
  join clans ca on ca.id = w.attacker_clan
  join clans cd on cd.id = w.defender_clan
  where w.attacker_clan = p_clan or w.defender_clan = p_clan
  order by w.created_at desc
  limit coalesce(p_limit, 8);
$$;
grant execute on function public.clan_war_log(bigint, int) to anon, authenticated;

-- ---------- fine migrazione Clan 3b ----------
