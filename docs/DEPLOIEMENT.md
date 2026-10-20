# Corsian-Battle — Déploiement sur noe

> Machine : **noe** (Scaleway, 2 vCPU, 3,9 Go RAM, 63 Go disque à 86 %). User `nicee`,
> **sans accès `docker.sock`** → systemd + venv, aucun conteneur. Accès SSH depuis Termux.
>
> ⚠️ **Gel d'infrastructure** : rien n'est installé tant que les points ⏳ du §10 ne sont pas
> tranchés. Ce document décrit la cible, pas un état existant.

---

## 1. Arborescence cible

### 1.1 Dépôt GitHub (`niceescap/Corsian-Battle`)

```
bataille_corse/        moteur Python — source de vérité des règles (inchangé)
app/                   projet Flutter (Android ; iOS plus tard)
serveur/
  requirements.txt     fastapi, uvicorn[standard], pyjwt, cryptography, argon2-cffi,
                       sqlalchemy, aiosqlite, python-multipart
  commun/              bd.py (SQLite WAL), jwt.py (RS256 + JWKS), pseudo.py (filtre UGC),
                       limites.py (débit), journal.py
  auth/main.py         service 8111
  jeu/main.py          service 8112 (REST + WS)
  jeu/table.py         table en mémoire, sièges, sockets, temporisateurs
  jeu/resolveur_reseau.py   ResolveurTapeReseau
  migrations/          001_initial.sql, …
  systemd/corsian-auth.service · corsian-jeu.service · corsian-sauvegarde.service/.timer
  tests/               client headless, simulation de tables complètes
site/                  fichiers statiques publiés (voir §7)
docs/                  le présent dossier
demo.py                inchangé — valide le moteur hors ligne
```

### 1.2 Sur noe

```
/home/nicee/corsian-battle/
  app/                      code déployé (miroir de serveur/ + bataille_corse/)
    bataille_corse/         ← indispensable : le moteur est importé par corsian-jeu
    serveur/
  .venv/                    environnement Python isolé (python3 -m venv)
  var/corsian.db            base (+ -wal, -shm)
  var/cles/                 clé privée RS256, chmod 600, hors dépôt
  sauvegardes/              VACUUM INTO quotidiens, 7 jours
  logs/                     journaux applicatifs (si besoin en plus de journald)

/home/nicee/agent/softopik/projects/corsian-battle/    ← racine statique nginx (déjà déclarée)
  index.html              ✅ landing officielle, 15 Ko — À CONSERVER TEL QUEL
  static/                 ✅ logo_og.png, logo_site.png — la landing en dépend : ne pas
                             renommer ni déplacer ces deux fichiers
  privacy.html            à créer (nom réservé par la spec)
  terms.html              à créer
  suppression-compte.html à créer
  support.html            à créer
  apk/                    binaires Android signés à télécharger
  aab/                    (usage interne : téléversement Play Console)
```

**Règle de sécurité** : `var/cles/` et `var/` ne sont jamais dans le dépôt, jamais servis par
nginx (la racine statique est une arborescence différente — vérification à faire malgré tout,
car `alias` et chemins relatifs ont déjà causé des fuites ailleurs).

## 2. Environnement Python

```bash
cd ~/corsian-battle
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r app/serveur/requirements.txt
```

Budget disque : ~120 Mo pour ces paquets (aucun binaire lourd, pas de torch/pandas). Sur 8,8 Go
libres, sans objet. **Ne jamais** réutiliser le venv de 44i ni celui d'open-webui.

Version Python de la machine : 3.12.3 → cible de code 3.12 (pas de syntaxe 3.13+).

## 3. Fichiers d'environnement

`/etc/corsian/auth.env` et `/etc/corsian/jeu.env`, propriétaires `root:nicee`, `chmod 640` :

```ini
# corsian-auth
HOST=127.0.0.1
PORT=8111
BASE_DSN=sqlite:////home/nicee/corsian-battle/var/corsian.db
CLE_PRIVEE=/home/nicee/corsian-battle/var/cles/auth-rs256.pem
KID=2026-09
DUREE_ACCES_S=900
DUREE_REFRESH_J=30
PREFIXE_PUBLIC=/corsian-battle
ORIGINE_PUBLIQUE=https://soft.opik.net

# corsian-jeu
HOST=127.0.0.1
PORT=8112
BASE_DSN=sqlite:////home/nicee/corsian-battle/var/corsian.db
JWKS_LOCAL=http://127.0.0.1:8111/api/auth/.well-known/jwks.json
PREFIXE_PUBLIC=/corsian-battle
ORIGINE_PUBLIQUE=https://soft.opik.net
FENETRE_TAPE_MS=900
DELAI_TOUR_MS=12000
GRACE_DECONNEXION_S=30
MAX_TABLES=200
```

