# Corsian-Battle — Schéma de base de données

> SQLite 3 en mode **WAL**, fichier unique `~/corsian-battle/var/corsian.db`.
> Couche d'accès : SQLAlchemy **Core** (pas d'ORM) — un simple jeu de cartes n'a pas besoin
> d'unit-of-work, et Core garde la porte ouverte vers PostgreSQL sans réécrire le métier.

---

## 1. Ce qui est en base — et ce qui n'y est pas

**En base** : identités et comptes, appareils, sessions de rafraîchissement, parties
**terminées**, statistiques cumulées, instantanés de reprise des tables actives, signalements,
blocages, suspicions anti-triche.

**Jamais en base** :

| Donnée | Où elle vit | Pourquoi |
|---|---|---|
| Ordre du paquet d'une partie en cours | Mémoire du processus `corsian-jeu` | Écrire à chaque carte userait le disque et ajouterait de la latence ; un instantané périodique suffit |
| Connexions WebSocket, fenêtres de tape, temporisateurs de tour | Mémoire | Non reconstructible, sans valeur après coupure |
| Mots de passe | Jamais (empreinte argon2id uniquement) | — |
| Jetons de rafraîchissement en clair | Jamais (empreinte SHA-256) | Une fuite de base ne doit pas permettre d'usurper une session |
| Cartes des joueurs en cours de partie | Mémoire | Voir `PROTOCOLE.md` §8 |

**Ordre de grandeur** : un joueur ≈ 300 o, une partie terminée ≈ 600 o avec son récit compact.
10 000 parties ≈ 6 Mo. La base restera sous les 100 Mo très longtemps — le disque de noe est à
86 %, c'est un argument décisif pour SQLite plutôt qu'un serveur Postgres dédié.

## 2. Configuration SQLite

### 2.1 Pragmatiques appliqués à chaque connexion

```sql
PRAGMA journal_mode = WAL;          -- lecture/écriture concurrentes, indispensable en prod
PRAGMA synchronous = NORMAL;        -- bon compromis ; FULL n'apporte rien ici (pas de paiement)
PRAGMA foreign_keys = ON;           -- désactivé par défaut dans SQLite : à ne jamais oublier
PRAGMA busy_timeout = 5000;         -- attend 5 s au lieu d'échouer si un autre processus écrit
PRAGMA journal_size_limit = 4194304;-- borne le WAL à 4 Mo
PRAGMA temp_store = MEMORY;
```

### 2.2 Fichiers

| Fichier | Rôle | Sauvegardé |
|---|---|---|
| `corsian.db` | Base | non (copie quotidienne) |
| `corsian.db-wal` | Journal d'écriture anticipée | non |
| `corsian.db-shm` | Index partagé du WAL | non |

Ne **jamais** copier `corsian.db` seul pendant une écriture : la sauvegarde passe par
`VACUUM INTO` (§7), qui produit un fichier cohérent.

### 2.3 Taille et croissance

WAL borné à 4 Mo, `wal_checkpoint(TRUNCATE)` exécuté par une tâche périodique (toutes les
5 min dans `corsian-jeu`) pour éviter un WAL qui gonfle en exploitation continue.

### 2.4 Règle d'écriture entre les deux processus

Deux processus écrivent (`corsian-auth` et `corsian-jeu`). WAL autorise un seul écrivain à la
fois, les autres attendent — ce qui suffit largement au débit réel (quelques écritures par
partie). Trois règles à respecter à l'implémentation :

1. **Transactions courtes** : ne jamais ouvrir une transaction d'écriture puis faire de l'E/S
   réseau à l'intérieur (attente de `tape`, appel JWKS, etc.).
2. **Domaines disjoints** : `corsian-auth` n'écrit que dans `joueurs`, `appareils`,
   `sessions_refresh` ; `corsian-jeu` n'écrit que dans `parties`, `participations`,
   `tables_snapshot`, `signalements`, `blocages`, `suspicions`. Les lectures sont libres.
3. **Pas de verrou applicatif** : aucun `BEGIN IMMEDIATE` conservé au-delà de quelques
   millisecondes.

## 3. DDL

