-- ============================================================================
--  CatCards — Titoli, Fase 1 (parte 1): categorizzazione razza/colore lato server
--  Replica del normalizzatore dell'app: una razza per carta (con priorità) +
--  fino a 2 colori. Serve a sapere chi appartiene a quale categoria per creare
--  e difendere le cinture. Da lanciare in Supabase → SQL Editor.
-- ============================================================================

-- normalizza la stringa razza: minuscolo, senza accenti, solo lettere/spazi, con spazi ai bordi
create or replace function public._norm_razza(s text)
returns text language sql immutable as $$
  select ' ' || regexp_replace(
           regexp_replace(
             translate(lower(coalesce(s, '')),
                       'àáâãäèéêëìíîïòóôõöùúûüç', 'aaaaaeeeeiiiiooooouuuuc'),
             '[^a-z ]', ' ', 'g'),
           '\s+', ' ', 'g') || ' ';
$$;

-- razza normalizzata (la prima per priorità, come BREED_ORDER)
create or replace function public.card_breed(razza text)
returns text language sql immutable as $$
  with s as (select public._norm_razza(razza) as t)
  select key from (values
    (1,'mainecoon', array['maine coon','maine']),
    (2,'blurusso',  array['blu di russia','russian blue','russo']),
    (3,'norvegese', array['norvegese','delle foreste']),
    (4,'scottish',  array['scottish','fold']),
    (5,'esotico',   array['esotico','esotica','exotic']),
    (6,'siberiano', array['siberiano','siberiana']),
    (7,'certosino', array['certosino','certosina','chartreux']),
    (8,'siamese',   array['siamese']),
    (9,'persiano',  array['persiano','persiana']),
    (10,'ragdoll',  array['ragdoll']),
    (11,'sphynx',   array['sphynx','sfinge','senza pelo','nudo']),
    (12,'bengala',  array['bengala','bengalese','bengal']),
    (13,'british',  array['british','britannico','britannica']),
    (14,'angora',   array['angora']),
    (15,'birmano',  array['birmano','birmana','sacro di birmania']),
    (16,'abissino', array['abissino','abissina']),
    (17,'orientale',array['orientale']),
    (18,'turco',    array['turco','van']),
    (19,'savana',   array['savannah','savana']),
    (20,'bombay',   array['bombay']),
    (21,'rex',      array['rex','devon','cornish']),
    (22,'soriano',  array['soriano','soriana']),
    (23,'tigrato',  array['tigrato','tigrata','tabby']),
    (24,'europeo',  array['europeo','europea']),
    (25,'comune',   array['comune','domestico','domestica','meticcio','meticcia'])
  ) b(ord,key,syns), s
  where exists (select 1 from unnest(b.syns) w where position(' '||w||' ' in s.t) > 0)
  order by b.ord limit 1;
$$;

-- colori normalizzati (fino a 2), tolte prima le parole della razza
create or replace function public.card_colors(razza text)
returns text[] language plpgsql immutable as $$
declare s text := public._norm_razza(razza); s2 text; b text := public.card_breed(razza); w text; res text[];
begin
  s2 := s;
  if b is not null then
    for w in select unnest(syns) from (values
      ('mainecoon',array['maine coon','maine']),('blurusso',array['blu di russia','russian blue','russo']),
      ('norvegese',array['norvegese','delle foreste']),('scottish',array['scottish','fold']),
      ('esotico',array['esotico','esotica','exotic']),('siberiano',array['siberiano','siberiana']),
      ('certosino',array['certosino','certosina','chartreux']),('siamese',array['siamese']),
      ('persiano',array['persiano','persiana']),('ragdoll',array['ragdoll']),
      ('sphynx',array['sphynx','sfinge','senza pelo','nudo']),('bengala',array['bengala','bengalese','bengal']),
      ('british',array['british','britannico','britannica']),('angora',array['angora']),
      ('birmano',array['birmano','birmana','sacro di birmania']),('abissino',array['abissino','abissina']),
      ('orientale',array['orientale']),('turco',array['turco','van']),('savana',array['savannah','savana']),
      ('bombay',array['bombay']),('rex',array['rex','devon','cornish']),('soriano',array['soriano','soriana']),
      ('tigrato',array['tigrato','tigrata','tabby']),('europeo',array['europeo','europea']),
      ('comune',array['comune','domestico','domestica','meticcio','meticcia'])
    ) t(key,syns) where t.key = b loop
      s2 := replace(s2, ' '||w||' ', ' ');
    end loop;
  end if;
  select array_agg(key order by ord) into res from (
    select ord,key from (values
      (1,'tartarugato',array['tartarugato','tartaruga','tortie']),
      (2,'tricolore',  array['tricolore','calico']),
      (3,'bicolore',   array['bicolore','smoking','tuxedo']),
      (4,'pointed',    array['point','colorpoint','colourpoint','mascherato']),
      (5,'maculato',   array['maculato','maculata','pezzato','pezzata','macchie']),
      (6,'striato',    array['striato','striata']),
      (7,'bianco',     array['bianco','bianca']),
      (8,'nero',       array['nero','nera']),
      (9,'grigio',     array['grigio','grigia']),
      (10,'blu',       array['blu']),
      (11,'rosso',     array['rosso','rossa','arancione','zenzero']),
      (12,'crema',     array['crema','panna']),
      (13,'marrone',   array['marrone','cioccolato']),
      (14,'fulvo',     array['fulvo','fulva','sabbia'])
    ) c(ord,key,syns)
    where exists (select 1 from unnest(c.syns) x where position(' '||x||' ' in s2) > 0)
    order by ord limit 2
  ) z;
  return coalesce(res, '{}');
end $$;

-- categorie idonee a una cintura: razza (una per carta) o colore (anche più d'uno per carta), con conteggio
create or replace function public.title_categories(p_min int default 10)
returns table(tipo text, categoria text, contendenti int)
language sql stable security definer set search_path = public as $$
  with pool as (select serial, razza from cards where retired is not true and razza is not null)
  select 'razza', card_breed(razza), count(*)::int
  from pool where card_breed(razza) is not null
  group by card_breed(razza)
  having count(*) >= coalesce(p_min, 10)
  union all
  select 'colore', col, count(*)::int
  from pool, unnest(card_colors(razza)) col
  group by col
  having count(*) >= coalesce(p_min, 10)
  order by 1, 3 desc;
$$;
grant execute on function public.title_categories(int) to anon, authenticated;

-- ---------- fine Titoli Fase 1 (parte 1) ----------
