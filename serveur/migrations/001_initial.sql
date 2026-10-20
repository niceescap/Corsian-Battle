-- Corsian-Battle — schéma initial (version 1)
-- Référence : docs/SCHEMA_BD.md. Appliqué automatiquement au démarrage par
-- serveur/commun/bd.initialiser(). Aucune migration n'est réversible :
-- sauvegarde `VACUUM INTO` avant toute intervention manuelle.

-- ── Joueurs ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS joueurs (
    id                  TEXT PRIMARY KEY,
    pseudo              TEXT NOT NULL,
    pseudo_min          TEXT NOT NULL,
    email               TEXT,
    mot_de_passe_hash   TEXT,
    cree_le             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    dernier_vu_le       TEXT,
    langue              TEXT NOT NULL DEFAULT 'fr',
    statut              TEXT NOT NULL DEFAULT 'actif'
                          CHECK (statut IN ('actif','suspendu','supprime')),
    UNIQUE (pseudo_min)
);

-- ── Appareils ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS appareils (
    id                  TEXT PRIMARY KEY,
    joueur_id           TEXT NOT NULL REFERENCES joueurs(id) ON DELETE CASCADE,
    uuid_appareil       TEXT NOT NULL,
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
    empreinte     TEXT NOT NULL UNIQUE,
    cree_le       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    expire_le     TEXT NOT NULL,
    revoque_le    TEXT,
    ip_creation   TEXT
);
CREATE INDEX IF NOT EXISTS idx_refresh_joueur     ON sessions_refresh(joueur_id);
CREATE INDEX IF NOT EXISTS idx_refresh_expiration ON sessions_refresh(expire_le);

-- ── Parties terminées ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS parties (
    id             TEXT PRIMARY KEY,
    code_table     TEXT NOT NULL,
    type           TEXT NOT NULL CHECK (type IN ('duel','table_quatre','locale')),
    cree_le        TEXT NOT NULL,
    terminee_le    TEXT,
    gagnant_id     TEXT REFERENCES joueurs(id) ON DELETE SET NULL,
    raison_fin     TEXT CHECK (raison_fin IN ('victoire','abandon','partie_nulle','expiration')),
    nb_coups       INTEGER,
    nb_doublons    INTEGER,
    duree_ms       INTEGER,
    seed           INTEGER,
    recit_json     TEXT
);
CREATE INDEX IF NOT EXISTS idx_parties_terminee ON parties(terminee_le);
CREATE INDEX IF NOT EXISTS idx_parties_gagnant  ON parties(gagnant_id);

-- ── Participations ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS participations (
    partie_id            TEXT NOT NULL REFERENCES parties(id) ON DELETE CASCADE,
    joueur_id            TEXT REFERENCES joueurs(id) ON DELETE SET NULL,
    siege                INTEGER NOT NULL,
    pseudo_affiche       TEXT,
    est_bot              INTEGER NOT NULL DEFAULT 0,
    remplace_en_cours    INTEGER NOT NULL DEFAULT 0,
    nb_cartes_final      INTEGER,
    doublons_gagnes      INTEGER NOT NULL DEFAULT 0,
    doublons_perdus      INTEGER NOT NULL DEFAULT 0,
    tapes_manquees       INTEGER NOT NULL DEFAULT 0,
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
    coups_json   TEXT NOT NULL
);

-- ── Signalements (obligation UGC Google Play) ──────────────────────────────
CREATE TABLE IF NOT EXISTS signalements (
    id            TEXT PRIMARY KEY,
    emetteur_id   TEXT REFERENCES joueurs(id) ON DELETE SET NULL,
    cible_id      TEXT REFERENCES joueurs(id) ON DELETE CASCADE,
    partie_id     TEXT REFERENCES parties(id) ON DELETE SET NULL,
    motif         TEXT NOT NULL CHECK (motif IN ('pseudo','comportement','triche','autre')),
    detail        TEXT,
    cree_le       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    traite_le     TEXT,
    decision      TEXT CHECK (decision IN ('classe','avertissement','suspension'))
);
CREATE INDEX IF NOT EXISTS idx_signalements_cible        ON signalements(cible_id);
CREATE INDEX IF NOT EXISTS idx_signalements_nontraites   ON signalements(traite_le);

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

-- ── Statistiques (vue calculée, jamais dupliquée) ──────────────────────────
CREATE VIEW IF NOT EXISTS v_stats_joueur AS
SELECT
    j.id                                            AS joueur_id,
    j.pseudo                                        AS pseudo,
    COUNT(DISTINCT pa.id)                           AS parties,
    COUNT(DISTINCT CASE WHEN pa.gagnant_id = j.id THEN pa.id END) AS victoires,
    COALESCE(SUM(p.doublons_gagnes), 0)             AS doublons_gagnes,
    COALESCE(SUM(p.tapes_manquees), 0)              AS tapes_manquees,
    AVG(p.delai_tape_median_ms)                     AS delai_moyen_ms
FROM joueurs j
JOIN participations p ON p.joueur_id = j.id
JOIN parties pa       ON pa.id = p.partie_id
WHERE p.est_bot = 0 AND pa.terminee_le IS NOT NULL
GROUP BY j.id;
