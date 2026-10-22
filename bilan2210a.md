# Bilan de mission — 22/10/2026 — `bilan2210a.md`

> **Objectif :** livrer l'app Flutter Corsian-Battle branchée au multijoueur en ligne
> (auth + REST + WebSocket), avec un build APK par GitHub Actions qui passe.
>
> **Verdict : atteint.** Les 4 branches sont vertes, l'app dialogue avec le serveur
> (REST + WebSocket), et la CI construit l'APK debug, l'APK release et l'AAB.
> Deux réserves subsistent, détaillées en §6.

| | |
|---|---|
| **Période** | 22/10/2026, 02:10 → 04:16 UTC (≈ 2 h 06 de commits, ≈ 3 h 18 de session) |
| **Branche de travail** | `feat/app-en-ligne-ws` |
| **Commits** | 20 (de `3cdfd4b` à `2a38c0a`) |
| **Volume** | 47 fichiers, +4 667 / −79 lignes sur `app/` et `.github/` |
| **CI** | 4 runs verts (`main`, `feat/app-en-ligne-ws`, `docs/spec-multijoueur-en-ligne`, `feat/serveur-s2b-fenetre-doublon`) |
| **Tests** | 10 tests Dart verts, dont une partie en ligne complète |

---

## 1. Ce que la mission a corrigé

Sept bugs de fond, dont trois rendaient l'app **inutilisable** en conditions réelles.

### 1.1 Les URL de production étaient relatives — l'app ne pouvait rien joindre

`ConfigurationReseau.production` ne portait **aucune origine** : les URL produites
étaient relatives (`/corsian-battle/api/auth/invite`), sans scheme. C'est juste
pour une *web app* servie par nginx, qui sait d'où elle vient. Une application
Android n'a pas de page web à qui poser la question : **toute requête partait
vers rien**.

- `production` porte désormais l'origine publique explicite (`https://soft.opik.net`),
  d'où des URL `https://` et un WebSocket `wss://`.
- `depuisDefines()` était du **code mort** : il est branché sur les quatre clients.
  `--dart-define=HOST_IP=…` et `MODE_DEV` fonctionnent enfin.
- L'écran d'accueil partage une seule instance de configuration entre le REST, la
  session et la socket — sinon la table créée d'un côté n'était pas celle rejointe
  de l'autre.

> Commit `b814673`. Verrouillé par `app/test/config_reseau_test.dart` (5 tests).

### 1.2 Le joueur ne voyait jamais sa carte du dessus

Le serveur place `ma_carte` dans l'**objet du siège** (`serveur/jeu/table.py`,
`instantane()`) ; le client le lisait à la **racine** de l'instantané
(`json['ma_carte']`). La valeur arrivait donc toujours à `null`.

Conséquences en cascade :

- le joueur ne voyait **jamais** sa carte du dessus ;
- le flux `maCarte` (message privé `ta_carte_suivante`) était émis mais **jamais
  consommé** par l'écran ;
- `doublon_ouvert` ouvrait bien la fenêtre, mais rien n'était animé — et le
  joueur ne pouvait pas savoir **quelle** carte faisait doublon avant de taper.