Aucun secret dans le dépôt. La clé privée est générée une fois sur la machine :

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out ~/corsian-battle/var/cles/auth-rs256.pem
chmod 600 ~/corsian-battle/var/cles/auth-rs256.pem
```

## 4. Units systemd

`/etc/systemd/system/corsian-auth.service`

```ini
[Unit]
Description=Corsian-Battle — authentification (8111)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nicee
Group=nicee
WorkingDirectory=/home/nicee/corsian-battle/app
EnvironmentFile=/etc/corsian/auth.env
ExecStart=/home/nicee/corsian-battle/.venv/bin/uvicorn serveur.auth.main:app \
          --host 127.0.0.1 --port 8111 --workers 1 \
          --proxy-headers --forwarded-allow-ips 127.0.0.1 \
          --no-access-log
Restart=always
RestartSec=3
# Durcissement — aucun de ces services n'a besoin d'écrire ailleurs que var/
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/nicee/corsian-battle/var /home/nicee/corsian-battle/sauvegardes
MemoryMax=350M
CPUQuota=60%

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/corsian-jeu.service` : identique, avec `EnvironmentFile=/etc/corsian/jeu.env`,
port `8112`, `serveur.jeu.main:app`, `MemoryMax=450M` (les tables vivent en mémoire),
`After=network-online.target corsian-auth.service`.

⚠️ `--workers 1` est **obligatoire** : les tables sont en mémoire dans le processus. Deux
workers produiraient deux univers de jeu parallèles.

`corsian-sauvegarde.timer` + `.service` : `VACUUM INTO` quotidien à 04:20, purge à 7 jours.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now corsian-auth corsian-jeu
sudo systemctl enable --now corsian-sauvegarde.timer
```

## 5. nginx

### 5.1 ⏳ Blocs à ajouter au vhost `soft.opik.net` (443)

Voir `ARCHITECTURE.md` §4.3 pour le texte exact. En résumé :

```nginx
location /corsian-battle/api/auth/ { proxy_pass http://127.0.0.1:8111/api/auth/; … }
location /corsian-battle/api/jeu/  { proxy_pass http://127.0.0.1:8112/api/jeu/;  … }
```

### 5.2 ✅ `location` WS existant — une seule directive à ajouter

Le bloc `location ^~ /corsian-battle/ws` est **déjà en place et correct** : chemin
(`proxy_pass http://127.0.0.1:8112/ws` → backend `/ws`), `proxy_http_version 1.1`, en-têtes
`Upgrade`/`Connection`, timeouts longs. Rien à reprendre. État actuel, pour référence :

```nginx
location ^~ /corsian-battle/ws {
    proxy_pass http://127.0.0.1:8112/ws;
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout  3600s;
    proxy_send_timeout  3600s;
    proxy_buffering     off;
}
```

Sans `proxy_read_timeout` long, nginx coupe à 60 s ; sans `proxy_buffering off`, les messages
peuvent arriver par paquets et casser le rythme du doublon.

### 5.3 Vérification

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Le vhost comporte déjà des avertissements bénins (valeurs `TLSv1.2` dupliquées, *server name*
en double) : `nginx -t` doit rester à `successful`, les `[warn]` ne sont pas bloquants.

## 6. Mise en service et recette

| Étape | Commande | Attendu |
|---|---|---|
| 1. Ports libres | `ss -ltnp \| grep -E ':8111\|:8112'` | vide **avant** démarrage |
| 2. Schéma | premier démarrage → migrations appliquées | `sqlite3 var/corsian.db '.tables'` liste les tables |
| 3. Santé locale | `curl -s 127.0.0.1:8111/api/auth/sante` | `{"etat":"ok",…}` |
| 4. Santé publique | `curl -i https://soft.opik.net/corsian-battle/api/auth/sante` | `200` |
| 5. Config publique | `curl -s .../api/jeu/config` | `fenetre_tape_ms: 900` |
| 6. Compte invité | `POST .../api/auth/invite` | jeton + `nouveau_compte: true` |
| 7. Table | `POST .../api/jeu/tables` | code à 6 caractères |
| 8. WS | `curl -i -N -H 'Connection: Upgrade' …/corsian-battle/ws` | `101 Switching Protocols` |
| 9. WS outillé | `websocat wss://soft.opik.net/corsian-battle/ws` puis `bonjour` | `bienvenue` + `table_etat` |
| 10. Mémoire | `systemctl status corsian-*`, `free -m` | < 450 Mo cumulés, swap stable |
| 11. Reprise | `sudo systemctl restart corsian-jeu` pendant une table | table rechargée depuis `tables_snapshot` |
| 12. Sauvegarde | `systemctl start corsian-sauvegarde.service` | fichier `sauvegardes/corsian-AAAA-MM-JJ.db` |

