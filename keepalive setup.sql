-- TIDE — Table de keep-alive Supabase
--
-- À exécuter une seule fois dans : Supabase Dashboard > SQL Editor > New query
--
-- Rôle : fournir une cible de lecture minimale et sans risque pour le ping
-- automatisé, sans exposer la moindre donnée de jeu. On ne tape volontairement
-- pas sur les tables de parties, dont la RLS doit rester stricte.

-- 1. Table (une seule ligne, quelques octets)
create table if not exists public.keepalive (
  id  smallint primary key,
  ts  timestamptz not null default now()
);

-- 2. Ligne unique
insert into public.keepalive (id)
values (1)
on conflict (id) do nothing;

-- 3. RLS activée (obligatoire : sans ça, la table serait ouverte en écriture)
alter table public.keepalive enable row level security;

-- 4. Lecture seule pour les rôles anonyme et authentifié.
--    Aucune policy d'insert / update / delete n'est créée : la table est donc
--    strictement non modifiable depuis l'API publique.
drop policy if exists "keepalive_read" on public.keepalive;

create policy "keepalive_read"
  on public.keepalive
  for select
  to anon, authenticated
  using (true);

-- 5. Vérification — doit renvoyer exactement une ligne
select * from public.keepalive;


-- ----------------------------------------------------------------------------
-- Test en ligne de commande (facultatif, depuis ton poste)
-- Remplacer <ANON_KEY> par la clé anon du projet.
--
-- curl -i "https://yrxrsiekwsefrjadbmgv.supabase.co/rest/v1/keepalive?select=id&limit=1" \
--   -H "apikey: <ANON_KEY>" \
--   -H "Authorization: Bearer <ANON_KEY>"
--
-- Attendu : HTTP/2 200 et un corps de réponse [{"id":1}]
-- ----------------------------------------------------------------------------
