# Corsian-Battle — Endpoints REST

> Deux services, deux ports, une convention : **le backend expose ses chemins réels**, nginx
> ajoute le préfixe public `/corsian-battle`. Un endpoint est donc testable en local sur
> `127.0.0.1` sans nginx.

---

## 1. Correspondance nginx ↔ backend

| URL publique | Backend | Service |
|---|---|---|
| `https://soft.opik.net/corsian-battle/api/auth/*` | `http://127.0.0.1:8111/api/auth/*` | `corsian-auth` |
| `https://soft.opik.net/corsian-battle/api/jeu/*` | `http://127.0.0.1:8112/api/jeu/*` | `corsian-jeu` |
| `wss://soft.opik.net/corsian-battle/ws` | `ws://127.0.0.1:8112/ws` | `corsian-jeu` *(déjà câblé)* |
| `https://soft.opik.net/corsian-battle/…` | `/home/nicee/agent/softopik/projects/corsian-battle/…` | statique |

Côté app, toutes les URL sont **relatives** (`/corsian-battle/api/…`) : aucun risque de
*mixed content*, aucun environnement à configurer.

## 2. Conventions

| Sujet | Règle |
|---|---|
| Authentification | `Authorization: Bearer <jeton d'accès>` (JWT RS256, 15 min) |
| Content-Type | `application/json; charset=utf-8` en entrée comme en sortie |
| Erreurs | `{"erreur": {"code": "pseudo_indisponible", "message": "Ce pseudo est déjà pris."}}` |
| Codes HTTP | `200` OK · `201` créé · `204` sans contenu · `400` requête invalide · `401` non authentifié · `403` interdit · `404` introuvable · `409` conflit · `422` champ refusé · `429` débit dépassé · `503` service saturé |
| `message` | Toujours affichable tel quel (aucun détail technique, aucune trace de pile) |
| Identifiants | UUID hex 32 caractères ; jamais de compteur séquentiel exposé |
| Pagination | `?curseur=<op>&limite=20` (max 50), réponse `{"elements":[…],"curseur_suivant":…}` |
| Version | En-tête `X-Api-Version: 1` sur toutes les réponses ; pas de version dans l'URL en V1 |
| CORS | Aucun en-tête `Access-Control-Allow-Origin` : l'app et le site sont sur la même origine |
| Cache | `Cache-Control: no-store` sur tout ce qui touche un compte |

**Endpoints publics** (sans jeton) : `/sante`, `/api/auth/invite`, `/api/auth/connexion`,
`/api/auth/rafraichir`, `/api/auth/.well-known/jwks.json`, `/api/auth/compte/code` (validation),
`/api/jeu/classement`, `/api/jeu/config`.

## 3. `corsian-auth` — `127.0.0.1:8111`

### 3.1 `GET /api/auth/sante`

```json
{ "etat": "ok", "service": "corsian-auth", "version": "0.1.0",
  "base": "ok", "cle_signature": "ok", "heure_utc": "2026-09-16T08:12:44Z" }
```

`etat` vaut `ok`, `degrade` (base en lecture seule, disque > 90 %) ou `erreur`. Utilisé par le
timer de supervision et par l'app pour distinguer « serveur en panne » de « réseau coupé ».

### 3.2 `POST /api/auth/invite` — point d'entrée principal

Corps :

```json
{ "uuid_appareil": "9f1c…", "pseudo": "Nina",
  "plateforme": "android", "version_app": "1.0.0" }
```

Réponse `200` :

```json
{ "joueur": { "id": "a1b2…", "pseudo": "Nina", "email": null, "cree_le": "2026-09-16T08:12:44Z" },
  "jeton_acces": "eyJ…",   "expire_dans": 900,
  "jeton_refresh": "rt_…", "refresh_expire_dans": 2592000,
  "nouveau_compte": true }
```

**Idempotent** : un `uuid_appareil` déjà connu ramène le compte existant
(`nouveau_compte: false`), ce qui rend la reconnexion transparente après redémarrage de l'app.

