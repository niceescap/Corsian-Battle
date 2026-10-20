"""Accès à la base SQLite (mode WAL) — schéma dans `docs/SCHEMA_BD.md`.

Choix assumé pour cette première livraison : le module `sqlite3` de la
bibliothèque standard plutôt que SQLAlchemy Core. Raisons :

- aucune dépendance supplémentaire à installer sur noe (swap déjà entamé) ;
- aucun risque de divergence de version entre la machine et le dépôt ;
- tout l'accès aux données est **confiné dans ce fichier** : les fonctions
  exposées ont les signatures qu'aurait une couche SQLAlchemy, basculer plus
  tard ne touchera que ce module.

Règles d'usage (rappel de `docs/SCHEMA_BD.md` §2.4) :

1. transactions courtes — jamais d'E/S réseau dans une transaction ;
2. une connexion par appel (SQLite + WAL le gèrent très bien) ;
3. `corsian-auth` n'écrit que dans `joueurs`, `appareils`, `sessions_refresh` ;
   `corsian-jeu` n'écrit que dans `parties`, `participations`,
   `tables_snapshot`, `signalements`, `blocages`, `suspicions`.
"""
from __future__ import annotations

import contextlib
import os
import shutil
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

# Aliases exposés aux services : `bd` reste le **seul** module du dépôt qui
# importe `sqlite3`. Ailleurs on écrit `bd.Connexion` (annotations) et
# `bd.ErreurIntegrite` (contrainte d'unicité violée), ce qui garantit qu'un
# futur passage à SQLAlchemy Core ne touchera que ce fichier.
Connexion = sqlite3.Connection
ErreurIntegrite = sqlite3.IntegrityError

PRAGMATIQUES: tuple[str, ...] = (
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = NORMAL",
    "PRAGMA foreign_keys = ON",
    "PRAGMA busy_timeout = 5000",
    "PRAGMA journal_size_limit = 4194304",
    "PRAGMA temp_store = MEMORY",
)


def maintenant_iso(decalage_s: float = 0.0) -> str:
    """Horodatage UTC ISO-8601 au format utilisé par le schéma."""
    instant = time.time() + decalage_s
    millisecondes = int((instant % 1) * 1000)
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(instant)) + f".{millisecondes:03d}Z"


def dossier_migrations() -> Path:
    return Path(__file__).resolve().parent.parent / "migrations"


@contextlib.contextmanager
def connexion(chemin: str) -> Iterator[sqlite3.Connection]:
    dossier = os.path.dirname(os.path.abspath(chemin))
    if dossier:
        os.makedirs(dossier, exist_ok=True)
    conn = sqlite3.connect(chemin, timeout=5.0)
    conn.row_factory = sqlite3.Row
    try:
        for pragma in PRAGMATIQUES:
            conn.execute(pragma)
        yield conn
    finally:
        conn.close()


def initialiser(chemin: str, dossier: Optional[Path] = None) -> List[int]:
    """Crée le schéma et applique les migrations manquantes.

    Renvoie la liste des versions appliquées (vide si la base est à jour).
    Idempotent : peut être appelé à chaque démarrage.
    """
    dossier = dossier or dossier_migrations()
    fichiers = sorted(Path(dossier).glob("[0-9][0-9][0-9]_*.sql"))
    appliquees: List[int] = []
    with connexion(chemin) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_version ("
            " version INTEGER PRIMARY KEY,"
            " applique_le TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),"
            " note TEXT)"
        )
        conn.commit()
        deja = {ligne["version"] for ligne in conn.execute("SELECT version FROM schema_version")}
        for fichier in fichiers:
            try:
                version = int(fichier.name.split("_", 1)[0])
            except ValueError:
                continue
            if version in deja:
                continue
            conn.executescript(fichier.read_text(encoding="utf-8"))
            conn.execute(
                "INSERT INTO schema_version(version, note) VALUES(?, ?)",
                (version, fichier.name),
            )
            conn.commit()
            appliquees.append(version)
    return appliquees


def pourcentage_disque(chemin: str) -> int:
    """Taux d'occupation du volume portant la base (0 si indisponible)."""
    try:
        usage = shutil.disk_usage(os.path.dirname(os.path.abspath(chemin)) or ".")
    except OSError:
        return 0
    if usage.total <= 0:
        return 0
    return int(round(100.0 * usage.used / usage.total))


