-- Fonctions appelées par WF1 via l'API Supabase (/rest/v1/rpc/...)
-- Script complet : tables puis fonctions. À exécuter en une fois dans le SQL Editor de Supabase.

CREATE TABLE IF NOT EXISTS appels_offres (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  contractfolderid     text UNIQUE,
  idwebs               text[] NOT NULL,
  id_derniere_annonce  text,
  url_derniere_annonce text,
  statut               text DEFAULT 'ouvert',   -- ouvert, rectifie, attribue
  version              int  DEFAULT 1,
  -- champs structurés
  objet text, acheteur text, date_parution date, date_limite timestamptz,
  departements text[], code_postal text, nuts text, type_marche text[], cpv text[],
  nb_lots int, adapte_pme boolean, date_debut date, date_fin date,
  budget_projet numeric, budget_lots numeric, budget_incoherent boolean,
  hash_texte text,
  -- champs LLM
  resume text, secteur text, budget_texte numeric, duree text,
  exigences_particulieres text, lots_resume text,
  prompt_version text, model text,
  date_creation timestamptz DEFAULT now(),
  date_maj      timestamptz
);
CREATE INDEX IF NOT EXISTS idx_appels_offres_idwebs ON appels_offres USING GIN (idwebs);

CREATE TABLE IF NOT EXISTS annonces_boamp (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_marche        bigint REFERENCES appels_offres(id),
  idweb            text UNIQUE NOT NULL,
  nature           text,
  etat             text,
  date_parution    date,
  motif_changement text,
  texte_llm        text,
  donnees_brutes   jsonb,
  date_reception   timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS erreurs_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workflow text, etape text, idweb text, message text,
  donnees jsonb, date_erreur timestamptz DEFAULT now()
);

-- RLS activée sans politique : clé anon bloquée, service_role (n8n) non concernée
ALTER TABLE appels_offres  ENABLE ROW LEVEL SECURITY;
ALTER TABLE annonces_boamp ENABLE ROW LEVEL SECURITY;
ALTER TABLE erreurs_log    ENABLE ROW LEVEL SECURITY;

-- Étape 5 : doublon, marché existant, et hash du texte du marché
CREATE OR REPLACE FUNCTION wf1_verifier(p_idweb text, p_contractfolderid text, p_annonce_lie text[])
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH m AS (
    SELECT id, hash_texte FROM appels_offres
    WHERE (NULLIF(p_contractfolderid, '') IS NOT NULL AND contractfolderid = p_contractfolderid)
       OR (COALESCE(cardinality(p_annonce_lie), 0) > 0 AND idwebs && p_annonce_lie)
    ORDER BY (contractfolderid = p_contractfolderid) DESC NULLS LAST, id
    LIMIT 1)
  SELECT jsonb_build_object(
    'deja_traitee', EXISTS (SELECT 1 FROM annonces_boamp WHERE idweb = p_idweb),
    'id_marche',    (SELECT id FROM m),
    'hash_texte',   (SELECT hash_texte FROM m));
$$;

