-- ============================================================================
--  CatCards — Clan Fase 3a: guerre di clan (punti + registro + report)
--  Da lanciare in Supabase → SQL Editor DOPO clan_migration.sql e _2.sql.
-- ============================================================================

alter table public.clans add column if not exists points int default 0;

create table if not exists public.clan_wars (
  id            bigint generated always as identity primary key,
  attacker_clan bigint references clans(id) on delete cascade,
  defender_clan bigint references clans(id) on delete cascade,
  winner_clan   bigint,
  created_at    timestamptz default now()
);
alter table public.clan_wars enable row level security;
drop policy if exists clan_wars_read on public.clan_wars;
create policy clan_wars_read on public.clan_wars for select using (true);

-- sfoglia i clan: ora ritorna anche i PUNTI (ordina per punti desc)
drop function if exists public.clan_browse(text, int, int);
create or replace function public.clan_browse(p_search text, p_limit int, p_offset int)
returns table(id bigint, name text, emblem text, open boolean, points int, member_count int, roster_count int)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.emblem, c.open, coalesce(c.points,0),
    (select count(*)::int from clan_members m where m.clan_id = c.id),
    (select count(*)::int from clan_roster  r where r.clan_id = c.id)
  from clans c
  where p_search is null or p_search = '' or c.name ilike '%' || p_search || '%'
  order by coalesce(c.points,0) desc, c.created_at desc
  limit coalesce(p_limit, 20) offset coalesce(p_offset, 0);
$$;
grant execute on function public.clan_browse(text,int,int) to anon, authenticated;

-- report del risultato di una guerra (l'attaccante è il clan del capo che chiama)
create or replace function public.clan_war_report(p_defender bigint, p_attacker_won boolean, p_attacker_serials text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_att bigint; v_winner bigint;
begin
  select id into v_att from clans where leader_id = v_uid;
  if v_att is null then raise exception 'solo il capo puo attaccare'; end if;
  if p_defender = v_att then raise exception 'non puoi attaccare il tuo clan'; end if;
  if not exists (select 1 from clans where id = p_defender) then raise exception 'clan avversario inesistente'; end if;
  if exists (select 1 from clan_wars where attacker_clan = v_att and defender_clan = p_defender and created_at > now() - interval '30 minutes') then
    raise exception 'territorio in cooldown: riprova piu tardi';
  end if;
  v_winner := case when p_attacker_won then v_att else p_defender end;
  insert into clan_wars(attacker_clan, defender_clan, winner_clan) values (v_att, p_defender, v_winner);
  update clans set points = coalesce(points,0) + 30 where id = v_winner;                                               -- vincitore
  update clans set points = coalesce(points,0) + 5  where id = case when p_attacker_won then p_defender else v_att end;  -- sconfitto (consolazione)
  if p_attacker_serials is not null then
    update cards set rest_until = now() + interval '1 hour' where serial = any(p_attacker_serials);                     -- le carte attaccanti riposano
  end if;
end $$;
grant execute on function public.clan_war_report(bigint,boolean,text[]) to authenticated;

-- ---------- fine migrazione Clan 3a ----------