def espace_libre_mo(chemin: str) -> int:
    try:
        usage = shutil.disk_usage(os.path.dirname(os.path.abspath(chemin)) or ".")
    except OSError:
        return -1
    return int(usage.free // (1024 * 1024))


# ---------------------------------------------------------------------------
# Joueurs et appareils
# ---------------------------------------------------------------------------
def _ligne(ligne: Optional[sqlite3.Row]) -> Optional[Dict[str, Any]]:
    return dict(ligne) if ligne is not None else None


def joueur_par_id(conn: sqlite3.Connection, joueur_id: str) -> Optional[Dict[str, Any]]:
    return _ligne(
        conn.execute(
            "SELECT id, pseudo, email, cree_le, dernier_vu_le, langue, statut "
            "FROM joueurs WHERE id = ?",
            (joueur_id,),
        ).fetchone()
    )


def joueur_par_appareil(
    conn: sqlite3.Connection, uuid_appareil: str
) -> Optional[Dict[str, Any]]:
    """Compte rattaché à un appareil (idempotence de `POST /invite`)."""
    return _ligne(
        conn.execute(
            "SELECT j.id, j.pseudo, j.email, j.cree_le, j.dernier_vu_le, j.langue, "
            "       j.statut, a.id AS appareil_id "
            "FROM appareils a JOIN joueurs j ON j.id = a.joueur_id "
            "WHERE a.uuid_appareil = ?",
            (uuid_appareil,),
        ).fetchone()
    )


def pseudo_min_pris(conn: sqlite3.Connection, cle: str) -> bool:
    ligne = conn.execute(
        "SELECT 1 FROM joueurs WHERE pseudo_min = ? AND statut != 'supprime'", (cle,)
    ).fetchone()
    return ligne is not None


def creer_joueur(
    conn: sqlite3.Connection,
    joueur_id: str,
    pseudo: str,
    cle_uniq: str,
    langue: str = "fr",
) -> None:
    """Lève `sqlite3.IntegrityError` si le pseudo est déjà pris."""
    with conn:
        conn.execute(
            "INSERT INTO joueurs(id, pseudo, pseudo_min, langue, statut) "
            "VALUES(?, ?, ?, ?, 'actif')",
            (joueur_id, pseudo, cle_uniq, langue),
        )


def creer_appareil(
    conn: sqlite3.Connection,
    appareil_id: str,
    joueur_id: str,
    uuid_appareil: str,
    plateforme: str,
    version_app: Optional[str] = None,
) -> None:
    with conn:
        conn.execute(
            "INSERT INTO appareils(id, joueur_id, uuid_appareil, plateforme, "
            "                      version_app, derniere_connexion) "
            "VALUES(?, ?, ?, ?, ?, ?)",
            (appareil_id, joueur_id, uuid_appareil, plateforme, version_app, maintenant_iso()),
        )


def appareils_du_joueur(conn: sqlite3.Connection, joueur_id: str) -> List[Dict[str, Any]]:
    lignes = conn.execute(
        "SELECT id, plateforme, version_app, cree_le, derniere_connexion "
        "FROM appareils WHERE joueur_id = ? ORDER BY derniere_connexion DESC",
        (joueur_id,),
    ).fetchall()
    return [dict(ligne) for ligne in lignes]


def touch_joueur(conn: sqlite3.Connection, joueur_id: str) -> None:
    with conn:
        conn.execute(
            "UPDATE joueurs SET dernier_vu_le = ? WHERE id = ?",
            (maintenant_iso(), joueur_id),
        )


def touch_appareil(
    conn: sqlite3.Connection, appareil_id: str, version_app: Optional[str] = None
) -> None:
    if version_app:
        with conn:
            conn.execute(
                "UPDATE appareils SET derniere_connexion = ?, version_app = ? WHERE id = ?",
                (maintenant_iso(), version_app, appareil_id),
            )
    else:
        with conn:
            conn.execute(
                "UPDATE appareils SET derniere_connexion = ? WHERE id = ?",
                (maintenant_iso(), appareil_id),
            )


def stats_joueur(conn: sqlite3.Connection, joueur_id: str) -> Dict[str, Any]:
    vide = {
        "parties": 0,
        "victoires": 0,
        "doublons_gagnes": 0,
        "tapes_manquees": 0,
        "delai_moyen_ms": None,
    }
    ligne = conn.execute(
        "SELECT parties, victoires, doublons_gagnes, tapes_manquees, delai_moyen_ms "
        "FROM v_stats_joueur WHERE joueur_id = ?",
        (joueur_id,),
    ).fetchone()
    if ligne is None:
        return vide
    resultat = dict(vide)
    resultat.update({cle: ligne[cle] for cle in vide if ligne[cle] is not None})
    if resultat["delai_moyen_ms"] is not None:
        resultat["delai_moyen_ms"] = round(float(resultat["delai_moyen_ms"]), 1)
    return resultat


def supprimer_joueur(conn: sqlite3.Connection, joueur_id: str) -> bool:
    """Suppression RGPD + Play : `docs/SCHEMA_BD.md` §6.

    Efface toute donnée personnelle et anonymise les participations, pour ne
    pas trouer l'historique des autres joueurs. Renvoie `True` si un compte a
    bien été supprimé.
    """
    with conn:
        conn.execute(
            "UPDATE participations SET joueur_id = NULL, pseudo_affiche = 'Joueur' "
            "WHERE joueur_id = ?",
            (joueur_id,),
        )
        conn.execute("UPDATE parties SET gagnant_id = NULL WHERE gagnant_id = ?", (joueur_id,))
        conn.execute(
            "UPDATE signalements SET emetteur_id = NULL WHERE emetteur_id = ?", (joueur_id,)
        )
        curseur = conn.execute("DELETE FROM joueurs WHERE id = ?", (joueur_id,))
        return curseur.rowcount > 0


# ---------------------------------------------------------------------------
# Sessions de rafraîchissement
# ---------------------------------------------------------------------------
def creer_session_refresh(
    conn: sqlite3.Connection,
    session_id: str,
    joueur_id: str,
    empreinte: str,
    expire_le: str,
    appareil_id: Optional[str] = None,
    ip_creation: Optional[str] = None,
) -> None:
    with conn:
        conn.execute(
            "INSERT INTO sessions_refresh(id, joueur_id, appareil_id, empreinte, "
            "                             expire_le, ip_creation) "
            "VALUES(?, ?, ?, ?, ?, ?)",
            (session_id, joueur_id, appareil_id, empreinte, expire_le, ip_creation),
        )


def session_par_empreinte(conn: sqlite3.Connection, empreinte: str) -> Optional[Dict[str, Any]]:
    return _ligne(
        conn.execute(
            "SELECT id, joueur_id, appareil_id, cree_le, expire_le, revoque_le "
            "FROM sessions_refresh WHERE empreinte = ?",
            (empreinte,),
        ).fetchone()
    )


def revoquer_session(conn: sqlite3.Connection, session_id: str) -> None:
    with conn:
        conn.execute(
            "UPDATE sessions_refresh SET revoque_le = ? WHERE id = ? AND revoque_le IS NULL",
            (maintenant_iso(), session_id),
        )


def revoquer_sessions_appareil(conn: sqlite3.Connection, appareil_id: str) -> int:
    """Révocation en chaîne : utilisée quand un jeton déjà révoqué est rejoué."""
    with conn:
        curseur = conn.execute(
            "UPDATE sessions_refresh SET revoque_le = ? "
            "WHERE appareil_id = ? AND revoque_le IS NULL",
            (maintenant_iso(), appareil_id),
        )
        return curseur.rowcount


def purger_sessions_expirees(conn: sqlite3.Connection) -> int:
    with conn:
        curseur = conn.execute(
            "DELETE FROM sessions_refresh WHERE expire_le < ?", (maintenant_iso(),)
        )
        return curseur.rowcount


# ---------------------------------------------------------------------------
# Parties terminées (écrites par corsian-jeu uniquement)
# ---------------------------------------------------------------------------
def creer_partie(
    conn: sqlite3.Connection,
    partie_id: str,
    code_table: str,
    type_partie: str,
    cree_le: str,
    seed: int,
    terminee_le: Optional[str] = None,
    gagnant_id: Optional[str] = None,
    raison_fin: Optional[str] = None,
    nb_coups: Optional[int] = None,
    nb_doublons: Optional[int] = None,
    duree_ms: Optional[int] = None,
    recit_json: Optional[str] = None,
) -> None:
    with conn:
        conn.execute(
            "INSERT INTO parties(id, code_table, type, cree_le, terminee_le, gagnant_id, "
            "                     raison_fin, nb_coups, nb_doublons, duree_ms, seed, recit_json) "
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                partie_id, code_table, type_partie, cree_le, terminee_le, gagnant_id,
                raison_fin, nb_coups, nb_doublons, duree_ms, seed, recit_json,
            ),
        )


