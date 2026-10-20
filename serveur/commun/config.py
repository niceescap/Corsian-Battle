"""Configuration des deux services, lue dans l'environnement.

Les noms de variables sont exactement ceux de `docs/DEPLOIEMENT.md` §3, donc
les mêmes fichiers `.env` systemd fonctionnent sans adaptation.

Règles :
- aucune valeur par défaut ne doit permettre de démarrer en production avec
  une configuration muette (voir `verifier_production`) ;
- les réglages de jeu (fenêtre de tape, délai de tour…) sont **lus ici**, pas
  codés en dur dans l'app : ils sont servis par `GET /api/jeu/config`
  (`docs/ENDPOINTS.md` §4.2), ce qui permet de les ajuster sans republier.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

# Émetteur et audience des JWT : les deux services doivent s'accorder.
EMETTEUR = "corsian-auth"
AUDIENCE = "corsian-battle"

# Version du protocole WebSocket (voir docs/PROTOCOLE.md §15).
VERSION_PROTO = 1


def _texte(nom: str, defaut: str) -> str:
    brut = os.environ.get(nom)
    if brut is None:
        return defaut
    brut = brut.strip()
    return brut or defaut


def _entier(nom: str, defaut: int) -> int:
    brut = os.environ.get(nom, "").strip()
    if not brut:
        return defaut
    try:
        return int(brut)
    except ValueError:
        return defaut


def _booleen(nom: str, defaut: bool = False) -> bool:
    brut = os.environ.get(nom, "").strip().lower()
    if not brut:
        return defaut
    return brut in ("1", "oui", "true", "vrai", "yes", "on")


def chemin_depuis_dsn(dsn: str) -> str:
    """`sqlite:////home/x/y.db` → `/home/x/y.db` (chemin relatif accepté)."""
    for prefixe in ("sqlite+pysqlite:///", "sqlite:///"):
        if dsn.startswith(prefixe):
            return os.path.expanduser(dsn[len(prefixe):])
    return os.path.expanduser(dsn)


def chemin_base() -> str:
    dsn = _texte("BASE_DSN", "")
    if dsn:
        return chemin_depuis_dsn(dsn)
    return os.path.expanduser("~/corsian-battle/var/corsian.db")


@dataclass(frozen=True)
class Config:
    """Configuration d'un service. Les champs non utilisés sont ignorés."""

    service: str
    environnement: str = "dev"          # dev | prod
    hote: str = "127.0.0.1"             # jamais 0.0.0.0
    port: int = 8111
    version: str = "0.1.0"

    base_chemin: str = ""
    prefixe_public: str = "/corsian-battle"
    origine_publique: str = "https://soft.opik.net"

    # --- corsian-auth ---------------------------------------------------
    cle_privee: str = ""
    kid: str = "2026-09"
    duree_acces_s: int = 900            # 15 min
    duree_refresh_j: int = 30

    # --- corsian-jeu ----------------------------------------------------
    jwks_local: str = ""
    mode_sans_auth: bool = False        # échappatoire de développement ONLY
    fenetre_tape_ms: int = 900
    plancher_tape_ms: int = 120         # plancher physiologique
    refus_tape_ms: int = 100            # en dessous : rejet + suspicion
    delai_tour_ms: int = 12000
    grace_deconnexion_s: int = 30
    compte_a_rebours_s: int = 3
    max_tables: int = 200
    duree_table_s: int = 7200           # 2 h avant expiration d'une table en attente
    max_messages_par_s: int = 10
    silence_max_s: int = 75
    bonjour_max_s: int = 5

    @property
    def url_jwks(self) -> str:
        """JWKS lu en **local** : la clé publique ne sort jamais du serveur."""
        return self.jwks_local or (
            "http://127.0.0.1:8111/api/auth/.well-known/jwks.json"
        )


def _commune(service: str, port_defaut: int) -> dict:
    return {
        "service": service,
        "environnement": _texte("ENVIRONNEMENT", "dev"),
        "hote": _texte("HOST", "127.0.0.1"),
        "port": _entier("PORT", port_defaut),
        "version": _texte("VERSION", "0.1.0"),
        "base_chemin": chemin_base(),
        "prefixe_public": _texte("PREFIXE_PUBLIC", "/corsian-battle"),
        "origine_publique": _texte("ORIGINE_PUBLIQUE", "https://soft.opik.net"),
    }


def config_auth() -> Config:
    return Config(
        **_commune("corsian-auth", 8111),
        cle_privee=os.path.expanduser(
            _texte("CLE_PRIVEE", "~/corsian-battle/var/cles/auth-rs256.pem")
        ),
        kid=_texte("KID", "2026-09"),
        duree_acces_s=_entier("DUREE_ACCES_S", 900),
        duree_refresh_j=_entier("DUREE_REFRESH_J", 30),
    )


def config_jeu() -> Config:
    return Config(
        **_commune("corsian-jeu", 8112),
        jwks_local=_texte("JWKS_LOCAL", ""),
        mode_sans_auth=_booleen("MODE_SANS_AUTH", False),
        fenetre_tape_ms=_entier("FENETRE_TAPE_MS", 900),
        plancher_tape_ms=_entier("PLANCHER_TAPE_MS", 120),
        refus_tape_ms=_entier("REFUS_TAPE_MS", 100),
        delai_tour_ms=_entier("DELAI_TOUR_MS", 12000),
        grace_deconnexion_s=_entier("GRACE_DECONNEXION_S", 30),
        compte_a_rebours_s=_entier("COMPTE_A_REBOURS_S", 3),
        max_tables=_entier("MAX_TABLES", 200),
    )


def verifier_production(cfg: Config) -> None:
    """Refuse de démarrer en production avec une configuration de développement.

    Appelé au démarrage des deux services : mieux vaut un refus net qu'un
    serveur public qui accepte n'importe quel jeton.
    """
    if cfg.environnement != "prod":
        return
    problemes = []
    if cfg.mode_sans_auth:
        problemes.append("MODE_SANS_AUTH est actif")
    if cfg.service == "corsian-auth" and not cfg.cle_privee:
        problemes.append("CLE_PRIVEE est absente")
    if cfg.hote not in ("127.0.0.1", "::1", "localhost"):
        problemes.append(f"HOST={cfg.hote} n'est pas une adresse de boucle locale")
    if problemes:
        raise RuntimeError(
            "Démarrage refusé en production : " + " ; ".join(problemes)
        )
