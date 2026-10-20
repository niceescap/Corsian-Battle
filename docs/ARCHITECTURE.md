# Corsian-Battle — Architecture du multijoueur en ligne

> **Statut** : spécification. Aucun code applicatif n'est écrit tant que les deux points
> marqués ⏳ ne sont pas tranchés (contenu de la racine statique, bloc `location` API).
>
> **Décisions validées par Nicolas** : SQLite en mode WAL · compte invité (appareil + pseudo)
> avec rattachement d'email optionnel · orchestrateur FastAPI/Python **réutilisant le moteur
> `bataille_corse`** comme autorité du jeu.

---

## 1. Objectifs

1. Jouer une vraie partie de bataille corse **entre humains**, en duel (2) ou à la table de 4,
   depuis l'app Android (puis iOS via TestFlight).
2. Que le résultat soit **digne de confiance** : ni l'ordre du paquet, ni le verdict d'un
   doublon ne doivent pouvoir être fabriqués par un client modifié.
3. Que la partie **survive aux aléas mobiles** : coupure réseau, mise en arrière-plan,
   changement d'opérateur, joueur qui part.
4. Que le tout tienne sur **la machine existante** (noe, 2 vCPU / 3,9 Go RAM déjà sous pression
   de swap) sans ajouter de service lourd.
5. Que le mode **hors-ligne reste intact** : le duel contre la machine et la table de 4 locale
   doivent continuer à fonctionner sans aucun serveur.

## 2. Non-objectifs (assumés pour la V1)

| Écarté | Pourquoi | Reprise possible |
|---|---|---|
| Chat texte entre joueurs | Oblige une modération UGC lourde (Play) pour un gain faible | plus tard, avec le signalement déjà prévu |
| Spectateurs | Complexité de diffusion sans revenue | plus tard |
| Mode classé / saison | Exige un anti-triche durci | S4+ |
| Multi-worker, Redis, Postgres | Un seul processus suffit à la charge visée | voir §10 |
| Fédération / multi-région | Un seul serveur, un seul domaine | non prévu |

## 3. Principes directeurs

1. **Le serveur est la seule autorité.** Le client ne décide rien : il envoie des intentions
   (« je pose ma carte du dessus », « je tape ») et affiche ce que le serveur lui raconte.
2. **Une seule implémentation des règles.** `bataille_corse/moteur.py` tourne côté serveur.
   Le port Dart `app/lib/moteur/partie_locale.dart` reste réservé au jeu hors-ligne ; il n'est
   **jamais** utilisé pour arbitrer une partie en ligne. Toute évolution des règles se fait
   d'abord dans le moteur Python, puis est reportée dans le port Dart.
3. **Ce qui n'est pas public n'est pas envoyé.** Un client ne reçoit jamais l'ordre du paquet
   ni les cartes des adversaires (§8.3). C'est la principale défense anti-triche.
4. **L'état vivant reste en mémoire, la base ne garde que le durable.** Aucune écriture en base
   par carte posée. La base sert aux comptes, aux statistiques, aux parties terminées et aux
   instantanés de reprise.
5. **Aucune comparaison d'horloges murales** entre appareils. Tous les classements de réflexes
   se font sur des **durées mesurées localement** par chaque client, bornées et vérifiées par
   le serveur.
6. **Sobriété d'abord** : 2 processus uvicorn à 1 worker, SQLite, aucune dépendance native,
   aucune tâche de build sur la machine.

## 4. Topologie

```
                        ┌──────────────────────────────────────────────┐
  App Android / iOS     │  noe  (Scaleway, 2 vCPU, 3,9 Go RAM)         │
        │               │                                              │
        │  HTTPS 443    │  nginx  ·  vhost soft.opik.net               │
        │  WSS 443      │    ├─ /corsian-battle/          ──► disque   │
        └───────────────┼───►├─ /corsian-battle/api/auth/ ──► :8111    │
                        │    ├─ /corsian-battle/api/jeu/  ──► :8112    │
                        │    └─ /corsian-battle/ws        ──► :8112    │
                        │                                              │
                        │  corsian-auth (127.0.0.1:8111)  FastAPI      │
                        │        │  signe/vérifie JWT, gère comptes    │
                        │        ▼                                     │
                        │  SQLite WAL ── ~/corsian-battle/var/corsian.db│
                        │        ▲                                     │
                        │        │  (comptes, stats, parties, snapshot)│
                        │  corsian-jeu (127.0.0.1:8112)   FastAPI      │
                        │        · REST + WebSocket                    │
                        │        · tables en mémoire (asyncio)         │
                        │        · importe bataille_corse (autorité)   │
                        └──────────────────────────────────────────────┘
```