Erreurs : `422 pseudo_refuse` (filtre UGC), `409 pseudo_indisponible`, `429 trop_de_comptes`
(limite par IP et par appareil).

### 3.3 `POST /api/auth/connexion`

```json
{ "email": "nina@exemple.fr", "mot_de_passe": "…" }
```

Même réponse que `/invite`. `401 identifiants_invalides` — message volontairement ambigu
(aucune indication sur l'existence du compte). Limite : 5 tentatives / 15 min / IP.

### 3.4 `POST /api/auth/rafraichir`

```json
{ "jeton_refresh": "rt_…" }
```

Réponse : nouvelle paire, **ancien jeton révoqué** (rotation). Un jeton déjà révoqué et
réutilisé entraîne la révocation de **toute** la chaîne de sessions de l'appareil (détection de
vol). `401 refresh_invalide`.

### 3.5 `POST /api/auth/deconnexion`

```json
{ "jeton_refresh": "rt_…" }
```
→ `204`. Révoque la session courante sans toucher au compte.

### 3.6 `GET /api/auth/profil` *(jeton requis)*

```json
{ "joueur": { "id": "a1b2…", "pseudo": "Nina", "email": null,
              "cree_le": "…", "dernier_vu_le": "…", "langue": "fr" },
  "appareils": [ { "plateforme": "android", "derniere_connexion": "…", "actuel": true } ],
  "stats": { "parties": 12, "victoires": 7, "doublons_gagnes": 34, "delai_moyen_ms": 268 } }
```

### 3.7 `PATCH /api/auth/profil` *(jeton requis)*

```json
{ "pseudo": "Nina2" }
```
→ `200` avec le profil à jour. Mêmes filtres qu'à la création ; `409 pseudo_indisponible`.
Limite : 3 changements / 24 h (évite l'usurpation de pseudo après un signalement).

### 3.8 `POST /api/auth/email` *(jeton requis)* — rattachement

```json
{ "email": "nina@exemple.fr", "mot_de_passe": "minimum 10 caractères" }
```
→ `200`. Transforme un compte invité en compte récupérable sur un autre téléphone. Aucune
vérification par courriel en V1 (pas de dépendance SMTP) : l'adresse est simplement normalisée
et unique. Si l'adresse appartient déjà à un compte → `409 email_deja_utilise` ; une **fusion**
de comptes (invité → existant) est explicitement **hors périmètre V1** et sera documentée avant
d'être implémentée.

### 3.9 Suppression de compte

Deux voies, comme l'exige Google Play (dans l'app **et** sur le web) :

**a) `DELETE /api/auth/compte`** *(jeton requis)* → `204`, effet décrit dans
`SCHEMA_BD.md` §6. Immédiat, irréversible.

