-- ============================================================================
--  CatCards — Award Fase 3, Passo 2a+2b: instrumentazione (logging da adesso)
--  Da lanciare UNA volta in Supabase → SQL Editor.
--  Aggiunge i dati che serviranno ai premi extra. I valori del PASSATO non si
--  recuperano: i nuovi campi si popolano dai match/carte da qui in avanti.
-- ============================================================================

-- matches: Elo dei due al momento del match + chi ha lanciato la sfida
alter table public.matches add column if not exists winner_elo       int;
alter table public.matches add column if not exists loser_elo        int;
alter table public.matches add column if not exists challenger_serial text;

-- cards: data di creazione + picco Elo storico
alter table public.cards add column if not exists created_at timestamptz;
update public.cards set created_at = timestamp '2020-01-01' where created_at is null;  -- le carte già esistenti NON sono "nuove"
alter table public.cards alter column created_at set default now();

alter table public.cards add column if not exists peak_elo int;
update public.cards set peak_elo = coalesce(elo, 1000) where peak_elo is null;         -- inizializza al valore attuale

-- peak_elo si alza da solo quando l'Elo cresce
create or replace function public.trg_peak_elo() returns trigger language plpgsql as $$
begin
  new.peak_elo := greatest(coalesce(old.peak_elo, 0), coalesce(new.elo, 1000));
  return new;
end $$;
drop trigger if exists cards_peak_elo on public.cards;
create trigger cards_peak_elo before update of elo on public.cards
  for each row execute function public.trg_peak_elo();

-- ---------- fine migrazione 3 ----------
