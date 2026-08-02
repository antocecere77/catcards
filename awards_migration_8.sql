-- ============================================================================
--  CatCards — Award: CHIUSURA AUTOMATICA della settimana (pg_cron)
--  settle_due_weeks() chiude le settimane scadute, crea l'edizione e accredita
--  i punti. Finora girava solo quando qualcuno apriva l'app: ora gira da sola.
--  Idempotente: se non c'è nulla da chiudere non fa niente.
--  Da lanciare in Supabase → SQL Editor DOPO awards_migration_1..7.sql.
--  (Serve pg_cron: se manca, Dashboard → Database → Extensions → pg_cron.)
-- ============================================================================

create extension if not exists pg_cron;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'catcards_award_settle') then perform cron.unschedule('catcards_award_settle'); end if;
end $$;

-- ogni ora al minuto 5: chiude eventuali settimane scadute (idempotente)
select cron.schedule('catcards_award_settle', '5 * * * *', $$ select public.settle_due_weeks(); $$);

-- chiude subito quelle GIÀ scadute finora (prima esecuzione manuale)
select public.settle_due_weeks();

-- Verifica:   select jobname, schedule, active from cron.job;
-- Edizioni:   select distinct week_id from awards order by week_id desc;
-- ---------- fine migrazione Award (chiusura automatica) ----------