Corrigé : `SiegeInfo` parse `ma_carte`, `EtatTable` le retrouve dans le siège de
ce client (jamais celui d'un autre), le client mémorise la carte et fusionne les
deux canaux (privé et instantané) sans s'écraser mutuellement. L'écran affiche
la carte du joueur et révèle celle du doublon au centre du tapis, avec pulsation.

> Commit `c6cc617`. Test `le joueur reçoit sa carte du dessus et voit le doublon
> s'ouvrir` : **il échoue sans le correctif** (timeout de 3 min) — il prouve donc
> le chemin complet, du serveur à l'écran.

### 1.3 L'app plantait au passage de la salle d'attente au tapis

Le flux `etats` de `ClientJeu` était un `async*` à abonnement unique : le second
`listen` (salle → écran de jeu) levait « Stream has already been listened to ».
Le flux est désormais **multi-abonnement**, avec rejeu de l'état courant à
l'abonnement — le `bienvenue` arrive souvent avant que l'UI ne s'abonne.

> Commit `50462b2`. Test `le flux des états accepte plusieurs abonnements successifs`.

### 1.4 La limite de création de compte bloquait les joueurs légitimes

Le quota était consommé **même par les appels idempotents** : un simple
redémarrage de l'app suffisait à se faire refuser. Le compteur ne consomme plus
que les vraies créations, et la limite par IP est passée de 5/h à 20/h
(`max_creations_compte_h`, réellement câblée sur le limiteur au lieu d'être en
dur dans le code).

> Commit `50462b2`.

### 1.5 La protection anti-rejeu du serveur refusait tous les coups d'un client synchronisé

`seq_attendu` était comparé à l'égalité stricte avec `table.seq` — un compteur
**global**, incrémenté par les messages privés adressés à *un autre* siège. Un
client parfaitement synchronisé se voyait donc refuser **tous** ses coups, et la
partie restait figée au tour de 12 s.

La comparaison est désormais faite **par siège** (`Siege.seq_pose`) : on refuse
un rejeu, pas la latence. Un client en retard reste accepté — il joue sur l'état
courant du serveur, qui reste l'unique autorité.

Le protocole était décrit avec l'ancienne sémantique : `docs/PROTOCOLE.md` §2 a
été corrigé en conséquence.

> Commits `36b0f4d` (doc) et le correctif serveur antérieur à cette session.

### 1.6 Le bandeau « connexion perdue » ne se refermait jamais

Le client se reconnectait tout seul (recul exponentiel 1→30 s), mais n'émettait
rien quand la socket rouvrait. L'alarme continuait donc à l'écran alors que la
partie avait repris.

Corrigé : le client expose un flux `reconnexions`, émis à chaque ouverture
réussie ; l'écran referme le bandeau dessus.

> Commit `e9e9e80`. Test `une reconnexion est signalée à l'écran`.

### 1.7 La suppression de compte n'était accessible nulle part dans l'UI

L'API existait (`DELETE /api/auth/compte`) mais aucun écran ne la proposait.
C'est une **exigence** : droit à l'effacement (RGPD) et politique Google Play,
qui impose que la suppression soit possible *depuis l'application*. Sans cela,
la publication restait bloquée.

Ajout d'un écran Compte (pseudo, identifiant technique, suppression après
confirmation explicite) et de `SessionJeu.supprimerCompte()`, qui supprime
d'abord chez le serveur puis oublie la session locale — un échec réseau ne doit
pas laisser l'app croire avoir supprimé un compte qui existe encore.

> Commit `1d04cb5`. Vérifié côté serveur : `DELETE /api/auth/compte` renvoie 204
> et le joueur disparaît de la base.

---

## 2. Ce que la mission a ajouté

### 2.1 Écran de salle d'attente

Le code à 6 caractères **est** l'invitation : affiché en très grand, copié dans le
presse-papier, partageable. Pastilles de sièges, bascule automatique vers
l'écran de jeu quand la table passe en jeu.

### 2.2 Écran de jeu en ligne complet

Éléments qui n'étaient pas affichés, ajoutés sans mot (l'UX universelle du projet
reste sans texte pendant la partie) :

| Élément | Source |
|---|---|
| Carte du dessus du joueur | `ta_carte_suivante` (privé) + `table_etat.sieges[n].ma_carte` |
| Carte du doublon, au centre, avec pulsation | `doublon_ouvert.cartes[1]` |
| Pli en cours | `table_etat.pli` |
| Défi ouvert : qui répond, combien de chances | `table_etat.defi` |
| Compte à rebours avant le lancement | `compte_a_rebours` |
| Bandeau « un joueur part » | `mouvements` |
| Bandeau de coupure refermé à la reconnexion | `reconnexions` |

Le flux `mouvements` recopiait les données **sans** le `type` : l'écran ne pouvait
pas savoir *quel* mouvement il recevait. Corrigé.

### 2.3 Reconnexion automatique

Recul exponentiel (1, 2, 4 … 30 s). Les fermetures définitives — 4404 table
absente, 4409 complète, 4413 protocole incompatible — ne reconnectent pas : elles
demandent une action au joueur.

### 2.4 Un seul `tape` par fenêtre

Le serveur ne retient que le **premier** envoi d'un siège ; en renvoyer plusieurs
serait compté comme une anomalie (et consigné en suspicion).

---

## 3. La chaîne de build

### 3.1 Ce que fait la CI

`.github/workflows/build-apk.yml` — 14 étapes, sur push, pull request vers `main`,
tag `v*` et `workflow_dispatch` :

1. `flutter analyze` — **bloquant**
2. `flutter test` — **bloquant** (le test d'intégration s'ignore seul si le
   serveur local est absent)
3. `flutter build apk --debug` → artefact `apk-debug` (74 Mo)
4. `flutter build apk --release` + `flutter build appbundle --release` →
   artefact `release-signe` (81 Mo) **ou** `release-non-signe`

### 3.2 La signature, par secrets — jamais par le dépôt