**b) Voie web sans identifiants** (un compte invité n'a ni email ni mot de passe) :

```
POST /api/auth/compte/code        (jeton requis, depuis l'app)
  → { "code": "T7K2-9QMC", "expire_dans": 900 }

DELETE /api/auth/compte/code      (public, depuis suppression-compte.html)
  corps : { "code": "T7K2-9QMC" }
  → 204
```

Le code à 9 caractères, valable 15 min, à usage unique, évite d'exiger un email pour supprimer
un compte qui n'en a pas. Limite : 3 codes / h / compte, 10 tentatives / h / IP.

### 3.10 `GET /api/auth/.well-known/jwks.json`

```json
{ "keys": [ { "kty": "RSA", "kid": "2026-09", "use": "sig", "alg": "RS256", "n": "…", "e": "AQAB" } ] }
```

Lu par `corsian-jeu` en local (`http://127.0.0.1:8111/api/auth/.well-known/jwks.json`), mis en
cache 10 min, **jamais** exposé par nginx au public — la clé publique n'est pas secrète, mais
la réduire au réseau local supprime un point de découverte. Rotation de clé : nouveau `kid`,
l'ancien reste publié 30 jours.

## 4. `corsian-jeu` — `127.0.0.1:8112`

### 4.1 `GET /api/jeu/sante`

```json
{ "etat": "ok", "service": "corsian-jeu", "version": "0.1.0",
  "tables_actives": 3, "sockets_ouverts": 9, "base": "ok",
  "memoire_mo": 78, "uptime_s": 84213 }
```

`etat: "degrade"` si `tables_actives` dépasse 180 (seuil de saturation à 200, cf.
`PROTOCOLE.md` §13) — la création de table renvoie alors `503`.

### 4.2 `GET /api/jeu/config` *(public)*

```json
{ "version_proto": 1,
  "fenetre_tape_ms": 900,
  "delai_tour_ms": 12000,
  "grace_deconnexion_s": 30,
  "compte_a_rebours_s": 3,
  "tailles_table": [2, 4],
  "maintenance": false,
  "message_maintenance": null }
```

L'app **ne code en dur aucun de ces réglages** : ils sont lus au démarrage et mis en cache.
C'est ce qui permet d'ajuster la fenêtre de tape ou de couper le multijoueur sans republier
l'app — indispensable pendant les premières semaines d'exploitation.

### 4.3 `POST /api/jeu/tables` *(jeton requis)*

```json
{ "type": "duel" }
```
→ `201`
```json
{ "code": "K7M2QP", "type": "duel", "siege": 0, "etat": "attente",
  "url_partage": "https://soft.opik.net/corsian-battle/#table=K7M2QP",
  "ws": "/corsian-battle/ws",
  "expire_le": "2026-09-16T10:12:44Z" }
```

Le créateur obtient automatiquement le siège 0. Limite : 1 table active par joueur.

### 4.4 `GET /api/jeu/tables/{code}` *(jeton requis)*

```json
{ "code": "K7M2QP", "type": "duel", "etat": "attente",
  "sieges": [ {"siege":0,"pseudo":"Nina","pret":true,"est_bot":false},
              {"siege":1,"pseudo":null,"pret":false,"est_bot":false} ],
  "blocages_mutuels": false }
```

`404 table_introuvable`. `blocages_mutuels: true` empêche de rejoindre (cf. §4.9).

### 4.5 `POST /api/jeu/tables/{code}/rejoindre` *(jeton requis)*

→ `200` `{ "siege": 1, "ws": "/corsian-battle/ws" }`.
Erreurs : `409 table_pleine`, `409 partie_deja_lancee`, `403 joueur_bloque`.

Le REST ne fait que **réserver le siège** ; le jeu démarre sur le WebSocket. Un siège réservé
non connecté sous 20 s est libéré.

### 4.6 `DELETE /api/jeu/tables/{code}` *(créateur, jeton requis)*

→ `204` si la table est encore en `attente` ; `409 partie_en_cours` sinon (on ne peut pas
dissoudre une partie lancée : les autres joueurs sont protégés).

### 4.7 Matchmaking — `POST /api/jeu/file` *(jeton requis)*

```json
{ "type": "duel" }
```
→ `202`
```json
{ "position": 2, "attente_estimee_s": 25, "jeton_file": "q_…" }
```

Une correspondance trouvée produit, côté WebSocket, un `table_etat` sur la table créée
automatiquement — aucun aller-retour REST supplémentaire. Les joueurs bloqués mutuellement ne
sont jamais appariés. `DELETE /api/jeu/file` → `204` (quitte la file).

### 4.8 Statistiques et historique *(jeton requis)*

| Endpoint | Réponse |
|---|---|
| `GET /api/jeu/stats/moi` | `{ "parties": 12, "victoires": 7, "doublons_gagnes": 34, "tapes_manquees": 5, "delai_moyen_ms": 268, "serie_en_cours": 2 }` |
| `GET /api/jeu/historique?limite=20&curseur=…` | `{ "elements": [ {"partie_id":"…","type":"duel","terminee_le":"…","place":1,"adversaires":["Marc"],"nb_coups":84,"raison_fin":"victoire"} ] }` |
| `GET /api/jeu/classement?periode=30j&limite=10` *(public)* | `{ "elements": [ {"pseudo":"Nina","parties":41,"victoires":27,"delai_moyen_ms":241} ] }` — **bots exclus**, pseudos des comptes supprimés affichés « Joueur » |

### 4.9 Modération UGC *(jeton requis)*

| Endpoint | Corps | Effet |
|---|---|---|
| `POST /api/jeu/signalements` | `{"code_table":"K7M2QP","siege":1,"motif":"pseudo","detail":"…"}` | Enregistre ; `detail` ≤ 200 caractères, refusé au-delà (`422`) |
| `GET /api/jeu/blocages` | — | Liste des joueurs bloqués |
| `POST /api/jeu/blocages` | `{"joueur_id":"…"}` | Empêche appariement et rejointe de table |
| `DELETE /api/jeu/blocages/{joueur_id}` | — | `204` |

Limites : 10 signalements / jour / joueur, 1 signalement par cible et par partie.
Ces trois verrous (signalement, blocage, filtre de pseudo) sont la contrepartie exigée par
Google Play dès qu'un pseudo de joueur est affiché à d'autres — voir `CONFORMITE.md` §5.

### 4.10 `GET /api/jeu/maintenance` *(interne, 127.0.0.1)*

Bascule manuelle du drapeau `maintenance` servi par `/config`, pour couper le multijoueur
(incident, saturation mémoire) sans arrêter le service ni déployer.

## 5. Limites de débit (par IP et par compte)

| Famille | Limite | Réponse au-delà |
|---|---|---|
| Création de compte (`/invite`) | 5 / h / IP, 1 / appareil | `429` |
| Connexion (`/connexion`) | 5 / 15 min / IP | `429` |
| Rafraîchissement | 60 / h / compte | `429` |
| Création de table | 10 / h / compte | `429` |
| File d'attente | 30 entrées / h / compte | `429` |
| Signalements | 10 / jour / compte | `429` |
| Lecture (stats, classement) | 120 / min / IP | `429` |
| WebSocket | 10 msg/s, rafale 20 | fermeture `4429` |

Toute réponse `429` porte `Retry-After` en secondes. L'app respecte ce délai sans relancer.

## 6. Recette de vérification (une fois les services démarrés)

```bash
# Santé — en local sur la machine
curl -s 127.0.0.1:8111/api/auth/sante | python3 -m json.tool
curl -s 127.0.0.1:8112/api/jeu/sante  | python3 -m json.tool

# Santé — à travers nginx (après ajout des deux blocs location)
curl -i https://soft.opik.net/corsian-battle/api/auth/sante
curl -i https://soft.opik.net/corsian-battle/api/jeu/sante

# Configuration publique
curl -s https://soft.opik.net/corsian-battle/api/jeu/config | python3 -m json.tool

# Compte invité, de bout en bout
JETON=$(curl -s -X POST https://soft.opik.net/corsian-battle/api/auth/invite \
        -H 'Content-Type: application/json' \
        -d '{"uuid_appareil":"test-termux-0001","pseudo":"Testeur",
             "plateforme":"test","version_app":"0.0.0"}' \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["jeton_acces"])')

curl -s https://soft.opik.net/corsian-battle/api/auth/profil \
     -H "Authorization: Bearer $JETON" | python3 -m json.tool

# Création d'une table
curl -s -X POST https://soft.opik.net/corsian-battle/api/jeu/tables \
     -H "Authorization: Bearer $JETON" -H 'Content-Type: application/json' \
     -d '{"type":"duel"}' | python3 -m json.tool

# Handshake WebSocket (curl -I ne suffit PAS : HEAD ≠ Upgrade)
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://soft.opik.net/corsian-battle/ws
# Attendu : HTTP/1.1 101 Switching Protocols
```

## 7. Ce qui est volontairement absent du REST

- **Jouer un coup** : uniquement par WebSocket. Un `POST /poser_carte` serait rejouable,
  ordonnançable hors contexte et impossible à synchroniser avec la fenêtre de tape.
- **Récupérer les cartes des autres** : n'existe sous aucune forme (`PROTOCOLE.md` §8).
- **Choisir son siège** : attribué par le serveur dans l'ordre d'arrivée.
- **Modifier une partie terminée** : aucune route d'écriture sur `parties` n'est exposée.
