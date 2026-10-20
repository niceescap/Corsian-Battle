# `serveur/` — corsian-auth et corsian-jeu

Backend du multijoueur. Spécification : [`../docs/`](../docs/README.md).
Règles du jeu : **jamais réimplémentées ici** — `bataille_corse/` reste la seule autorité.

```
serveur/
  requirements.txt        fastapi, uvicorn[standard], PyJWT, cryptography
  commun/config.py        lecture de l'environnement (noms de docs/DEPLOIEMENT.md §3)
  commun/bd.py            SQLite WAL + migrations + suppression RGPD (seul module
                          qui importe sqlite3 ; ailleurs : bd.Connexion, bd.ErreurIntegrite)
  commun/jwt.py           RS256 : émission (auth), vérification par JWKS (jeu)
  commun/pseudo.py        filtre UGC des pseudos
  commun/limites.py       limiteur de débit glissant
  migrations/001_initial.sql
  auth/main.py            corsian-auth  → 127.0.0.1:8111
  jeu/main.py             corsian-jeu   → 127.0.0.1:8112 (REST + WebSocket /ws)
  jeu/table.py            tables en mémoire, sièges, instantanés filtrés
  jeu/partie.py           PartieEnLigne : moteur + tour + délai de tour + fin
  jeu/evenements.py       un coup de moteur → événements diffusables (diff d'état)
  jeu/resolveur_reseau.py ResolveurTapeReseau (fenêtre de tape, plausibilité)
  tests/                  exécutables avec pytest **ou** sans aucune dépendance
  tests/client_headless.py  joue des parties complètes en WebSocket, sans l'app
  lancer_local.sh         démarre les deux services en premier plan
```

## 1. Installer

```bash
cd <racine du dépôt>
python3 -m venv .venv
.venv/bin/pip install -r serveur/requirements.txt
```

