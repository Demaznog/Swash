-- =====================================================================
-- TIDE — duel en ligne
-- À exécuter dans Supabase > SQL Editor, une seule fois.
-- Idiome repris du projet Territoire : auth anonyme, code d'adhésion,
-- temps réel sur postgres_changes.
-- =====================================================================

-- ---------- table ----------
create table if not exists public.partie (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  jeu        text not null default 'classic',      -- 'classic' | 'plus'
  hote       uuid not null references auth.users(id),
  invite     uuid          references auth.users(id),
  statut     text not null default 'attente',      -- attente | en_cours | termine
  ply        int  not null default 0,              -- numéro du dernier coup appliqué
  trait      int  not null default 1,              -- 1 = bleu, 2 = rouge
  coup       jsonb,                                -- dernier coup : {src,dst}
  plateau    text,                                 -- position après ce coup (contrôle)
  resultat   jsonb,                                -- {winner,reason} une fois terminé
  cree       timestamptz not null default now(),
  maj        timestamptz not null default now()
);

create index if not exists partie_code_idx on public.partie(code);

-- ---------- sécurité ----------
alter table public.partie enable row level security;

drop policy if exists partie_lecture on public.partie;
create policy partie_lecture on public.partie
  for select using (auth.uid() = hote or auth.uid() = invite);

-- Aucune écriture directe : tout passe par les fonctions ci-dessous.
-- (pas de policy insert/update/delete)

-- ---------- droits d'accès ----------
-- Nécessaire si "Automatically expose new tables" est décoché à la création
-- du projet : sans ce grant, ni l'API ni le temps réel ne voient la table.
grant usage on schema public to authenticated;
grant select on table public.partie to authenticated;
-- Aucun insert/update/delete : tout passe par les fonctions plus bas.

-- ---------- temps réel ----------
alter publication supabase_realtime add table public.partie;
alter table public.partie replica identity full;

-- ---------- création ----------
create or replace function public.creer_partie(p_jeu text default 'classic')
returns table(partie_id uuid, code text)
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_id   uuid;
  v_essais int := 0;
begin
  if auth.uid() is null then raise exception 'authentification requise'; end if;

  loop
    -- code à 4 caractères, sans I O 0 1 pour éviter les confusions
    v_code := (
      select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                               (floor(random()*32)+1)::int, 1), '')
      from generate_series(1,4)
    );
    exit when not exists (select 1 from partie where partie.code = v_code
                          and statut <> 'termine');
    v_essais := v_essais + 1;
    if v_essais > 20 then raise exception 'aucun code disponible'; end if;
  end loop;

  insert into partie(code, jeu, hote) values (v_code, p_jeu, auth.uid())
  returning id into v_id;

  return query select v_id, v_code;
end $$;

-- ---------- adhésion ----------
create or replace function public.rejoindre_partie(p_code text)
returns table(partie_id uuid, jeu text)
language plpgsql security definer set search_path = public as $$
declare r partie%rowtype;
begin
  if auth.uid() is null then raise exception 'authentification requise'; end if;

  select * into r from partie
   where code = upper(trim(p_code)) and statut = 'attente'
   order by cree desc limit 1;

  if not found then raise exception 'code inconnu ou partie déjà commencée'; end if;
  if r.hote = auth.uid() then raise exception 'vous êtes déjà l''hôte de cette partie'; end if;

  update partie set invite = auth.uid(), statut = 'en_cours', maj = now()
   where id = r.id;

  return query select r.id, r.jeu;
end $$;

-- ---------- jouer un coup ----------
-- p_ply est le numéro du coup joué. Le serveur refuse s'il ne suit pas
-- le dernier enregistré : c'est la protection contre les doublons et les
-- écritures simultanées.
create or replace function public.jouer_coup(
  p_id uuid, p_ply int, p_coup jsonb, p_plateau text,
  p_trait int, p_resultat jsonb default null)
returns void
language plpgsql security definer set search_path = public as $$
declare r partie%rowtype; v_moi int;
begin
  select * into r from partie where id = p_id for update;
  if not found then raise exception 'partie inconnue'; end if;

  if    auth.uid() = r.hote   then v_moi := 1;
  elsif auth.uid() = r.invite then v_moi := 2;
  else  raise exception 'vous ne participez pas à cette partie'; end if;

  if r.statut = 'termine' then raise exception 'partie terminée'; end if;
  if r.trait <> v_moi     then raise exception 'ce n''est pas votre tour'; end if;
  if p_ply <> r.ply + 1   then raise exception 'coup désynchronisé'; end if;

  update partie set
    ply = p_ply, coup = p_coup, plateau = p_plateau, trait = p_trait,
    resultat = p_resultat,
    statut = case when p_resultat is null then 'en_cours' else 'termine' end,
    maj = now()
  where id = p_id;
end $$;

-- ---------- abandon ----------
create or replace function public.quitter_partie(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare r partie%rowtype; v_moi int;
begin
  select * into r from partie where id = p_id for update;
  if not found then return; end if;
  if    auth.uid() = r.hote   then v_moi := 1;
  elsif auth.uid() = r.invite then v_moi := 2;
  else return; end if;
  update partie set statut = 'termine', maj = now(),
    resultat = jsonb_build_object('winner', 3 - v_moi, 'reason', 'abandon')
  where id = p_id and statut <> 'termine';
end $$;

grant execute on function public.creer_partie(text)                          to authenticated;
grant execute on function public.rejoindre_partie(text)                      to authenticated;
grant execute on function public.jouer_coup(uuid,int,jsonb,text,int,jsonb)   to authenticated;
grant execute on function public.quitter_partie(uuid)                        to authenticated;

-- ---------- ménage (facultatif) ----------
-- delete from partie where maj < now() - interval '2 days';
