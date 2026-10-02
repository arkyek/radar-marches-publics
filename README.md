# Radar Marchés Publics

Veille automatisée des appels d'offres publics pour les PME et les freelances.

Chaque jour, le pipeline récupère les annonces du BOAMP, les fait analyser par un LLM (résumé, secteur, budget, durée, exigences), les stocke dans PostgreSQL, puis envoie à chaque profil un e-mail avec uniquement les marchés qui le concernent. Un assistant conversationnel (RAG) permet aussi d'interroger les marchés en langage naturel.

**Stack** : n8n · PostgreSQL et pgvector (Supabase) · OpenAI `gpt-4o-mini` (analyse) et `gpt-4o` (juge d'évaluation) · SMTP

---

## Architecture

```
API BOAMP ──► WF1 Collecte et analyse ──► appels_offres + annonces_boamp + documents
                                                 │
                    ┌────────────────────────────┼────────────────────────────┐
                    ▼                            ▼                            ▼
             WF2 Digest (8 h)           WF6 Assistant RAG             WF4 Évaluation
             e-mail par profil          chat en langage naturel       scores + verdict GO / NO-GO
```

| Workflow | Déclencheur | Rôle |
|---|---|---|
| **WF1** Collecte et analyse | Tous les jours à 7 h + manuel | BOAMP → LLM → base de données → indexation RAG |
| **WF2** Digest | Tous les jours à 8 h + manuel | Sélection SQL par profil → phrase LLM → e-mail |
| **WF4** Évaluation | Manuel | Mesure la qualité de l'analyse LLM du WF1 |
| **WF6** Assistant RAG | Message dans le chat | Recherche sémantique + informations à jour |

---

## Base de données (Supabase)

Installation : exécuter `radar_01_installation.sql` puis `wf4_evaluation.sql` dans le SQL Editor. Les deux scripts peuvent être relancés sans risque.

| Table | Une ligne = | Rôle |
|---|---|---|
| `appels_offres` | un marché | État actuel, version la plus récente. Notre propre `id`, et tous les idweb BOAMP dans `idwebs` |
| `annonces_boamp` | une annonce reçue | Historique complet. `idweb` unique = pas de doublon |
| `documents` | un marché indexé | Embeddings pour le RAG (dimension 1536) |
| `digests_envoyes` | un marché envoyé à un profil | Évite les renvois ; renvoie un marché rectifié avec « Mis à jour » |
| `erreurs_log` | une erreur | Journal des échecs (LLM, profil invalide…) |
| `evaluation_reference` | une annonce de test | Corrigé rédigé à la main pour l'évaluation |
| `evaluation_resultats` | une annonce évaluée dans un run | Réponses du LLM et leurs notes |

**Fonctions RPC** appelées par les workflows :

| Fonction | Utilisée par | Rôle |
|---|---|---|
| `wf1_verifier` | WF1 | Annonce déjà traitée ? Marché déjà connu ? |
| `wf1_maj_marche` | WF1 | Applique un rectificatif (sans effacer les valeurs connues) |
| `wf1_historique_textes` | WF1 | Textes de toutes les annonces d'un marché |
| `wf1_attribuer` | WF1 | Passe un marché au statut « attribué » |
| `wf2_selection` | WF2 | Marchés à envoyer à un profil |
| `wf2_noter_envois` | WF2 | Enregistre les versions envoyées |
| `match_documents` | WF6 | Recherche par similarité dans `documents` |
| `rag_details_marches` | WF6 | Informations à jour des marchés trouvés, filtrées |
| `eval_enregistrer`, `eval_rapport` | WF4 | Enregistre les notes, calcule les scores |

Requêtes de suivi, de contrôle et de remise à zéro : `radar_02_requetes_utiles.sql`.

---

## WF1 · Collecte et analyse

**Objectif** : transformer les annonces du BOAMP en fiches de marché exploitables, sans doublon, en gérant le cycle de vie d'un marché (initial, rectificatif, attribution).

**Déroulé**
1. **API BOAMP** : annonces de la veille (`APPEL_OFFRE` et `ATTRIBUTION`), 20 maximum, de la plus ancienne à la plus récente.
2. **Préparation** (code) : extrait les champs structurés (dates, acheteur, départements, CPV, lots, budgets, PME) et construit un texte nettoyé de 4 000 caractères maximum pour le LLM.
3. **Hash texte** : empreinte du texte, pour savoir s'il a changé.
4. **Vérifications** : l'annonce est-elle déjà traitée ? Le marché existe-t-il (`contractfolderid` ou `annonce_lie`) ?
5. **Switch**, selon le type d'annonce :
   - **A. Nouveau marché** : analyse LLM → création dans `appels_offres` → indexation dans `documents` ;
   - **B. Mise à jour** : si le texte est identique, mise à jour des champs structurés sans LLM ; sinon, analyse LLM de tout l'historique du marché, puis mise à jour ;
   - **C. Attribution** : le marché passe au statut « attribué ».
6. **Historique** : chaque annonce est enregistrée dans `annonces_boamp`.

**Analyse LLM** : `gpt-4o-mini`, temperature 0, sortie JSON imposée par un Structured Output Parser. Champs produits : `resume`, `secteur` (12 valeurs, voir plus bas), `exigences_particulieres`, `lots_resume`, `duree`, `budget_texte`. Règle centrale : rien d'inventé, `null` si l'information est absente.

**En cas d'échec du LLM** : l'annonce est écrite dans `erreurs_log`, mais pas dans l'historique, pour être retentée le lendemain.

---

## WF2 · Digest quotidien

**Objectif** : envoyer à chaque profil les marchés nouveaux ou mis à jour qui lui correspondent, jamais deux fois la même version.

**Déroulé**
1. **Profils** : liste des profils en JSON (nœud *Edit Fields*, en attendant une table `profils`).
2. **Vérifier le profil** (code) : corrige les petites erreurs (majuscules, « 1 » → « 01 »), rejette les profils invalides vers `erreurs_log`.
3. **Pour chaque profil** :
   - **Sélection** (SQL, sans LLM) : marché ouvert ou rectifié, date limite à plus de 3 jours, secteur et département du profil, budget au-dessus du minimum, pas encore envoyé dans cette version. 10 marchés maximum ;
   - **Raisons par marché** (LLM) : une phrase « pourquoi ce marché vous concerne », un seul appel pour tous les marchés du profil ;
   - **Composer email** → **Envoi** (SMTP) → **Noter les envois**.

**Format d'un profil**

```json
{
  "id": "av-pro-paris",
  "nom": "AV Pro Paris",
  "email": "contact@exemple.fr",
  "activite": "Installation et maintenance de matériel audiovisuel",
  "secteurs": ["audiovisuel et équipements"],
  "departements": ["75", "92", "93", "94"],
  "budget_min": 50000,
  "pme_seulement": false
}
```

L'`id` identifie le profil : plusieurs profils peuvent partager la même adresse e-mail.

---

## WF6 · Assistant RAG

**Objectif** : répondre à « Quels marchés pour mon entreprise ? » en langage naturel, sans jamais inventer.

**Composants** : Chat Trigger → AI Agent (`gpt-4o-mini`, mémoire de 6 échanges) avec deux outils :
- **`recherche_semantique`** : trouve les marchés proches de l'activité, dans `documents` ;
- **`details_marches`** : lit les informations **à jour** dans `appels_offres` via `rag_details_marches`.

**Démarche de l'agent**
1. Traduit le profil en métier, secteurs et départements (Lyon → 69, 01, 38, 42).
2. Recherche sémantique, puis lecture des informations à jour avec les filtres secteur et département.
3. Retient un marché seulement si la prestation relève directement du métier.
4. Répond avec 5 marchés maximum, ou « Aucun marché ne correspond » quand c'est le cas.

Les filtres de statut, de date, de secteur et de département sont appliqués **par la base**, pas par l'agent : un marché hors sujet ne peut pas arriver jusqu'à lui.

---

## WF4 · Évaluation

**Objectif** : mesurer la qualité de l'analyse LLM du WF1 avant la mise en production, et comparer les versions du prompt.

**Principe** : un corrigé rédigé à la main (`evaluation_reference`), le même prompt qu'en production, puis une correction automatique.

**Déroulé**
1. **Annonces étiquetées** : lignes de `evaluation_reference` avec `etiquete = true`.
2. **Analyse annonce** : même prompt et même modèle que le WF1.
3. **Graders** (code) : format, secteur, budget et durée en VP / FP / FN / VN, rappel et ancrage des exigences, faithfulness.
4. **Juge** (`gpt-4o`) : fidélité et clarté du résumé, fidélité des exigences.
5. **Enregistrement** dans `evaluation_resultats`, puis **Rapport** et **Verdict**.

**Les trois dimensions mesurées**

| Dimension | Contrôles | Méthode |
|---|---|---|
| Format compliance | JSON valide, secteur dans la liste, résumé ≤ 25 mots | Code |
| Output correctness | Secteur, précision et rappel du budget et de la durée, rappel des exigences | Code, comparé au corrigé |
| Faithfulness | Rien d'inventé, exigences ancrées dans le texte, résumé fidèle | Proxy par mots-clés + juge LLM |
| Stabilité | Même secteur d'un run à l'autre | Comparaison de plusieurs runs |

**Verdict** : chaque score est comparé à son seuil (par exemple 95 % pour la précision du budget). **GO** si tous sont atteints, **NO-GO** si un seul échoue, **INCOMPLET** si une mesure manque (la stabilité au premier run).

**Utilisation** : étiqueter au moins 20 annonces (30 à 50 avant une vraie mise en production), lancer le WF4 trois fois, lire le verdict et la liste des erreurs. Après chaque modification du prompt du WF1, recopier le prompt dans le WF4 et changer `prompt_version`.

---

## Référentiel des secteurs

La même liste de 12 valeurs est utilisée partout : prompt d'analyse, schéma du parser, profils, prompt de l'agent.

`BTP et travaux` · `informatique et numérique` · `audiovisuel et équipements` · `conseil et études` · `formation` · `nettoyage et services` · `espaces verts` · `transport et logistique` · `santé` · `restauration` · `communication et événementiel` · `autre`

Toute modification doit être reportée aux quatre endroits.

---

## Lancer une démo

1. **WF1** (Manual Trigger) : collecte et analyse ; vérifier `appels_offres` et `documents`.
2. **Relancer WF1** : rien ne doit changer (anti-doublon).
3. **WF2** (Manual Trigger) : les e-mails arrivent ; relancer, aucun nouvel envoi.
4. **WF6** : poser une question dans le chat ; vérifier dans l'exécution les appels à `recherche_semantique` puis `details_marches`.
5. **WF4** : afficher le verdict et le tableau des scores.

Remises à zéro utiles pour une nouvelle démo : section F de `radar_02_requetes_utiles.sql`.

---

## Conventions

- **Un seul projet Supabase** pour toute l'équipe, et le même dans tous les workflows (nœud *Config* et credentials).
- **Aucun secret dans les nœuds** : clés et mots de passe uniquement dans les credentials n8n. Utiliser la clé `service_role` pour Supabase.
- **Noms de nœuds** : les expressions `$('Nom du nœud')` en dépendent ; ne pas renommer un nœud sans mettre à jour ses références.
- **Versions du prompt** : `prompt_version` est enregistré avec chaque marché et chaque évaluation (`wf1-v1`, `wf1-v2`…).
- **Export** : exporter les workflows en JSON dans le dépôt après chaque modification.

## Limites connues

- Un marché rectifié avec un nouveau texte n'est pas réindexé dans `documents` ; l'agent lit toutefois les informations à jour via `details_marches`.
- Le secteur `communication et événementiel` regroupe des activités très différentes (communication digitale, hôtessariat, impression) ; à séparer dans une prochaine version.
- Les profils sont saisis dans un nœud du WF2 ; une table `profils` avec un formulaire est prévue.