```sql
-- ── Version du schéma ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER PRIMARY KEY,
    applique_le TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    note        TEXT
);

-- ── Joueurs ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS joueurs (
    id                  TEXT PRIMARY KEY,             -- uuid4 hex, 32 caractères
    pseudo              TEXT NOT NULL,                -- filtré, ≤ 20 caractères
    pseudo_min          TEXT NOT NULL,                -- minuscule sans accents, unicité
    email               TEXT,                         -- NULL tant que le compte est invité
    mot_de_passe_hash   TEXT,                         -- argon2id ; NULL pour un compte invité
    cree_le             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    dernier_vu_le       TEXT,
    langue              TEXT NOT NULL DEFAULT 'fr',
    statut              TEXT NOT NULL DEFAULT 'actif'  -- actif | suspendu | supprime
                          CHECK (statut IN ('actif','suspendu','supprime')),
    UNIQUE (pseudo_min)
);

-- Unicité du pseudo : contrainte forte en V1 (jeu entre amis, volume faible).
-- Si elle devient gênante, la lever et suffixer le pseudo d'un discriminant court.

-- ── Appareils ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS appareils (
    id                  TEXT PRIMARY KEY,             -- uuid4 hex
    joueur_id           TEXT NOT NULL REFERENCES joueurs(id) ON DELETE CASCADE,
    uuid_appareil       TEXT NOT NULL,                -- identifiant généré côté app, réinstallable
    plateforme          TEXT NOT NULL CHECK (plateforme IN ('android','ios','web','test')),
    version_app         TEXT,
    cree_le             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    derniere_connexion  TEXT,
    UNIQUE (uuid_appareil)
);
CREATE INDEX IF NOT EXISTS idx_appareils_joueur ON appareils(joueur_id);

-- ── Sessions de rafraîchissement ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sessions_refresh (
    id            TEXT PRIMARY KEY,
    joueur_id     TEXT NOT NULL REFERENCES joueurs(id) ON DELETE CASCADE,
    appareil_id   TEXT REFERENCES appareils(id) ON DELETE SET NULL,
    empreinte     TEXT NOT NULL UNIQUE,               -- sha256(jeton refresh) hex
    cree_le       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    expire_le     TEXT NOT NULL,                      -- cree_le + 30 j
    revoque_le    TEXT,
    ip_creation   TEXT                                -- IPv4/IPv6, pour l'audit uniquement
);
CREATE INDEX IF NOT EXISTS idx_refresh_joueur   ON sessions_refresh(joueur_id);
CREATE INDEX IF NOT EXISTS idx_refresh_expiration ON sessions_refresh(expire_le);

-- ── Parties terminées ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS parties (
    id             TEXT PRIMARY KEY,
    code_table     TEXT NOT NULL,                     -- code à 6 caractères, non sensible
    type           TEXT NOT NULL CHECK (type IN ('duel','table_quatre','locale')),
    cree_le        TEXT NOT NULL,
    terminee_le    TEXT,
    gagnant_id     TEXT REFERENCES joueurs(id) ON DELETE SET NULL,  -- NULL = humain supprimé
    raison_fin     TEXT CHECK (raison_fin IN ('victoire','abandon','partie_nulle','expiration')),
    nb_coups       INTEGER,
    nb_doublons    INTEGER,
    duree_ms       INTEGER,
    seed           INTEGER,                           -- reproductibilité, jamais diffusé
    recit_json     TEXT                               -- récit compact : coups remarquables seulement
);
CREATE INDEX IF NOT EXISTS idx_parties_terminee ON parties(terminee_le);
CREATE INDEX IF NOT EXISTS idx_parties_gagnant  ON parties(gagnant_id);

-- ── Participations ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS participations (
    partie_id       TEXT NOT NULL REFERENCES parties(id) ON DELETE CASCADE,
    joueur_id       TEXT REFERENCES joueurs(id) ON DELETE SET NULL,  -- NULL après suppression
    siege           INTEGER NOT NULL,
    pseudo_affiche  TEXT,                             -- figé au moment de la partie
    est_bot         INTEGER NOT NULL DEFAULT 0,
    remplace_en_cours INTEGER NOT NULL DEFAULT 0,     -- bot a pris la main
    nb_cartes_final INTEGER,
    doublons_gagnes INTEGER NOT NULL DEFAULT 0,
    doublons_perdus INTEGER NOT NULL DEFAULT 0,
    tapes_manquees  INTEGER NOT NULL DEFAULT 0,
    delai_tape_median_ms REAL,
    PRIMARY KEY (partie_id, siege)
);
CREATE INDEX IF NOT EXISTS idx_participations_joueur ON participations(joueur_id);

-- ── Instantanés de reprise ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tables_snapshot (
    code_table   TEXT PRIMARY KEY,
    partie_id    TEXT NOT NULL,
    maj_le       TEXT NOT NULL,
    nb_coups     INTEGER NOT NULL,
    seed         INTEGER NOT NULL,
    coups_json   TEXT NOT NULL                        -- liste ordonnée des coups à rejouer
);

-- Volontairement minimal : on ne stocke pas l'état du moteur, on stocke de quoi le
-- reconstruire (seed + coups). Plus petit, et garanti cohérent avec les règles.

-- ── Signalements (obligation UGC Google Play) ──────────────────────────────
CREATE TABLE IF NOT EXISTS signalements (
    id            TEXT PRIMARY KEY,
    emetteur_id   TEXT REFERENCES joueurs(id) ON DELETE SET NULL,
    cible_id      TEXT REFERENCES joueurs(id) ON DELETE CASCADE,
    partie_id     TEXT REFERENCES parties(id) ON DELETE SET NULL,
    motif         TEXT NOT NULL CHECK (motif IN
                    ('pseudo','comportement','triche','autre')),
    detail        TEXT,                               -- ≤ 200 caractères, jamais de carte blanche
    cree_le       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    traite_le     TEXT,
    decision      TEXT CHECK (decision IN ('classe','avertissement','suspension'))
);
CREATE INDEX IF NOT EXISTS idx_signalements_cible ON signalements(cible_id);
CREATE INDEX IF NOT EXISTS idx_signalements_nontraites ON signalements(traite_le);

-- ── Blocages entre joueurs ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS blocages (
    bloqueur_id  TEXT NOT NULL REFERENCES joueurs(id) ON DELETE CASCADE,
    bloque_id    TEXT NOT NULL REFERENCES joueurs(id) ON DELETE CASCADE,
    cree_le      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    PRIMARY KEY (bloqueur_id, bloque_id)
);

-- ── Suspicions anti-triche ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS suspicions (
    id          TEXT PRIMARY KEY,
    joueur_id   TEXT NOT NULL REFERENCES joueurs(id) ON DELETE CASCADE,
    partie_id   TEXT REFERENCES parties(id) ON DELETE SET NULL,
    type        TEXT NOT NULL CHECK (type IN
                  ('delai_impossible','delai_sous_plancher','rafale_messages','coup_perime')),
    valeur_ms   INTEGER,
    cree_le     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_suspicions_joueur ON suspicions(joueur_id, cree_le);

-- ── Statistiques : vue calculée, pas de table dupliquée ────────────────────
CREATE VIEW IF NOT EXISTS v_stats_joueur AS
SELECT
    j.id                                            AS joueur_id,
    j.pseudo                                        AS pseudo,
    COUNT(DISTINCT p.partie_id)                     AS parties,
    COUNT(DISTINCT CASE WHEN p.gagnant_id = j.id
                        THEN p.partie_id END)       AS victoires,
    COALESCE(SUM(p.doublons_gagnes), 0)             AS doublons_gagnes,
    COALESCE(SUM(p.tapes_manquees), 0)              AS tapes_manquees,
    AVG(p.delai_tape_median_ms)                     AS delai_moyen_ms
FROM joueurs j
JOIN participations p ON p.joueur_id = j.id
JOIN parties       pa ON pa.id = p.partie_id
WHERE p.est_bot = 0 AND pa.terminee_le IS NOT NULL
GROUP BY j.id;
```