### 4.1 Ports et liaisons

| Élément | Bind | Rôle |
|---|---|---|
| `corsian-auth` | `127.0.0.1:8111` | REST uniquement : comptes, JWT, suppression |
| `corsian-jeu` | `127.0.0.1:8112` | REST (tables, stats) **+ WebSocket** (jeu) |
| SQLite | pas de port | fichier unique, un seul processus écrit |

`8111` et `8112` sont confirmés **libres** (`ss -ltnp` et `ss -lunp`). Ports voisins déjà pris
sur la machine : 8001 (CyQuiz), 3252 (44i), 8080 (open-webui), 11434 (ollama), 5432 (postgres),
5000/8000/8011/2025/8070/8088/8090/8095/8081/18000/17000/8766/8871/8872/65162.

**Règle absolue : bind sur `127.0.0.1`, jamais `0.0.0.0`.** nginx (443) est le seul point
d'entrée public. Uvicorn est lancé avec `--proxy-headers --forwarded-allow-ips 127.0.0.1` afin
que les limites de débit s'appuient sur l'IP réelle du client et non sur 127.0.0.1.

### 4.2 Ce qui existe déjà dans nginx (à ne pas modifier)

```nginx
location = /corsian-battle        { return 301 /corsian-battle/; }
location /corsian-battle/         { alias /home/nicee/agent/softopik/projects/corsian-battle/;
                                    index index.html; }
location ^~ /corsian-battle/ws    { proxy_pass http://127.0.0.1:8112/ws; }   # WS déjà câblé
```

Le `proxy_pass` se terminant par `/ws`, nginx **strippe le préfixe** : le backend doit donc
déclarer l'handshake sur **`/ws`** (choix retenu, `@app.websocket("/ws")`). Aucune modification
nginx n'est nécessaire pour le WebSocket.

### 4.3 ⏳ À ajouter dans nginx (proposition, en attente de validation)

```nginx
# API d'authentification — public /corsian-battle/api/auth/* → backend /api/auth/*
location /corsian-battle/api/auth/ {
    proxy_pass http://127.0.0.1:8111/api/auth/;
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 30s;
}

# API de jeu — public /corsian-battle/api/jeu/* → backend /api/jeu/*
location /corsian-battle/api/jeu/ {
    proxy_pass http://127.0.0.1:8112/api/jeu/;
    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 30s;
}
```

Le WS existant devra recevoir les mêmes en-têtes d'upgrade s'ils ne sont pas déjà présents
(`proxy_http_version 1.1`, `Upgrade`, `Connection "upgrade"`, `proxy_read_timeout 3600s`) :
sans timeout long, nginx coupe les sockets inactifs à 60 s.

**Avantage de cette convention** : le backend expose ses chemins réels (`/api/auth/…`), donc il
est testable en local sans nginx — `curl 127.0.0.1:8111/api/auth/sante` — et l'URL publique
n'est qu'un préfixe. Le préfixe public est fourni aux services par variable d'environnement
(`PREFIXE_PUBLIC=/corsian-battle`) pour les rares URL absolues à produire (liens d'invitation,
JWKS, suppression de compte).

### 4.4 ⏳ Racine statique — contenu à vérifier avant d'écrire

`/home/nicee/agent/softopik/projects/corsian-battle/` : un `ls -la` est requis. Politique
appliquée par précaution :

- **aucun écrasement** d'un fichier existant (une autre session a pu déposer la page `#download`) ;
- si `index.html` existe → proposition de diff, ou version posée dans un sous-dossier avec un
  `location` dédié ;
- les fichiers nouveaux portent des noms réservés par cette spec : `privacy.html`, `terms.html`,
  `suppression-compte.html`, et les binaires sous `apk/` et `aab/`.

## 5. Les deux services

### 5.1 `corsian-auth` (8111)