| Secret | Contenu |
|---|---|
| `KEYSTORE_BASE64` | `base64 -w0 corsian-battle-upload.jks` |
| `KEYSTORE_PASSWORD` | mot de passe du keystore |
| `KEY_ALIAS` | alias de la clé |
| `KEY_PASSWORD` | mot de passe de la clé |

`app/android/app/build.gradle.kts` reconstruit le keystore dans le répertoire de
build, hors du dépôt. **Sans** ces secrets, le build retombe sur les clés de
debug — et la CI **ne publie aucun artefact « signé »**, elle émet un
avertissement et nomme l'artefact `release-non-signe`. Elle ne prétend jamais
livrer un binaire publiable qu'elle ne signe pas vraiment.

### 3.3 Un tag publie une release

```bash
git tag -a v0.1.0 -m "Corsian Battle 0.1.0"
git push origin v0.1.0
```

Le tag déclenche la CI, qui publie une **release GitHub** avec l'APK signé, l'AAB
signé et leurs empreintes SHA-256. Procédure complète : `docs/DEPLOIEMENT.md` §7.1.

### 3.4 Un piège que la CI a révélé

La CI échouait sur le build release. GitHub Actions injecte les secrets
**absents** comme des variables d'environnement **VIDES**, pas comme des
variables manquantes : le test `!= null` laissait passer une chaîne vide, et le
décodage base64 échouait au milieu du build. La détection repose désormais sur
`isNotBlank()`.

Le build release est en outre lancé **même sans les secrets** : c'est la seule
façon de valider en continu que la configuration Gradle de signature reste
correcte. Avant, le premier run avec une vraie clé aurait pu être le premier
build release — et son premier échec.

> Commits `9d71ebf` et `7c33c80`.

### 3.5 Chaîne de signature validée de bout en bout

Trois configurations testées en local : secrets absents (chaînes vides) → build
OK, clés de debug ; secrets valides → build OK, APK signé avec la clé fournie
(empreinte SHA-256 vérifiée par `apksigner`) ; aucune variable du tout → build
OK, clés de debug.

---

## 4. Vérifications effectuées

| Vérification | Moyen | Résultat |
|---|---|---|
| Analyse statique | `flutter analyze` | 0 problème |
| Tests unitaires | `flutter test` | 10 verts |
| Partie en ligne complète | test d'intégration Dart, contre le serveur local | verte, enregistrée en base |
| Carte du joueur + doublon | test d'intégration dédié | vert — **échoue sans le correctif** |
| Table à 4 | recette `client_headless.py --joueurs 4` | 642 coups, 37 tapes/joueur, victoire |
| Suppression de compte | `DELETE /api/auth/compte` | 204, joueur absent de la base |
| Build debug | `flutter build apk --debug` | OK (149 Mo) |
| Build release | `flutter build apk --release` | OK (57 Mo) |
| Build AAB | `flutter build appbundle --release` | OK (55 Mo) |
| Manifest de l'APK | `aapt2 dump badging` | label « Corsian Battle », `INTERNET`, targetSdk 36 |
| Signature de l'APK | `apksigner verify --print-certs` | clé attendue |
| CI | 4 branches | vertes |
| Parties en base | `sqlite3` | 29 parties, dont `LFXMV6` (642 coups, victoire) |

---

## 5. Ce qui a été corrigé dans la documentation

La doc décrivait un état qui n'était plus vrai, ou décrivait mal le code :

- `docs/PROTOCOLE.md` §2 — sémantique de `seq_attendu` (par siège, pas globale)
- `docs/PROTOCOLE.md` §6 — `ma_carte` est dans l'objet du siège, pas à la racine
- `docs/ARCHITECTURE.md` §6.4 / §6.5 — configuration partagée, tableau de ce que
  l'écran en ligne affiche et d'où il le tient
- `docs/DEPLOIEMENT.md` §7.1 — procédure de keystore, de bout en bout
- `docs/DEPLOIEMENT.md` §9 — les trois contraintes CI classées « résolu »
- `docs/FEUILLE_DE_ROUTE.md` — état réel de S2 et de S5, avec les critères
  vérifiés cochés et les autres laissés ouverts
- `docs/CONFORMITE.md` — suppression de compte depuis l'app : **fait**
- `docs/ENDPOINTS.md` — la limite de création ne compte que les vraies créations
- `README.md` — build release, AAB, publication par tag

---

## 6. Ce qui reste à faire

### 6.1 Bloquant pour la publication

**La clé de signature de production n'existe pas encore.** La CI construit l'AAB
mais, sans les 4 secrets, elle le publie sous `release-non-signe`.