-- Branche B : mise à jour (sans LLM si p_llm est null, complète sinon)
CREATE OR REPLACE FUNCTION wf1_maj_marche(
  p_id bigint, p_idweb text, p_url text DEFAULT NULL,
  p_date_limite timestamptz DEFAULT NULL, p_date_debut date DEFAULT NULL, p_date_fin date DEFAULT NULL,
  p_budget_projet numeric DEFAULT NULL, p_budget_lots numeric DEFAULT NULL,
  p_hash_texte text DEFAULT NULL, p_llm jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  UPDATE appels_offres SET
    idwebs               = array_append(idwebs, p_idweb),
    id_derniere_annonce  = p_idweb,
    url_derniere_annonce = COALESCE(p_url, url_derniere_annonce),
    date_limite   = COALESCE(p_date_limite, date_limite),
    date_debut    = COALESCE(p_date_debut, date_debut),
    date_fin      = COALESCE(p_date_fin, date_fin),
    budget_projet = COALESCE(p_budget_projet, budget_projet),
    budget_lots   = COALESCE(p_budget_lots, budget_lots),
    hash_texte    = COALESCE(p_hash_texte, hash_texte),
    resume        = COALESCE(NULLIF(p_llm->>'resume', ''), resume),
    secteur       = COALESCE(NULLIF(p_llm->>'secteur', ''), secteur),
    budget_texte  = CASE WHEN p_llm IS NULL THEN budget_texte ELSE (p_llm->>'budget_texte')::numeric END,
    duree         = COALESCE(NULLIF(p_llm->>'duree', ''), duree),
    exigences_particulieres = COALESCE(NULLIF(p_llm->>'exigences_particulieres', ''), exigences_particulieres),
    lots_resume   = COALESCE(NULLIF(p_llm->>'lots_resume', ''), lots_resume),
    prompt_version = COALESCE(p_llm->>'prompt_version', prompt_version),
    model          = COALESCE(p_llm->>'model', model),
    statut = 'rectifie', version = version + 1, date_maj = now()
  WHERE id = p_id
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id);
END $$;

