-- ============================================================================
--  CatCards — Award Fase 3, Passo 3 (parte 2): nuovi record HALL OF FAME
--  Da lanciare in Supabase → SQL Editor DOPO le migrazioni 1-5.
--  Aggiunge a hall_of_fame(): Picco Elo, Regno più lungo, Muro (difese),
--  Pluricampione, Le Nove Vite (primo a finire il Sentiero).
-- ============================================================================
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
   from cards where (coalesce(wins,0)+coalesce(losses,0)) >= 10 order by wins::numeric / nullif(wins+losses,0) desc, wins desc limit 1)
  union all
  -- 📊 Picco Elo: il più alto mai raggiunto
  (select 'piccoelo', serial, name, owner, coalesce(peak_elo, elo, 1000)::numeric
   from cards where peak_elo is not null order by peak_elo desc limit 1)
  union all
  -- 👑 Regno più lungo (in giorni)
  (select 'regno', serial, name, owner, round(extract(epoch from (coalesce(ended_at, now()) - started_at)) / 86400.0, 1)
   from champion_reigns order by (coalesce(ended_at, now()) - started_at) desc limit 1)
  union all
  -- 🛡️ Il Muro: regno con più difese del titolo (vittorie da campione durante il regno)
  (select 'muro', r.serial, r.name, r.owner, d.defenses::numeric
   from champion_reigns r
   cross join lateral (
     select count(*) defenses from matches m
     where m.winner_serial = r.serial and m.created_at >= r.started_at and m.created_at < coalesce(r.ended_at, now())
   ) d
   where d.defenses > 0 order by d.defenses desc limit 1)
  union all
  -- 🏅 Pluricampione: più volte campione (almeno 2 regni)
  (select 'pluricampione', r.serial, max(r.name), max(r.owner), count(*)::numeric
   from champion_reigns r group by r.serial having count(*) >= 2 order by count(*) desc limit 1)
  union all
  -- 🐈‍⬛ Le Nove Vite: primo a completare il Sentiero
  (select 'novevite', serial, name, owner, 100::numeric
   from sentiero_done order by done_at asc limit 1);
$$;
grant execute on function public.hall_of_fame() to anon, authenticated;

-- ---------- fine migrazione 6 ----------