Recette complète en §6 de `ENDPOINTS.md`.

## 7. Publication des binaires et du site

1. **APK/AAB construits par GitHub Actions**, jamais sur noe : le swap est déjà à 1,9 Go sur
   3,6 Go, un `flutter build` y mettrait la machine à genoux (et les builds actuels régénèrent
   `android/`, cf. §9).
2. Récupération de l'artefact depuis Termux (API GitHub + PAT), puis dépôt dans
   `~/agent/softopik/projects/corsian-battle/apk/`.
3. **Signature release** : keystore généré une fois, conservé **hors** dépôt (Termux + copie
   chiffrée), alias et empreinte notés dans un endroit sûr — une clé Play perdue = application
   définitivement impossibles à mettre à jour.
4. Le site pointe vers `apk/corsian-battle-<version>.apk` avec l'empreinte SHA-256 affichée, et
   vers la fiche Play pour l'AAB.
5. iOS : aucun fichier à servir (TestFlight uniquement) — encart « bientôt ».

## 8. Exploitation courante

```bash
# Journaux
journalctl -u corsian-auth -u corsian-jeu -f
journalctl -u corsian-jeu --since "1 h ago" | grep -i erreur

# Redémarrage (interrompt les tables en cours ; les snapshots limitent la casse)
sudo systemctl restart corsian-jeu

# État des tables actives (diagnostic)
curl -s 127.0.0.1:8112/api/jeu/sante

# Mode maintenance (coupe le multijoueur sans arrêter le service)
curl -s 127.0.0.1:8112/api/jeu/maintenance   # bascule

# Sauvegarde manuelle
sqlite3 ~/corsian-battle/var/corsian.db \
  "VACUUM INTO '/home/nicee/corsian-battle/sauvegardes/corsian-manuel.db'"
```

**Mise à jour du code** : `git pull` dans `~/corsian-battle/app` → `pip install -r
requirements.txt` si nécessaire → migrations automatiques au démarrage →
`sudo systemctl restart corsian-auth corsian-jeu`. Interruption de quelques secondes.

**Retour arrière** : `git checkout <tag précédent>` + restauration de la sauvegarde si une
migration a été appliquée (les migrations ne sont pas réversibles automatiquement).

## 9. Contraintes CI à connaître

| Contrainte | Conséquence |
|---|---|
| Le jeton GitHub de l'assistant n'a pas le scope `workflow` | Impossible de créer/modifier un YAML de workflow ni de déclencher `workflow_dispatch` (403). **Nicolas pose les YAML dans l'UI** et lance les builds |
| `build-apk.yml` régénère `android/` par `flutter create` à chaque build | Tout SDK exigeant une configuration native est impossible : AdMob App ID, Google Sign-In, **App Links d'invitation**, notifications. D'où le choix d'une invitation par **code + page web** (`PROTOCOLE.md` §4) qui fonctionne sans rien de natif |
| Build actuel en `--debug` (~85 Mo) | Non publiable. S5 : passer en `--release` + AAB + signature |
| Pas de `release`/`tag` dans le workflow | Les artefacts se récupèrent via l'API JSON ; une voie « release GitHub » reste à poser par Nicolas |
| Aucun macOS disponible | Pas de build iOS, donc pas de TestFlight tant qu'un accès Mac n'existe pas |

## 10. ⏳ Points à trancher avant toute installation

1. **Contenu de la racine statique** : `ls -la /home/nicee/agent/softopik/projects/corsian-battle/`.
   Politique : strictement additif, aucun `index.html` existant écrasé.
2. **Ajout des deux blocs `location` API** (§5.1) et **complément du bloc WS** (§5.2), par
   Nicolas, puis `sudo nginx -t`.
3. **Budget mémoire** : 2 × 80 à 450 Mo (plafonnés par `MemoryMax`) alors que le swap est déjà
   à 1,9 Go / 3,6 Go. À confirmer, éventuellement en arrêtant `ollama` pendant les phases de
   test — mais `ProtectHome`/`MemoryMax` rendent l'incident borné.
4. **Emplacement des clés** et politique de sauvegarde du keystore de signature (perte =
   application morte sur Play).
5. **Validation du nom de domaine applicatif** : tout passe par `soft.opik.net/corsian-battle/`.
   Un sous-domaine dédié (par ex. `jeu.opik.net`) simplifierait les cookies/CORS et les App Links
   plus tard, mais ajoute un certificat à émettre. Décision à prendre avant S1.
