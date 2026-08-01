-- ============================================================================
--  CatCards — Nemesi (Fase 1): ricavata dallo storico incontri (zero costi)
--  La nemesi di una carta = l'avversario che l'ha battuta di più (min 2 volte).
--  Da lanciare in Supabase → SQL Editor.
-- ============================================================================

create or replace function public.card_nemesi(p_serial text)
returns table(serial text, name text, owner text, img text,
              they_beat_me int, i_beat_them int, total int, last_met timestamptz)
language sql stable security definer set search_path = public as $$
  with enc as (
    select loser_serial  as opp, 1 as i_win, 0 as they_win, created_at from matches where winner_serial = p_serial
    union all
    select winner_serial as opp, 0 as i_win, 1 as they_win, created_at from matches where loser_serial  = p_serial
  ),
  agg as (
    select opp,
           sum(i_win)::int    as i_beat_them,
           sum(they_win)::int  as they_beat_me,
           count(*)::int       as total,
           max(created_at)     as last_met
    from enc
    where opp is not null and opp <> p_serial
    group by opp
  )
  select a.opp, c.name, c.owner, c.img, a.they_beat_me, a.i_beat_them, a.total, a.last_met
  from agg a
  left join cards c on c.serial = a.opp
  where a.they_beat_me >= 2                              -- almeno 2 sconfitte contro di lui
  order by a.they_beat_me desc, a.total desc, a.last_met desc
  limit 1;
$$;
grant execute on function public.card_nemesi(text) to anon, authenticated;

-- ---------- fine migrazione Nemesi Fase 1 ----------