**Fait** : création de compte invité (identifiant d'appareil + pseudo), rattachement
email/mot de passe, connexion, rafraîchissement et révocation de session, lecture et
suppression du profil, publication de la clé publique de signature (JWKS), limites de débit.

**Ne fait pas** : ne connaît rien aux tables de jeu, ne détient aucun état de partie,
n'ouvre aucun WebSocket.

**Ne stocke jamais** : de mot de passe en clair (hachage argon2id), de jeton de rafraîchissement
en clair (empreinte SHA-256 uniquement).

### 5.2 `corsian-jeu` (8112)

**Fait** : création/rejointe de tables, codes d'invitation, file d'attente (matchmaking),
boucle de jeu autoritaire, arbitrage des doublons, remplacement des joueurs partis par des bots,
statistiques et classement, signalements, instantanés de reprise.

**Ne fait pas** : ne gère aucun mot de passe, n'écrit aucun compte. Il **vérifie la signature**
du JWT présenté par le client à l'aide du JWKS publié par `corsian-auth` (clé lue localement,
mise en cache 10 min). Les deux services partagent la même base SQLite, mais chacun n'écrit que
dans ses tables (voir `SCHEMA_BD.md` §2.4 pour la règle d'écriture croisée).

### 5.3 Pourquoi deux processus plutôt qu'un

- Isolation des pannes : un plantage de la boucle de jeu ne déconnecte pas l'authentification.
- Déploiement indépendant : on peut republier l'auth (correctif de sécurité) sans interrompre
  les tables en cours.
- Le jour où la charge augmente, seul `corsian-jeu` est à faire évoluer.

Coût : ~60 à 90 Mo de RAM par processus Python. Sur 2,3 Go disponibles, c'est acceptable.

## 6. Réutilisation du moteur Python

### 6.1 Ce qui est déjà utilisable tel quel

| Élément | Usage serveur |
|---|---|
| `cartes.py` (paquet 52, codes poker, `construire_paquet(rng)`) | Distribution, sérialisation |
| `joueur.py` (tas face cachée, carte du dessus imposée) | État par siège |
| `moteur.py` `BatailleCorse.jouer_un_coup()` | **Granularité exacte d'un coup réseau** |
| `moteur.py` `_est_doublon()`, `DefiEnCours`, `_attribuer_pli()` | Événements à diffuser |
| `resolveur_tape.py` `ResolveurTape` (interface) | Point de branchement réseau déjà prévu |
| `resolveur_tape.py` `ProfilReflexe`, `ResolveurSimulationBots` | Bots de remplacement |

La docstring de `resolveur_tape.py` décrit déjà le résolveur réseau à écrire : chaque appli
timecode son propre écart reveal → appui, le résolveur choisit le délai le plus court reçu.
`PROTOCOLE.md` §10 en fait la spécification précise.

### 6.2 Les trois ajouts nécessaires au moteur (sans le réécrire)

1. **`ResolveurTapeReseau`** — implémentation de `ResolveurTape` qui, au lieu de tirer des
   temps simulés, **attend** les délais mesurés envoyés par les clients, dans une fenêtre bornée,
   puis applique `min()` sur les délais plausibles. Comme `determiner_gagnant()` est synchrone
   dans l'interface actuelle, le serveur l'appelle depuis une tâche asyncio qui a déjà collecté
   les délais (collecte asynchrone en amont, résolution synchrone) — aucune modification
   d'interface requise.
2. **Observation des événements** — `jouer_un_coup()` applique les règles mais ne *raconte* pas
   ce qu'il vient de faire (il n'alimente que `self.historique`, des chaînes destinées aux
   humains). Le serveur doit produire des événements **structurés** à diffuser. Deux options,
   à trancher à l'implémentation :
   - *(préférée)* comparaison d'état avant/après le coup (`pli`, `defi_en_cours`, `index_courant`,
     tas de chaque joueur) pour déduire l'événement — zéro modification du moteur ;
   - ajout d'un crochet optionnel `observateur` dans `moteur.py` — plus lisible, mais touche
     au fichier source de vérité.