-- Branche B : historique des textes du marché
CREATE OR REPLACE FUNCTION wf1_historique_textes(p_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('id_marche', p_id, 'historique',
    string_agg('Annonce du ' || date_parution || ' (' || etat || ') :' || E'\n' || texte_llm,
               E'\n\n' ORDER BY date_parution, id))
  FROM annonces_boamp WHERE id_marche = p_id;
$$;

-- Branche C : attribution (ne modifie rien si le marché n'est pas en base)
CREATE OR REPLACE FUNCTION wf1_attribuer(p_id bigint, p_idweb text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  UPDATE appels_offres SET
    statut = 'attribue', idwebs = array_append(idwebs, p_idweb),
    id_derniere_annonce = p_idweb, date_maj = now()
  WHERE id = p_id
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id);
END $$;

-- Seule la clé service_role (celle de l'identifiant n8n) peut appeler ces fonctions
REVOKE EXECUTE ON FUNCTION wf1_verifier(text, text, text[]), wf1_maj_marche(bigint, text, text, timestamptz, date, date, numeric, numeric, text, jsonb),
  wf1_historique_textes(bigint), wf1_attribuer(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION wf1_verifier(text, text, text[]), wf1_maj_marche(bigint, text, text, timestamptz, date, date, numeric, numeric, text, jsonb),
  wf1_historique_textes(bigint), wf1_attribuer(bigint, text) TO service_role;

NOTIFY pgrst, 'reload schema';

-- =====================================================================
-- WF4 · Évaluation de l'extraction LLM (Supabase SQL Editor)
-- Sans danger à relancer.
-- =====================================================================

-- ---------- 1. Jeu de référence (à étiqueter à la main) ----------
CREATE TABLE IF NOT EXISTS evaluation_reference (
  idweb          text PRIMARY KEY,
  texte_llm      text NOT NULL,      -- texte exact envoyé au LLM en production
  cas_teste      text,               -- ex. « budget contradictoire », « groupement solidaire »
  secteur_ref    text,               -- une des 12 valeurs
  budget_ref     numeric,            -- vide si aucun montant total clair
  duree_ref      text,               -- vide si absente ; ex. « 12 mois, reconductible 3 fois »
  exigences_ref  text,               -- éléments séparés par « ; », vide si aucune
  etiquete_par   text,
  etiquete       boolean NOT NULL DEFAULT false   -- passer à true une fois l'étiquetage terminé
);

-- Remplissage initial : 20 annonces initiales au hasard (les colonnes *_ref restent à remplir)
INSERT INTO evaluation_reference (idweb, texte_llm)
SELECT idweb, texte_llm FROM annonces_boamp
WHERE etat = 'INITIAL' AND texte_llm IS NOT NULL
ORDER BY random()
LIMIT 20
ON CONFLICT (idweb) DO NOTHING;

-- ---------- 2. Résultats détaillés ----------
CREATE TABLE IF NOT EXISTS evaluation_resultats (
  id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  date   timestamptz NOT NULL DEFAULT now(),
  run    text NOT NULL,
  idweb  text NOT NULL
);
ALTER TABLE evaluation_resultats
  ADD COLUMN IF NOT EXISTS prompt_version         text,
  ADD COLUMN IF NOT EXISTS model                  text,
  ADD COLUMN IF NOT EXISTS format_ok              int,
  ADD COLUMN IF NOT EXISTS parse_erreur           text,
  ADD COLUMN IF NOT EXISTS secteur_llm            text,
  ADD COLUMN IF NOT EXISTS secteur_ok             int,
  ADD COLUMN IF NOT EXISTS budget_llm             numeric,
  ADD COLUMN IF NOT EXISTS budget_statut          text,     -- VP, FP, FN, VN
  ADD COLUMN IF NOT EXISTS duree_llm              text,
  ADD COLUMN IF NOT EXISTS duree_statut           text,     -- VP, FP, FN, VN
  ADD COLUMN IF NOT EXISTS resume                 text,
  ADD COLUMN IF NOT EXISTS resume_mots            int,
  ADD COLUMN IF NOT EXISTS resume_longueur_ok     int,
  ADD COLUMN IF NOT EXISTS exigences_llm          text,
  ADD COLUMN IF NOT EXISTS exigences_rappel       numeric,  -- part des exigences de référence retrouvées
  ADD COLUMN IF NOT EXISTS exigences_ancrage      numeric,  -- part des exigences du LLM présentes dans le texte
  ADD COLUMN IF NOT EXISTS faithfulness           int,      -- 1 = rien d'inventé (budget, durée, exigences)
  ADD COLUMN IF NOT EXISTS juge_resume_fidele     int,
  ADD COLUMN IF NOT EXISTS juge_resume_clarte     int,      -- 1 à 5
  ADD COLUMN IF NOT EXISTS juge_exigences_fideles int,
  ADD COLUMN IF NOT EXISTS juge_justification    text;

-- ---------- 3. Fonctions ----------
DROP FUNCTION IF EXISTS eval_enregistrer;
DROP FUNCTION IF EXISTS eval_rapport;

-- Enregistre le résultat d'une annonce -> { id }
CREATE FUNCTION eval_enregistrer(p jsonb)
RETURNS jsonb LANGUAGE sql AS $$
  INSERT INTO evaluation_resultats (
    run, idweb, prompt_version, model, format_ok, parse_erreur,
    secteur_llm, secteur_ok, budget_llm, budget_statut, duree_llm, duree_statut,
    resume, resume_mots, resume_longueur_ok, exigences_llm, exigences_rappel, exigences_ancrage,
    faithfulness, juge_resume_fidele, juge_resume_clarte, juge_exigences_fideles, juge_justification)
  VALUES (
    p->>'run', p->>'idweb', p->>'prompt_version', p->>'model', (p->>'format_ok')::int, p->>'parse_erreur',
    p->>'secteur', (p->>'secteur_ok')::int, (p->>'budget_texte')::numeric, p->>'budget_statut',
    p->>'duree', p->>'duree_statut',
    p->>'resume', (p->>'resume_mots')::int, (p->>'resume_longueur_ok')::int,
    p->>'exigences_particulieres', (p->>'exigences_rappel')::numeric, (p->>'exigences_ancrage')::numeric,
    (p->>'faithfulness')::int, (p->>'juge_resume_fidele')::int, (p->>'juge_resume_clarte')::int,
    (p->>'juge_exigences_fideles')::int, p->>'juge_justification')
  RETURNING jsonb_build_object('id', id);
$$;

-- Rapport d'un run + stabilité sur tous les runs de la même version de prompt
CREATE FUNCTION eval_rapport(p_run text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT * FROM evaluation_resultats WHERE run = p_run),
  pv AS (SELECT max(prompt_version) AS v FROM r),
  stab AS (
    SELECT idweb, count(DISTINCT run) AS nb_runs, count(DISTINCT secteur_llm) AS nb_secteurs
    FROM evaluation_resultats, pv
    WHERE prompt_version = pv.v AND secteur_llm IS NOT NULL
    GROUP BY idweb
  ),
  pct AS (SELECT
    count(*) AS n,
    round(100.0 * avg(format_ok)) AS format_pct,
    round(100.0 * avg(secteur_ok)) AS secteur_pct,
    round(100.0 * count(*) FILTER (WHERE budget_statut = 'VP') / NULLIF(count(*) FILTER (WHERE budget_statut IN ('VP','FP')), 0)) AS budget_precision_pct,
    round(100.0 * count(*) FILTER (WHERE budget_statut = 'VP') / NULLIF(count(*) FILTER (WHERE budget_statut IN ('VP','FN')), 0)) AS budget_rappel_pct,
    round(100.0 * count(*) FILTER (WHERE duree_statut = 'VP') / NULLIF(count(*) FILTER (WHERE duree_statut IN ('VP','FP')), 0)) AS duree_precision_pct,
    round(100.0 * count(*) FILTER (WHERE duree_statut = 'VP') / NULLIF(count(*) FILTER (WHERE duree_statut IN ('VP','FN')), 0)) AS duree_rappel_pct,
    round(100.0 * avg(faithfulness)) AS faithfulness_pct,
    round(100.0 * avg(exigences_rappel)) AS exigences_rappel_pct,
    round(100.0 * avg(exigences_ancrage)) AS exigences_ancrage_pct,
    round(100.0 * avg(resume_longueur_ok)) AS resume_longueur_pct,
    round(100.0 * avg(juge_resume_fidele)) AS juge_resume_fidele_pct,
    round(avg(juge_resume_clarte), 1) AS juge_clarte_moyenne,
    round(100.0 * avg(juge_exigences_fideles)) AS juge_exigences_fideles_pct
    FROM r)
  SELECT jsonb_build_object(
    'run', p_run,
    'prompt_version', (SELECT v FROM pv),
    'metriques', to_jsonb(pct.*),
    'stabilite', jsonb_build_object(
      'annonces_multi_runs', (SELECT count(*) FROM stab WHERE nb_runs >= 2),
      'stabilite_secteur_pct', (SELECT round(100.0 * count(*) FILTER (WHERE nb_secteurs = 1) / NULLIF(count(*), 0)) FROM stab WHERE nb_runs >= 2)),
    'erreurs', COALESCE((SELECT jsonb_agg(e) FROM (
        SELECT jsonb_build_object('idweb', idweb, 'probleme', concat_ws(' ; ',
          CASE WHEN format_ok = 0 THEN 'format : ' || COALESCE(parse_erreur, 'JSON invalide') END,
          CASE WHEN secteur_ok = 0 AND format_ok = 1 THEN 'secteur : ' || COALESCE(secteur_llm, 'vide') END,
          CASE WHEN budget_statut IN ('FP','FN') THEN 'budget ' || budget_statut || ' (' || COALESCE(budget_llm::text, 'null') || ')' END,
          CASE WHEN duree_statut IN ('FP','FN') THEN 'durée ' || duree_statut END,
          CASE WHEN faithfulness = 0 THEN 'information inventée' END,
          CASE WHEN juge_resume_fidele = 0 THEN 'résumé non fidèle (juge)' END)) AS e
        FROM r
        WHERE format_ok = 0 OR secteur_ok = 0 OR budget_statut IN ('FP','FN') OR duree_statut IN ('FP','FN')
           OR faithfulness = 0 OR juge_resume_fidele = 0
        LIMIT 15) x), '[]'::jsonb))
  FROM pct;
$$;