Sur noe, le venv de production est `~/corsian-battle/.venv` (jamais celui de 44i
ni d'open-webui). Ne rien compiler sur la machine : ces quatre paquets ont des
roues préconstruites pour linux/x86_64.

## 2. Lancer (recette immédiate, sans systemd)

```bash
./serveur/lancer_local.sh          # les deux services en premier plan, Ctrl-C arrête tout
```

Le script crée `./var/corsian.db` (schéma appliqué par la migration `001`) et,
**au tout premier lancement uniquement**, génère la clé RS256 de développement
dans `./var/cles/auth-rs256.pem` (`chmod 600`, un `WARNING` est journalisé à
cette occasion — c'est normal). Aucun `openssl` manuel n'est requis en dev ; en
production il l'est (`docs/DEPLOIEMENT.md` §3, et `ENVIRONNEMENT=prod` refuse de
démarrer sans clé). Le script démarre ensuite :

- `corsian-auth` sur `127.0.0.1:8111`
- `corsian-jeu` sur `127.0.0.1:8112`

En production, ce sont les units systemd de `docs/DEPLOIEMENT.md` §4 qui
s'appliquent, avec `ENVIRONNEMENT=prod`, une clé générée par `openssl` et
`chmod 600`, et `BASE_DSN`/`CLE_PRIVEE` explicites. En `prod`, un démarrage
avec `MODE_SANS_AUTH=1` ou sans `CLE_PRIVEE` est **refusé**
(`config.verifier_production`).

`--workers 1` est obligatoire pour `corsian-jeu` : les tables vivent dans le
processus. Deux workers produiraient deux univers de jeu parallèles.

## 3. Vérifier

```bash
curl -s 127.0.0.1:8111/api/auth/sante | python3 -m json.tool
curl -s 127.0.0.1:8112/api/jeu/sante  | python3 -m json.tool
curl -s 127.0.0.1:8112/api/jeu/config | python3 -m json.tool

# Compte invité, idempotent par uuid_appareil
REP=$(curl -s -X POST 127.0.0.1:8111/api/auth/invite \
      -H 'Content-Type: application/json' \
      -d '{"uuid_appareil":"termux-0001","pseudo":"Nina","plateforme":"test"}')
echo "$REP" | python3 -m json.tool
JETON=$(echo "$REP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["jeton_acces"])')

curl -s 127.0.0.1:8111/api/auth/profil -H "Authorization: Bearer $JETON" | python3 -m json.tool

# Table de duel, puis le socket
curl -s -X POST 127.0.0.1:8112/api/jeu/tables -H "Authorization: Bearer $JETON" \
     -H 'Content-Type: application/json' -d '{"type":"duel"}' | python3 -m json.tool

# Handshake WebSocket à travers nginx (101 attendu)
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://soft.opik.net/corsian-battle/ws
```

À travers nginx, les mêmes routes sont préfixées : `/corsian-battle/api/auth/…`,
`/corsian-battle/api/jeu/…`, `/corsian-battle/ws`.

### Tester le WebSocket à travers nginx

```bash
curl -i -N --http1.1 \
     -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     https://soft.opik.net/corsian-battle/ws
# Attendu : HTTP/1.1 101 Switching Protocols
```

⚠️ **`--http1.1` est obligatoire**, et `curl -I` ne teste rien (HEAD ≠ Upgrade).
Sans `--http1.1`, curl négocie HTTP/2 avec nginx ; HTTP/2 ne porte l'upgrade
WebSocket que via la RFC 8441, non activée sur nginx 1.24 → on obtient un **404
trompeur** alors que le proxy et le backend fonctionnent. En cas de doute,
refaire le même test en direct sur le backend (`http://127.0.0.1:8112/ws`) : s'il
répond `101`, le problème est entre nginx et curl, pas dans le service.

## 4. Tester

```bash
# Sans pytest, depuis n'importe quel dossier :
python3 serveur/tests/test_pseudo.py                  # filtre UGC
python3 serveur/tests/test_moteur_nonregression.py    # les règles, dont « personne n'a tapé »
python3 serveur/tests/test_resolveur_reseau.py        # fenêtre de tape, plausibilité
python3 serveur/tests/test_boucle_coups.py            # boucle de coups, diffusion, sièges

# Avec pytest (optionnel) :
.venv/bin/python -m pytest serveur/tests -q
```

`test_moteur_nonregression.py` verrouille les règles déjà validées sur
téléphone **et** le cas « personne n'a tapé ». À rejouer avant tout
déploiement : c'est le filet qui garantit que le serveur arbitre comme l'app
hors-ligne. Le moteur seul reste vérifiable par `python3 demo.py`.

### Recette de bout en bout, sans l'app

Deux services lancés, puis dans un autre terminal :

```bash
python3 serveur/tests/client_headless.py --joueurs 2 --verbeux
python3 serveur/tests/client_headless.py --joueurs 4 --parties 3
python3 serveur/tests/client_headless.py --auth https://soft.opik.net/corsian-battle \
                                        --jeu  https://soft.opik.net/corsian-battle
```

Le client crée les comptes invités, ouvre une table, fait asseoir tout le
monde, se déclare prêt, puis joue jusqu'à `partie_finie` en imprimant le
transcript (messages privés marqués `[privé]`). Il répond déjà `tape` à
`doublon_ouvert`, donc il recettera le lot B sans modification. Code de sortie
`0` si toutes les parties sont menées à leur terme.

## 5. Ce qui est implémenté — et ce qui ne l'est pas encore

**Fait**

| Bout | Détail |
|---|---|
| `GET /api/auth/sante` · `GET /api/jeu/sante` | état, base, disque, mémoire, tables actives |
| `GET /api/jeu/config` | réglages servis à l'app (fenêtre de tape, délai de tour, `ws`…) |
| `POST /api/auth/invite` | compte invité idempotent, filtre de pseudo, jetons |
| `POST /api/auth/rafraichir` | rotation + révocation en chaîne si jeton volé rejoué |
| `POST /api/auth/deconnexion` · `GET /api/auth/profil` · `DELETE /api/auth/compte` | session, profil + stats, suppression RGPD immédiate |
| `GET /api/auth/.well-known/jwks.json` | clé publique, lu en local par `corsian-jeu` |
| `POST/GET/DELETE /api/jeu/tables…` | création (idempotente par joueur), consultation, réservation de siège, fermeture |
| `WS /ws` | `bonjour` → `bienvenue` → `table_etat` filtré, `pret`, `ping`, `resynchroniser`, `quitter`, limites de débit, codes de fermeture de `docs/PROTOCOLE.md` §12 |
| `ResolveurTapeReseau` | fenêtre, plancher physiologique, rejets, suspicions, `None` si personne n'a tapé |
| Adaptation du moteur | `_resoudre_doublon()` peut renvoyer `None` — rétrocompatible |
| **Boucle de coups** | `PartieEnLigne` : lancement après `pret` + compte à rebours, `carte_posee`, `defi_ouvert`, `defi_rebondit`, `pli_gagne`, `ta_carte_suivante` privé, `partie_finie` |
| Délai de tour | 12 s puis coup automatique (`auto: true`) |
| Extraction des événements | `evenements.jouer_coup()` : diff d'état avant/après, **le moteur n'est pas modifié** |
| Fins de partie | `victoire`, `partie_nulle` (blocage ou garde-fou), `expiration` (30 min), `abandon` (table vide > 30 s) |
| Persistance | partie terminée + participations écrites en base, dans un thread, sans bloquer la boucle |
| Recette sans l'app | `tests/client_headless.py` joue des parties complètes en WebSocket |

| **Fenêtre de doublon (lot B)** | prédiction avant le coup → `doublon_ouvert` → collecte ≤ 900 ms → `carte_posee`(`annonce:true`) → `doublon_resolu` → `pli_gagne` ; clôture anticipée dès que tous les sièges connectés ont répondu |
| Anti-triche de la tape | plancher 120 ms, rejet < 100 ms, premier envoi seul retenu, **aucun retour au joueur** (pas d'oracle sur le plancher), suspicions consignées en base |
| Stats de tape par siège | doublons gagnés/perdus, tapes manquées, délai médian → `partie_finie` **et** table `participations` |
| Raison du pli exacte | `doublon` (celui qui a tapé) vs `defi_manque` (dernier poseur de figure), y compris quand les deux tombent sur le même coup |

**Pas encore (lot C → S4)**

- **bots de remplacement** après 30 s de déconnexion, et reconnexion sur
  instantané en cours de partie ;
- connexion email/mot de passe (argon2id) et rattachement d'email ;
- changement de pseudo et code de suppression à 9 caractères pour la voie web ;
- instantanés de reprise dans `tables_snapshot` ;
- matchmaking, historique, classement, signalements et blocages.

⚠️ **Ordre des messages sur un doublon** : `doublon_ouvert` arrive **avant**
`carte_posee`, et ce dernier porte `annonce: true` — le client anime la carte
depuis `doublon_ouvert.cartes[1]` et ne doit pas rejouer l'animation au
`carte_posee`. Détails et justification dans `docs/PROTOCOLE.md` §10.1, et
sémantique de `pli_gagne.raison` au §10.1bis.

## 6. Points de vigilance

- **`MODE_SANS_AUTH=1`** n'existe que pour tester le WebSocket avant que
  l'auth tourne. Il est refusé au démarrage si `ENVIRONNEMENT=prod`.
- Aucune connexion SQLite n'est partagée entre requêtes : les routes REST sont
  déclarées `def` (synchrone), donc exécutées dans le pool de threads de
  FastAPI, et chaque appel ouvre sa propre connexion. Jamais d'E/S réseau
  dans une transaction (`docs/SCHEMA_BD.md` §2.4).
- `proxy_buffering off` sur le `location` WS est **une condition d'équité**, pas
  de confort : avec le buffering, `carte_posee` et `doublon_ouvert` arrivent
  groupés et le chronomètre de tape du client démarre en retard
  (`docs/DEPLOIEMENT.md` §5.2).
- Les `Joueur.nom` doivent être uniques par table : le résolveur réseau classe
  par nom. L'unicité stricte des pseudos le garantit pour les humains, le
  nommage des bots pour les autres.