def creer_participation(
    conn: sqlite3.Connection,
    partie_id: str,
    siege: int,
    joueur_id: Optional[str] = None,
    pseudo_affiche: Optional[str] = None,
    est_bot: bool = False,
    remplace_en_cours: bool = False,
    nb_cartes_final: Optional[int] = None,
    doublons_gagnes: int = 0,
    doublons_perdus: int = 0,
    tapes_manquees: int = 0,
    delai_tape_median_ms: Optional[float] = None,
) -> None:
    with conn:
        conn.execute(
            "INSERT INTO participations(partie_id, joueur_id, siege, pseudo_affiche, est_bot, "
            "    remplace_en_cours, nb_cartes_final, doublons_gagnes, doublons_perdus, "
            "    tapes_manquees, delai_tape_median_ms) "
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                partie_id, joueur_id, siege, pseudo_affiche, 1 if est_bot else 0,
                1 if remplace_en_cours else 0, nb_cartes_final, doublons_gagnes,
                doublons_perdus, tapes_manquees, delai_tape_median_ms,
            ),
        )


def enregistrer_suspicion(
    conn: sqlite3.Connection,
    suspicion_id: str,
    joueur_id: str,
    type_suspicion: str,
    partie_id: Optional[str] = None,
    valeur_ms: Optional[int] = None,
) -> None:
    with conn:
        conn.execute(
            "INSERT INTO suspicions(id, joueur_id, partie_id, type, valeur_ms) "
            "VALUES(?, ?, ?, ?, ?)",
            (suspicion_id, joueur_id, partie_id, type_suspicion, valeur_ms),
        )