3. **« Personne n'a tapé »** — en ligne, un doublon peut passer sans qu'aucun joueur ne tape :
   le pli ne doit alors être attribué à personne et le jeu continue. L'interface
   `ResolveurTape.determiner_gagnant()` doit donc être autorisée à renvoyer `None`, et
   `_resoudre_doublon()` à rendre la main sans attribuer le pli. `ResolveurSimulationBots` ne
   renvoie jamais `None` : `demo.py` et toutes les simulations existantes gardent un
   comportement strictement identique. Détail du traitement : `PROTOCOLE.md` §10.3.
4. **Sérialisation / instantané** — projection de l'état d'une `BatailleCorse` en dictionnaire
   JSON, **filtrée par destinataire** (§8.3), plus un instantané reconstructible pour la reprise
   après redémarrage (`seed` + liste ordonnée des coups rejoués, plutôt que l'état brut : plus
   petit, et garanti cohérent avec les règles).

Les points 1 et 4 vivent dans `serveur/` ; les points 2 et 3 touchent `bataille_corse/` et
doivent rester **rétrocompatibles** (paramètres optionnels, comportement par défaut inchangé).

### 6.3 Le moteur n'est pas modifié pour le réseau

Règle de conception : `bataille_corse/` reste une bibliothèque **pure, synchrone, sans E/S**.
Tout ce qui est réseau, délais, sockets et temporisateurs vit dans `serveur/`. C'est ce qui
permet de continuer à valider les règles avec `demo.py` et des simulations de milliers de
parties sans aucun serveur.

## 7. Données

- **En mémoire** (processus `corsian-jeu`) : les tables actives — sièges, connexions, état du
  moteur, fenêtres de tape en cours, temporisateurs.
- **En base** (SQLite WAL) : comptes, appareils, sessions de rafraîchissement, parties
  terminées, statistiques, instantanés de tables, signalements et blocages.

Schéma complet, index, rétention et sauvegardes : **`SCHEMA_BD.md`**.

## 8. Sécurité et loyauté

### 8.1 Authentification

JWT **RS256** (paire de clés générée une fois, stockée hors dépôt, `chmod 600`) :
`corsian-auth` signe, `corsian-jeu` vérifie avec la clé publique du JWKS. Aucun secret partagé
n'est nécessaire, et une fuite du processus de jeu ne permet pas de forger de jetons.
Access 15 min, refresh 30 j avec rotation et révocation.

### 8.2 Transport

Uniquement via nginx en 443 (TLS terminé par nginx). Jamais de port applicatif exposé.
HSTS déjà porté par le vhost existant. Les URL côté app sont **relatives**
(`/corsian-battle/api/…`) pour éviter tout blocage *mixed content*, leçon déjà payée sur CyQuiz.

### 8.3 Anti-triche par l'information

Le serveur n'envoie à un client **que** :