## 4. Choix de conception

| Choix | Justification |
|---|---|
| Identifiants TEXT (uuid4 hex) | Pas de séquence à coordonner entre deux processus, aucun compteur devinable côté client |
| `pseudo_min` unique | Insensibilité casse/accents sans fonction dans la contrainte (SQLite `NOCASE` ne gère pas les accents) |
| `joueur_id` **nullable** sur `participations` et `parties.gagnant_id` | La suppression d'un compte efface ses données personnelles **sans** trouer l'historique des autres joueurs (voir §6) |
| `est_bot` sur `participations` | Exclut les bots des statistiques et du classement, sans table séparée |
| Statistiques en **vue** et non en table | Zéro désynchronisation possible ; le volume (milliers de parties) ne justifie pas de cache. Si le classement devient lent, on matérialisera dans `stats_joueur` avec une tâche nocturne |
| `tables_snapshot` = seed + coups, pas l'état brut | Plus petit, vérifiable, et impossible de restaurer un état contraire aux règles |
| `recit_json` limité aux coups remarquables | Un récit complet (200 000 coups possibles) ferait exploser la base |
| Timestamps TEXT ISO-8601 UTC | Lisible en `sqlite3`, tri lexicographique correct, pas de piège de fuseau |

## 5. Requêtes types

