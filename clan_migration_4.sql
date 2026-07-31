-- ============================================================================
--  CatCards — Clan: clan-bot per animare il mondo (admin)
--  Da lanciare in Supabase → SQL Editor DOPO le migrazioni clan 1-3.
-- ============================================================================

-- i bot non sono utenti auth reali: allento i vincoli su leader/membri
alter table public.clans        drop constraint if exists clans_leader_id_fkey;
alter table public.clan_members drop constraint if exists clan_members_user_id_fkey;

-- crea N clan guidati da proprietari-bot (solo admin). Idempotente: salta i bot già in un clan.
create or replace function public.admin_seed_bot_clans(p_count int)
returns int language plpgsql security definer set search_path = public as $$
declare rec record; v_clan bigint; n int := 0;
  ems text[] := array['🛡️','⚔️','🔥','🐾','👑','⭐','🌙','🦁','🐈','💥'];
begin
  if (auth.jwt() ->> 'email') <> 'antocecere77@gmail.com' then raise exception 'solo admin'; end if;
  for rec in
    select c.owner_id, max(c.owner) as owner
    from cards c
    where c.owner_id is not null
      and c.owner_id not in (select user_id from clan_members)
      and not exists (select 1 from profiles p where p.user_id = c.owner_id)   -- solo bot (nessun profilo reale)
    group by c.owner_id
    having count(*) >= 2
    limit greatest(coalesce(p_count, 5), 1)
  loop
    insert into clans(name, emblem, leader_id, open, points)
    values (left('Clan ' || rec.owner, 24), ems[1 + floor(random() * array_length(ems, 1))::int], rec.owner_id, (random() < 0.7), floor(random() * 120)::int)
    returning id into v_clan;
    insert into clan_members(clan_id, user_id, owner_name) values (v_clan, rec.owner_id, rec.owner);
    insert into clan_roster(clan_id, serial, added_by, pos)
      select v_clan, x.serial, rec.owner_id, row_number() over ()
      from (select serial from cards where owner_id = rec.owner_id order by elo desc nulls last limit 4) x;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.admin_seed_bot_clans(int) to authenticated;

-- ---------- fine migrazione clan-bot ----------