- le pli en cours (cartes publiques, dans l'ordre de pose) ;
- le nombre de cartes de chaque tas adverse (jamais leur identité) ;
- le reste neutre : uniquement son **nombre** ;
- **sa propre** carte du dessus (pré-annonce d'une carte, nécessaire à l'animation de swipe) ;
- les événements publics (défi ouvert, chances restantes, doublon, pli gagné, fin).

Conséquence : un client modifié ne peut pas connaître la carte suivante d'un adversaire, donc
ne peut pas choisir *quand* taper ni prévoir un doublon. Le seul avantage falsifiable restant est
le **délai de tape**, borné au §8.4.

### 8.4 Le doublon : fenêtre, plausibilité, sanction

- Fenêtre de collecte : ~900 ms à partir de l'émission de `doublon_ouvert`.
- Plancher physiologique : **120 ms**. Tout délai < 100 ms est **rejeté** et consigné
  (compteur de suspicion par joueur).
- Plafond : au-delà de la fenêtre, le joueur est réputé n'avoir pas tapé.
- Égalité parfaite : départagée par l'ordre d'arrivée serveur, puis par le siège.
- Correction de latence : le délai est mesuré **côté client** entre le début de l'animation de
  révélation et l'appui ; le serveur n'y ajoute rien. La latence réseau ne fausse donc pas la
  comparaison (elle retarde seulement la réception, ce qui est visible dans l'ordre d'arrivée
  utilisé uniquement pour les égalités).
- Trois suspicions enregistrées en 24 h → drapeau sur le compte ; au-delà d'un seuil à fixer en
  exploitation, exclusion du matchmaking classé (S4+). Aucun bannissement automatique en V1 :
  le volume ne le justifie pas et le faux positif est plus coûteux que la triche.

### 8.5 Autres protections

| Risque | Mesure |
|---|---|
| Inondation de messages | Limite par socket (≈10 msg/s, rafale 20), fermeture `4429` au-delà |
| Création massive de comptes invités | Limite par IP et par appareil + jeton signé obligatoire |
| Pseudo offensant (UGC → obligation Play) | Filtre à la création, longueur ≤ 20, jeu de caractères restreint, signalement |
| Rejeu d'un coup | Numéro de séquence par table ; tout coup hors séquence est ignoré |
| Usurpation de siège | Le JWT lie `joueur_id` ; le siège est attribué à la connexion, jamais choisi par le client |
| Fuite de la clé | Clés hors dépôt, `chmod 600`, rotation documentée dans `DEPLOIEMENT.md` |
| Déni de service sur la table | Un joueur qui ne répond plus est remplacé par un bot après 30 s, la partie continue |

## 9. Défaillances et reprise

| Cas | Comportement |
|---|---|
| Perte réseau d'un joueur (< 30 s) | Le siège est marqué `absent` ; le socket peut se reconnecter et recevoir `table_etat` |
| Perte réseau > 30 s | Un bot prend la main (`ProfilReflexe` + logique de tempo existante) ; le joueur peut revenir et récupérer son siège tant que la partie n'est pas finie |
| Un joueur quitte définitivement | Bot jusqu'à la fin de la partie ; la partie est enregistrée comme « terminée avec remplacement » |
| Redémarrage de `corsian-jeu` | Les tables actives sont rechargées depuis `tables_snapshot` (seed + coups rejoués) ; les sockets sont perdus, les clients se reconnectent et reçoivent l'état |
| Plantage de `corsian-auth` | Le jeu continue : les JWT déjà émis restent vérifiables (clé publique en cache) ; seule la création de compte est interrompue |
| Disque plein | Les services passent en lecture seule et refusent les nouvelles tables ; alerte par le `/sante` |
| Base corrompue | Restauration depuis la sauvegarde quotidienne (`VACUUM INTO`) ; les parties en cours sont perdues, les comptes reviennent à J-1 |

Aucune de ces situations ne doit produire d'écran d'erreur brut côté app : la règle UX déjà
appliquée (aucun mot en jeu, pictogrammes universels) vaut aussi pour le réseau.

## 10. Évolutions prévues (et ce qu'on refuse aujourd'hui)

- **Charge** : tant qu'un seul processus suffit, on reste à 1 worker. Le jour où il faut
  horizontaliser, la première étape est le routage collant par code de table (une table = un
  processus), pas un état partagé. Redis n'arrive qu'ensuite.
- **Base** : la couche d'accès est volontairement fine (SQLAlchemy Core) pour permettre un
  passage à PostgreSQL (5432 est déjà occupé sur la machine → 5433) sans réécrire le métier.
  Un Postgres existe déjà sur noe ; on ne l'utilise **pas** en V1 pour ne pas ajouter de
  dépendance d'exploitation à un projet de jeu.
- **Classement** : les tables `stats_joueur` sont conçues pour accueillir un score de type Elo
  plus tard ; la V1 ne compte que parties, victoires et doublons réussis.
- **iOS** : aucune compilation possible depuis noe (pas de macOS). La distribution passera par
  TestFlight, ce qui suppose un compte Apple Developer et un accès à un Mac. Le site affiche un
  encart « iOS : TestFlight — bientôt » plutôt qu'un bouton mort. Voir `CONFORMITE.md` §6.

## 11. ⏳ Points bloquants à trancher

1. Contenu réel de `/home/nicee/agent/softopik/projects/corsian-battle/` (`ls -la`).
2. Ajout des deux blocs `location` API (§4.3) et des en-têtes d'upgrade + timeout long sur le
   `location` WS existant.
3. Validation du budget mémoire : 2 × ~80 Mo alors que le swap est déjà à 1,9 Go sur 3,6 Go.
   Si nécessaire, arbitrer ce qui peut être arrêté pendant les phases de test (ollama ?).