```sql
-- Connexion d'un appareil déjà connu (compte invité)
SELECT j.* FROM joueurs j
JOIN appareils a ON a.joueur_id = j.id
WHERE a.uuid_appareil = ? AND j.statut = 'actif';

-- Renouvellement de jeton
SELECT * FROM sessions_refresh
WHERE empreinte = ? AND revoque_le IS NULL AND expire_le > strftime('%Y-%m-%dT%H:%M:%fZ','now');

-- Classement (10 premiers, 30 derniers jours)
SELECT joueur_id, pseudo, COUNT(*) AS parties,
       SUM(CASE WHEN gagnant_id = joueur_id THEN 1 ELSE 0 END) AS victoires
FROM participations p JOIN parties pa ON pa.id = p.partie_id
WHERE p.est_bot = 0 AND pa.terminee_le > ?
GROUP BY joueur_id ORDER BY victoires DESC, parties DESC LIMIT 10;

-- Purge des sessions expirées (tâche quotidienne)
DELETE FROM sessions_refresh WHERE expire_le < strftime('%Y-%m-%dT%H:%M:%fZ','now');

-- Suspicions d'un joueur sur 24 h (seuil d'alerte)
SELECT COUNT(*) FROM suspicions
WHERE joueur_id = ? AND cree_le > strftime('%Y-%m-%dT%H:%M:%fZ','now','-1 day');
```

## 6. Suppression de compte (RGPD + obligation Play)

`DELETE /api/auth/compte` exécute, dans une seule transaction :

```sql
UPDATE participations SET joueur_id = NULL, pseudo_affiche = 'Joueur'
  WHERE joueur_id = :id;
UPDATE parties      SET gagnant_id = NULL WHERE gagnant_id = :id;
UPDATE signalements SET emetteur_id = NULL WHERE emetteur_id = :id;
DELETE FROM joueurs WHERE id = :id;   -- cascade : appareils, sessions, suspicions, blocages
```

Effet : **toute donnée personnelle disparaît** (email, empreinte de mot de passe, identifiants
d'appareil, jetons, historique nominatif), tandis que les parties des autres joueurs restent
cohérentes (un siège anonymisé). Aucune récupération possible — c'est annoncé tel quel dans la
politique de confidentialité.

Délai de grâce : aucun (la suppression est immédiate, conformément aux règles Play sur les URL
de suppression de compte).

## 7. Sauvegarde et restauration

```bash
# Sauvegarde cohérente à chaud (aucune interruption de service)
sqlite3 ~/corsian-battle/var/corsian.db \
  "VACUUM INTO '/home/nicee/corsian-battle/sauvegardes/corsian-$(date +%F).db'"

# Conservation : 7 jours
find ~/corsian-battle/sauvegardes -name 'corsian-*.db' -mtime +7 -delete

# Restauration
systemctl stop corsian-jeu corsian-auth
cp ~/corsian-battle/sauvegardes/corsian-2026-09-15.db ~/corsian-battle/var/corsian.db
rm -f ~/corsian-battle/var/corsian.db-wal ~/corsian-battle/var/corsian.db-shm
systemctl start corsian-auth corsian-jeu
```

Fréquence : tâche quotidienne (timer systemd). Une sauvegarde pèse quelques Mo ; 7 jours de
rétention restent sous les 100 Mo — compatible avec les 8,8 Go libres.

## 8. Migrations

Table `schema_version` + un dossier `serveur/migrations/00X_*.sql` appliqués dans l'ordre au
démarrage, chacun dans une transaction, avec insertion de sa version. Règles :

1. Aucune migration destructive sans sauvegarde préalable vérifiée.
2. Ajout de colonne → `ALTER TABLE … ADD COLUMN` avec valeur par défaut (SQLite le gère bien).
3. Modification de contrainte → recréation de table (`CREATE TABLE neuf … ; INSERT SELECT … ;
   DROP … ; RENAME …`) dans une transaction, `foreign_keys = OFF` le temps de l'opération.
4. Le démarrage refuse de servir si la version en base est **supérieure** à celle du code
   (protection contre un retour arrière de déploiement).

## 9. Bascule éventuelle vers PostgreSQL

Prévue mais non souhaitée à court terme. Ce qui coûterait du travail :

- les timestamps TEXT → `timestamptz` ;
- `VACUUM INTO` → `pg_dump` ;
- les pragmatiques WAL → sans objet ;
- la vue `v_stats_joueur` → à réécrire (syntaxe quasi identique).

Rien dans le schéma n'utilise de spécificité SQLite bloquante (pas de `WITHOUT ROWID`, pas de
JSON1 dans les contraintes). Le déclencheur de migration serait le besoin de plusieurs
processus écrivains ou d'un classement temps réel sur des millions de parties.
