# `serveur/` — corsian-auth et corsian-jeu

Backend du multijoueur. Spécification : [`../docs/`](../docs/README.md).
Règles du jeu : **jamais réimplémentées ici** — `bataille_corse/` reste la seule autorité.

```
serveur/
  requirements.txt        fastapi, uvicorn[standard], PyJWT, cryptography
  commun/config.py        lecture de l'environnement (noms de docs/DEPLOIEMENT.md §3)
  commun/bd.py            SQLite WAL + migrations + suppression RGPD
  commun/jwt.py           RS256 : émission (auth), vérification par JWKS (jeu)
  commun/pseudo.py        filtre UGC des pseudos
  commun/limites.py       limiteur de débit glissant
  migrations/001_initial.sql
  auth/main.py            corsian-auth  → 127.0.0.1:8111
  jeu/main.py             corsian-jeu   → 127.0.0.1:8112 (REST + WebSocket /ws)
  jeu/table.py            tables en mémoire, sièges, instantanés filtrés
  jeu/resolveur_reseau.py ResolveurTapeReseau (fenêtre de tape, plausibilité)
  tests/                  exécutables avec pytest **ou** sans aucune dépendance
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

## 4. Tester

```bash
# Sans pytest, depuis n'importe quel dossier :
python3 serveur/tests/test_pseudo.py
python3 serveur/tests/test_moteur_nonregression.py
python3 serveur/tests/test_resolveur_reseau.py

# Avec pytest (optionnel) :
.venv/bin/python -m pytest serveur/tests -q
```

`test_moteur_nonregression.py` verrouille les règles déjà validées sur
téléphone **et** le nouveau cas « personne n'a tapé ». À rejouer avant tout
déploiement : c'est le seul filet qui garantit que le serveur arbitre comme
l'app hors-ligne.

Le moteur seul (hors serveur) reste vérifiable par `python3 demo.py`.

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

**Pas encore (étapes S1 complet → S3)**

- connexion email/mot de passe (argon2id) et rattachement d'email ;
- changement de pseudo et code de suppression à 9 caractères pour la voie web ;
- **boucle de coups** : branchement du moteur sur la table, `carte_posee`,
  `defi_ouvert`, `pli_gagne`, délai de tour et coup automatique ;
- fenêtre de doublon en conditions réelles (`doublon_ouvert` → collecte des
  `tape` → `doublon_resolu`) et consignation des suspicions en base ;
- déconnexion > 30 s → bot, reconnexion sur instantané ;
- matchmaking, historique, classement, signalements et blocages ;
- instantanés de reprise dans `tables_snapshot`.

Jusqu'à la boucle de coups, `poser_carte` et `tape` sont reconnus mais
répondent `pas_encore_en_partie` : le contrat des messages est déjà celui de la
spec, donc le client n'aura pas à changer.

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
