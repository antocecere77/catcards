-- ============================================================================
--  CatCards — Clan (Gang) Fase 2a: schema + operazioni server-side
--  Da lanciare UNA volta in Supabase → SQL Editor.
--  Regole applicate qui: 1 utente = 1 clan · capo comanda · capo esce = clan
--  sciolto · tetti 8 membri / 20 carte · ordine roster compatto.
-- ============================================================================

-- ---------- tabelle ----------
create table if not exists public.clans (
  id         bigint generated always as identity primary key,
  name       text not null,
  emblem     text default '🛡️',
  leader_id  uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz default now()
);
create table if not exists public.clan_members (
  clan_id    bigint not null references clans(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  owner_name text,
  joined_at  timestamptz default now(),
  primary key (clan_id, user_id),
  unique (user_id)                         -- 1 utente = 1 clan
);
create table if not exists public.clan_roster (
  id       bigint generated always as identity primary key,
  clan_id  bigint not null references clans(id) on delete cascade,
  serial   text not null,
  added_by uuid,
  pos      int not null default 0,
  unique (clan_id, serial)
);
create table if not exists public.clan_invites (
  id           bigint generated always as identity primary key,
  clan_id      bigint not null references clans(id) on delete cascade,
  to_user_id   uuid not null,
  from_name    text,
  created_at   timestamptz default now(),
  unique (clan_id, to_user_id)
);
create table if not exists public.clan_applications (
  id         bigint generated always as identity primary key,
  clan_id    bigint not null references clans(id) on delete cascade,
  user_id    uuid not null,
  owner_name text,
  created_at timestamptz default now(),
  unique (clan_id, user_id)
);

-- ---------- RLS: lettura pubblica dove serve; scrittura SOLO via funzioni ----------
alter table public.clans             enable row level security;
alter table public.clan_members      enable row level security;
alter table public.clan_roster       enable row level security;
alter table public.clan_invites      enable row level security;
alter table public.clan_applications enable row level security;
drop policy if exists p_clans_read on public.clans;             create policy p_clans_read      on public.clans             for select using (true);
drop policy if exists p_members_read on public.clan_members;    create policy p_members_read    on public.clan_members      for select using (true);
drop policy if exists p_roster_read on public.clan_roster;      create policy p_roster_read     on public.clan_roster       for select using (true);
drop policy if exists p_inv_read on public.clan_invites;        create policy p_inv_read        on public.clan_invites      for select using (to_user_id = auth.uid() or exists (select 1 from clans c where c.id = clan_id and c.leader_id = auth.uid()));
drop policy if exists p_app_read on public.clan_applications;   create policy p_app_read        on public.clan_applications for select using (user_id = auth.uid() or exists (select 1 from clans c where c.id = clan_id and c.leader_id = auth.uid()));

-- ---------- helper: compatta l'ordine del roster ----------
create or replace function public.clan_compact(p_clan bigint) returns void
language sql security definer set search_path = public as $$
  update clan_roster r set pos = s.rn
  from (select id, row_number() over (order by pos, id) rn from clan_roster where clan_id = p_clan) s
  where r.id = s.id and r.clan_id = p_clan;
$$;

-- ---------- crea clan (il chiamante diventa capo + membro) ----------
create or replace function public.clan_create(p_name text, p_emblem text, p_owner text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id bigint;
begin
  if v_uid is null then raise exception 'login richiesto'; end if;
  if exists (select 1 from clan_members where user_id = v_uid) then raise exception 'sei già in un clan'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'nome mancante'; end if;
  insert into clans(name, emblem, leader_id) values (left(trim(p_name),24), coalesce(nullif(p_emblem,''),'🛡️'), v_uid) returning id into v_id;
  insert into clan_members(clan_id, user_id, owner_name) values (v_id, v_uid, p_owner);
  delete from clan_applications where user_id = v_uid;   -- ritira eventuali richieste pendenti
  return v_id;
end $$;

-- ---------- esci dal clan (se sei il capo, il clan si scioglie) ----------
create or replace function public.clan_leave()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_leader uuid;
begin
  select clan_id into v_clan from clan_members where user_id = v_uid;
  if v_clan is null then return; end if;
  select leader_id into v_leader from clans where id = v_clan;
  if v_leader = v_uid then
    delete from clans where id = v_clan;             -- cascade: membri, roster, inviti, richieste
  else
    delete from clan_members where clan_id = v_clan and user_id = v_uid;
    delete from clan_roster  where clan_id = v_clan and added_by = v_uid;   -- ritira le sue carte
    perform clan_compact(v_clan);
  end if;
end $$;

-- ---------- bacheca: richiedi di entrare ----------
create or replace function public.clan_apply(p_clan bigint, p_owner text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'login richiesto'; end if;
  if exists (select 1 from clan_members where user_id = v_uid) then raise exception 'sei già in un clan'; end if;
  insert into clan_applications(clan_id, user_id, owner_name) values (p_clan, v_uid, p_owner)
  on conflict (clan_id, user_id) do nothing;
end $$;

-- ---------- il capo accetta/rifiuta una richiesta ----------
create or replace function public.clan_respond_application(p_app bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_applicant uuid; v_name text;
begin
  select clan_id, user_id, owner_name into v_clan, v_applicant, v_name from clan_applications where id = p_app;
  if v_clan is null then return; end if;
  if not exists (select 1 from clans where id = v_clan and leader_id = v_uid) then raise exception 'solo il capo'; end if;
  if p_accept then
    if (select count(*) from clan_members where clan_id = v_clan) >= 8 then raise exception 'clan pieno (8)'; end if;
    if not exists (select 1 from clan_members where user_id = v_applicant) then
      insert into clan_members(clan_id, user_id, owner_name) values (v_clan, v_applicant, v_name);
      delete from clan_applications where user_id = v_applicant;   -- ritira le altre sue richieste
    end if;
  end if;
  delete from clan_applications where id = p_app;
end $$;

-- ---------- il capo invita un utente ----------
create or replace function public.clan_invite(p_clan bigint, p_to uuid, p_from text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if not exists (select 1 from clans where id = p_clan and leader_id = v_uid) then raise exception 'solo il capo'; end if;
  if exists (select 1 from clan_members where user_id = p_to) then raise exception 'utente già in un clan'; end if;
  insert into clan_invites(clan_id, to_user_id, from_name) values (p_clan, p_to, p_from)
  on conflict (clan_id, to_user_id) do nothing;
end $$;

-- ---------- l'invitato accetta/rifiuta ----------
create or replace function public.clan_respond_invite(p_inv bigint, p_accept boolean, p_owner text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_to uuid;
begin
  select clan_id, to_user_id into v_clan, v_to from clan_invites where id = p_inv;
  if v_clan is null or v_to <> v_uid then return; end if;
  if p_accept and not exists (select 1 from clan_members where user_id = v_uid) then
    if (select count(*) from clan_members where clan_id = v_clan) >= 8 then raise exception 'clan pieno (8)'; end if;
    insert into clan_members(clan_id, user_id, owner_name) values (v_clan, v_uid, p_owner);
    delete from clan_applications where user_id = v_uid;
  end if;
  delete from clan_invites where id = p_inv;
end $$;

-- ---------- roster: aggiungi una TUA carta ----------
create or replace function public.clan_roster_add(p_serial text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint;
begin
  select clan_id into v_clan from clan_members where user_id = v_uid;
  if v_clan is null then raise exception 'non sei in un clan'; end if;
  if not exists (select 1 from cards where serial = p_serial and owner_id = v_uid) then raise exception 'non è una tua carta'; end if;
  if (select count(*) from clan_roster where clan_id = v_clan) >= 20 then raise exception 'roster pieno (20)'; end if;
  insert into clan_roster(clan_id, serial, added_by, pos)
  values (v_clan, p_serial, v_uid, coalesce((select max(pos) from clan_roster where clan_id = v_clan), 0) + 1)
  on conflict (clan_id, serial) do nothing;
end $$;

-- ---------- roster: togli una carta (il proprietario o il capo) ----------
create or replace function public.clan_roster_remove(p_serial text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; v_leader uuid; v_owner uuid;
begin
  select clan_id into v_clan from clan_members where user_id = v_uid;
  if v_clan is null then return; end if;
  select leader_id into v_leader from clans where id = v_clan;
  select added_by into v_owner from clan_roster where clan_id = v_clan and serial = p_serial;
  if v_owner is null then return; end if;
  if v_uid <> v_owner and v_uid <> v_leader then raise exception 'solo il proprietario o il capo'; end if;
  delete from clan_roster where clan_id = v_clan and serial = p_serial;
  perform clan_compact(v_clan);
end $$;

-- ---------- roster: il capo riordina (array di serial nell'ordine voluto) ----------
create or replace function public.clan_roster_reorder(p_serials text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_clan bigint; i int;
begin
  select id into v_clan from clans where leader_id = v_uid;
  if v_clan is null then raise exception 'solo il capo'; end if;
  for i in 1 .. array_length(p_serials, 1) loop
    update clan_roster set pos = i where clan_id = v_clan and serial = p_serials[i];
  end loop;
  perform clan_compact(v_clan);
end $$;

grant execute on function public.clan_create(text,text,text)              to authenticated;
grant execute on function public.clan_leave()                             to authenticated;
grant execute on function public.clan_apply(bigint,text)                  to authenticated;
grant execute on function public.clan_respond_application(bigint,boolean) to authenticated;
grant execute on function public.clan_invite(bigint,uuid,text)            to authenticated;
grant execute on function public.clan_respond_invite(bigint,boolean,text) to authenticated;
grant execute on function public.clan_roster_add(text)                    to authenticated;
grant execute on function public.clan_roster_remove(text)                 to authenticated;
grant execute on function public.clan_roster_reorder(text[])              to authenticated;

-- ---------- fine migrazione Clan Fase 2a ----------