Pour publier :

1. créer le keystore (une seule fois, sur une machine de confiance) ;
2. renseigner les 4 secrets dans Settings → Secrets and variables → Actions ;
3. `git tag -a v0.1.0 && git push origin v0.1.0` ;
4. téléverser l'AAB dans la Play Console — **test interne d'abord**.

La fiche Play reste à faire : captures, description, classification IARC, Data
Safety, URL de politique de confidentialité et de suppression. La page web
`suppression-compte.html` (voie de suppression **sans** l'app installée) est
également à créer.

### 6.2 La réserve de validation

**L'app n'a jamais tourné sur un vrai appareil Android** — aucun émulateur n'est
disponible dans l'environnement de travail. La validation repose sur le test
d'intégration Dart, l'inspection de l'APK (`aapt2`, `apksigner`) et la recette
headless. Un test sur deux téléphones physiques reste nécessaire, en particulier
pour la **reconnexion en cours de partie** et le **tap sur doublon** — deux
comportements sensibles à la latence et au rendu.

### 6.3 Non traité, par choix

- **App Links natifs** : techniquement possibles maintenant que `android/` est
  versionné, mais non implémentés. L'invitation par code saisi fonctionne.
- **Matchmaking, classement, signalements** (S4) : hors périmètre de l'objectif.
- **Budget mémoire et politique de sauvegarde du keystore** (`DEPLOIEMENT.md`
  §10) : décisions d'exploitation.

---

## 7. Un mot sur la méthode

Une erreur de diagnostic a été commise en cours de route, et il est utile de la
consigner : le bilan du premier tour affirmait qu'un bug de « carte du dessous »
empêchait les doublons de se déclencher. **C'était faux** — le serveur envoyait
bien la carte du dessus, et le test serveur le prouvait déjà
(`serveur/tests/test_fenetre_doublon.py` : `cartes == ["5S", "5H"]`).

En vérifiant cette affirmation au lieu de la reprendre, un **vrai** bug a été
trouvé, différent et plus grave : la carte n'était pas lue au bon endroit dans
la structure JSON. Le test ajouté a ensuite été **invalidé volontairement** pour
vérifier qu'il échouait bien sans le correctif — sans cela, un test vert ne
prouve rien.

Le même principe a servi pour la CI : le premier run a **échoué** sur le build
release, et l'échec a été diagnosticé plutôt que contourné.

---

## 8. Repères

### Branches

Toutes à jour sur `2a38c0a` :

- `main`
- `feat/app-en-ligne-ws` (branche de travail)
- `docs/spec-multijoueur-en-ligne`
- `feat/serveur-s2b-fenetre-doublon`

### Arborescence de l'app livrée

```
app/lib/net/          config_reseau · client_auth · client_jeu_rest · client_jeu
                      modeles_proto · session_jeu · erreur_reseau
app/lib/screens/      ecran_accueil · ecran_salle · ecran_table_en_ligne
                      ecran_compte · ecran_table
app/test/             config_reseau_test · client_jeu_test · partie_en_ligne_test
.github/workflows/    build-apk.yml
```

### Commandes de recette

```bash
# Backend local (auth 8111 + jeu 8112)
bash serveur/lancer_local.sh

# Tests Dart (l'intégration s'ignore si le serveur est absent)
cd app && flutter analyze && flutter test

# Partie à 4 joueurs, sans interface
.venv/bin/python serveur/tests/client_headless.py --joueurs 4 --parties 1 --rapide

# Builds
cd app && flutter build apk --release
cd app && flutter build appbundle --release

# Signer localement, pour vérifier la chaîne
cd app && KEYSTORE_BASE64="$(base64 -w0 ../corsian-battle-upload.jks)" \
  KEYSTORE_PASSWORD=… KEY_ALIAS=… KEY_PASSWORD=… flutter build apk --release
```

### Documentation

| Document | Contenu |
|---|---|
| `docs/ARCHITECTURE.md` | Structure, §6.4 couche réseau, §6.5 écran en ligne |
| `docs/PROTOCOLE.md` | Protocole v1, fenêtre de doublon, sémantique `seq_attendu` |
| `docs/ENDPOINTS.md` | API REST, limites de débit |
| `docs/DEPLOIEMENT.md` | Déploiement, §7.1 chaîne de signature, §9 contraintes CI |
| `docs/FEUILLE_DE_ROUTE.md` | S0 → S5, critères d'acceptation réels |
| `docs/CONFORMITE.md` | RGPD, Play, Data Safety |
| `docs/SCHEMA_BD.md` | Schéma SQLite |
