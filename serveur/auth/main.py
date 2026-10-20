"""corsian-auth — comptes invités, jetons, suppression. `127.0.0.1:8111`.

Périmètre de cette livraison (S0 + cœur de S1) :

    GET    /api/auth/sante
    GET    /api/auth/.well-known/jwks.json    lu en local par corsian-jeu, non proxyé
    POST   /api/auth/invite                   compte invité, idempotent par appareil
    POST   /api/auth/rafraichir               rotation du jeton de refresh
    POST   /api/auth/deconnexion              révocation de la session courante
    GET    /api/auth/profil                   (Bearer)
    DELETE /api/auth/compte                   (Bearer) — RGPD + exigence Play

Reste à venir (S1 complet) : connexion email/mot de passe (argon2id),
rattachement d'email, changement de pseudo, et le code de suppression à
9 caractères pour la voie web sans identifiants (`docs/ENDPOINTS.md` §3.9).

Les routes sont déclarées en `def` (synchrone) à dessein : FastAPI les exécute
dans son pool de threads, donc les accès SQLite ne bloquent jamais la boucle
événementielle.
"""
from __future__ import annotations

import logging
import sqlite3
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional

from fastapi import Depends, FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from serveur.commun import bd
from serveur.commun import jwt as jetons
from serveur.commun import pseudo as filtre
from serveur.commun.config import VERSION_PROTO, Config, config_auth, verifier_production
from serveur.commun.limites import Limiteur

journal = logging.getLogger("corsian.auth")

cfg: Config = config_auth()
_etat: Dict[str, Any] = {}
porteur = HTTPBearer(auto_error=False)

# Limites de `docs/ENDPOINTS.md` §5.
_limiteurs: Dict[str, Limiteur] = {
    "invite": Limiteur(5, 3600),          # 5 créations / h / IP
    "rafraichir": Limiteur(60, 3600),     # 60 / h / IP
    "lecture": Limiteur(120, 60),         # 120 / min / IP
}


class ErreurApi(Exception):
    """Erreur métier au format imposé : `{"erreur": {"code", "message"}}`."""

    def __init__(
        self,
        code: str,
        message: str,
        statut: int = 400,
        entetes: Optional[Dict[str, str]] = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.statut = statut
        self.entetes = entetes or {}


# ---------------------------------------------------------------------------
# Cycle de vie
# ---------------------------------------------------------------------------
@asynccontextmanager
async def cycle_de_vie(app: FastAPI):
    verifier_production(cfg)
    pem = jetons.charger_ou_generer_cle(cfg.cle_privee, cfg.environnement)
    _etat["cle_privee"] = pem
    _etat["cle_publique"] = jetons.cle_publique(pem)
    _etat["jwks"] = jetons.jwks(pem, cfg.kid)
    versions = bd.initialiser(cfg.base_chemin)
    with bd.connexion(cfg.base_chemin) as conn:
        purges = bd.purger_sessions_expirees(conn)
    journal.info(
        "%s démarré · environnement=%s · base=%s · migrations=%s · sessions purgées=%d",
        cfg.service, cfg.environnement, cfg.base_chemin, versions or "à jour", purges,
    )
    yield
    _etat.clear()


app = FastAPI(
    title="Corsian-Battle — authentification",
    version=cfg.version,
    lifespan=cycle_de_vie,
    docs_url=None,      # pas de Swagger public
    redoc_url=None,
    openapi_url=None,
)


@app.middleware("http")
async def entetes_communs(request: Request, call_next):
    reponse = await call_next(request)
    reponse.headers["X-Api-Version"] = str(VERSION_PROTO)
    return reponse


@app.exception_handler(ErreurApi)
async def _gerer_erreur_api(request: Request, exc: ErreurApi) -> JSONResponse:
    return JSONResponse(
        status_code=exc.statut,
        content={"erreur": {"code": exc.code, "message": exc.message}},
        headers=exc.entetes,
    )


@app.exception_handler(RequestValidationError)
async def _gerer_validation(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={
            "erreur": {
                "code": "requete_invalide",
                "message": "La requête est incomplète ou malformée.",
            }
        },
    )


@app.exception_handler(Exception)
async def _gerer_imprevu(request: Request, exc: Exception) -> JSONResponse:
    journal.exception("Erreur non gérée sur %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=500,
        content={
            "erreur": {
                "code": "erreur_interne",
                "message": "Le service n'a pas pu traiter la demande.",
            }
        },
    )


# ---------------------------------------------------------------------------
# Aides
# ---------------------------------------------------------------------------
def _ip(request: Request) -> str:
    """IP réelle du client : nginx la transmet, sinon adresse du socket."""
    reelle = request.headers.get("x-real-ip")
    if reelle:
        return reelle.strip()
    transferee = request.headers.get("x-forwarded-for")
    if transferee:
        return transferee.split(",")[0].strip()
    return request.client.host if request.client else "inconnue"


def _limiter(request: Request, nom: str) -> None:
    ok, retry = _limiteurs[nom].autorise(_ip(request))
    if not ok:
        raise ErreurApi(
            "trop_de_demandes",
            "Trop de demandes, réessaie dans un moment.",
            429,
            {"Retry-After": str(retry)},
        )


def _authentifie(
    credits: Optional[HTTPAuthorizationCredentials],
) -> Dict[str, Any]:
    if credits is None or not credits.credentials:
        raise ErreurApi("non_autorise", "Authentification requise.", 401)
    try:
        return jetons.verifier_acces(credits.credentials, _etat["cle_publique"])
    except jetons.ErreurJeton as erreur:
        raise ErreurApi(erreur.code, erreur.message, 401) from erreur


def _session_valide(
    conn: sqlite3.Connection, empreinte_refresh: str, ip: str
) -> Dict[str, Any]:
    """Contrôle d'un jeton de refresh, rotation comprise.

    Un jeton **déjà révoqué** et rejoué déclenche la révocation en chaîne de
    toutes les sessions de l'appareil : c'est la détection de vol décrite dans
    `docs/ENDPOINTS.md` §3.4.
    """
    session = bd.session_par_empreinte(conn, empreinte_refresh)
    if session is None:
        raise ErreurApi("refresh_invalide", "Session expirée, rouvre l'app.", 401)
    if session.get("revoque_le"):
        if session.get("appareil_id"):
            bd.revoquer_sessions_appareil(conn, session["appareil_id"])
        raise ErreurApi("refresh_revoque", "Session révoquée, rouvre l'app.", 401)
    if session["expire_le"] < bd.maintenant_iso():
        raise ErreurApi("refresh_expire", "Session expirée, rouvre l'app.", 401)
    joueur = bd.joueur_par_id(conn, session["joueur_id"])
    if joueur is None:
        raise ErreurApi("compte_inconnu", "Compte introuvable.", 401)
    if joueur.get("statut") != "actif":
        raise ErreurApi("compte_suspendu", "Ce compte ne peut pas se connecter.", 403)
    return {"session": session, "joueur": joueur}


def _paire_jetons(
    conn: sqlite3.Connection,
    joueur: Dict[str, Any],
    appareil_id: Optional[str],
    ip: str,
) -> Dict[str, Any]:
    """Crée une session de refresh et émet les deux jetons.

    La connexion est **passée explicitement** : les routes s'exécutent dans le
    pool de threads de FastAPI, donc toute variable de module servant à
    transporter un état par requête serait une course garantie entre deux
    appels simultanés.
    """
    jeton_refresh, empreinte_refresh = jetons.emettre_refresh()
    bd.creer_session_refresh(
        conn=conn,
        session_id=uuid.uuid4().hex,
        joueur_id=joueur["id"],
        empreinte=empreinte_refresh,
        expire_le=bd.maintenant_iso(cfg.duree_refresh_j * 86400),
        appareil_id=appareil_id,
        ip_creation=ip,
    )
    acces = jetons.emettre_acces(
        _etat["cle_privee"], cfg.kid, joueur["id"], joueur["pseudo"], cfg.duree_acces_s
    )
    return {
        "jeton_acces": acces,
        "expire_dans": cfg.duree_acces_s,
        "jeton_refresh": jeton_refresh,
        "refresh_expire_dans": cfg.duree_refresh_j * 86400,
    }


# ---------------------------------------------------------------------------
# Modèles de requête
# ---------------------------------------------------------------------------
class InviteRequete(BaseModel):
    uuid_appareil: str = Field(min_length=8, max_length=64)
    pseudo: str = Field(min_length=1, max_length=40)
    plateforme: str = Field(default="android", pattern="^(android|ios|web|test)$")
    version_app: Optional[str] = Field(default=None, max_length=32)
    langue: str = Field(default="fr", max_length=8)


class JetonRequete(BaseModel):
    jeton_refresh: str = Field(min_length=10, max_length=200)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/api/auth/sante")
def sante() -> JSONResponse:
    """Santé du service. Ne dépend d'aucun autre service : `corsian-jeu` peut
    être arrêté, cette route répond toujours (`docs/ARCHITECTURE.md` §9)."""
    etat_base = "ok"
    try:
        with bd.connexion(cfg.base_chemin) as conn:
            conn.execute("SELECT 1").fetchone()
    except Exception:
        journal.exception("Base illisible")
        etat_base = "erreur"
    disque = bd.pourcentage_disque(cfg.base_chemin)
    if etat_base != "ok":
        etat = "erreur"
    elif disque >= 90:
        etat = "degrade"
    else:
        etat = "ok"
    return JSONResponse(
        {
            "etat": etat,
            "service": cfg.service,
            "version": cfg.version,
            "base": etat_base,
            "cle_signature": "ok" if _etat.get("cle_privee") else "absente",
            "disque_pourcent": disque,
            "disque_libre_mo": bd.espace_libre_mo(cfg.base_chemin),
            "heure_utc": bd.maintenant_iso(),
        }
    )


@app.get("/api/auth/.well-known/jwks.json")
def cle_publique_json() -> JSONResponse:
    """Lu par `corsian-jeu` en `127.0.0.1`. Non exposé par nginx."""
    return JSONResponse(
        _etat.get("jwks", {"keys": []}),
        headers={"Cache-Control": "public, max-age=600"},
    )


@app.post("/api/auth/invite")
def invite(corps: InviteRequete, request: Request) -> JSONResponse:
    """Crée — ou retrouve — le compte rattaché à un appareil.

    **Idempotent** : un `uuid_appareil` déjà connu ramène le compte existant,
    ce qui rend la reconnexion transparente après redémarrage de l'app. Le
    pseudo fourni n'est alors pas appliqué (le joueur le change via son profil).
    """
    _limiter(request, "invite")
    pseudo_propre, code = filtre.valider(corps.pseudo)
    if code is not None or pseudo_propre is None:
        raise ErreurApi(code or "pseudo_interdit", filtre.message_erreur(code), 422)

    with bd.connexion(cfg.base_chemin) as conn:
        _etat["conn"] = conn
        try:
            existant = bd.joueur_par_appareil(conn, corps.uuid_appareil)
            if existant is not None:
                if existant.get("statut") != "actif":
                    raise ErreurApi("compte_suspendu", "Ce compte ne peut pas se connecter.", 403)
                joueur = existant
                nouveau = False
            else:
                if bd.pseudo_min_pris(conn, filtre.pseudo_min(pseudo_propre)):
                    raise ErreurApi("pseudo_indisponible", "Ce pseudo est déjà pris.", 409)
                joueur_id = uuid.uuid4().hex
                appareil_id = uuid.uuid4().hex
                try:
                    bd.creer_joueur(
                        conn, joueur_id, pseudo_propre,
                        filtre.pseudo_min(pseudo_propre), corps.langue,
                    )
                    bd.creer_appareil(
                        conn, appareil_id, joueur_id, corps.uuid_appareil,
                        corps.plateforme, corps.version_app,
                    )
                except sqlite3.IntegrityError:
                    # Course entre deux demandes : le pseudo a été pris entre-temps.
                    raise ErreurApi("pseudo_indisponible", "Ce pseudo est déjà pris.", 409)
                joueur = bd.joueur_par_id(conn, joueur_id) or {
                    "id": joueur_id,
                    "pseudo": pseudo_propre,
                    "email": None,
                    "cree_le": bd.maintenant_iso(),
                    "langue": corps.langue,
                    "statut": "actif",
                }
                joueur["appareil_id"] = appareil_id
                nouveau = True
            bd.touch_joueur(conn, joueur["id"])
            if joueur.get("appareil_id"):
                bd.touch_appareil(conn, joueur["appareil_id"], corps.version_app)
            jetons_emis = _paire_jetons(joueur, joueur.get("appareil_id"), _ip(request))
        finally:
            _etat.pop("conn", None)

    return JSONResponse(
        {
            "joueur": {
                "id": joueur["id"],
                "pseudo": joueur["pseudo"],
                "email": joueur.get("email"),
                "cree_le": joueur.get("cree_le"),
                "langue": joueur.get("langue", "fr"),
            },
            "nouveau_compte": nouveau,
            **jetons_emis,
        }
    )


@app.post("/api/auth/rafraichir")
def rafraichir(corps: JetonRequete, request: Request) -> JSONResponse:
    _limiter(request, "rafraichir")
    with bd.connexion(cfg.base_chemin) as conn:
        _etat["conn"] = conn
        try:
            trouve = _session_valide(conn, jetons.empreinte(corps.jeton_refresh), _ip(request))
            bd.revoquer_session(conn, trouve["session"]["id"])   # rotation
            joueur = trouve["joueur"]
            bd.touch_joueur(conn, joueur["id"])
            emis = _paire_jetons(joueur, trouve["session"].get("appareil_id"), _ip(request))
        finally:
            _etat["conn"] = None
    return JSONResponse(
        {
            "joueur": {"id": joueur["id"], "pseudo": joueur["pseudo"]},
            **emis,
        }
    )


@app.post("/api/auth/deconnexion")
def deconnexion(corps: JetonRequete) -> Response:
    with bd.connexion(cfg.base_chemin) as conn:
        session = bd.session_par_empreinte(conn, jetons.empreinte(corps.jeton_refresh))
        if session is not None and not session.get("revoque_le"):
            bd.revoquer_session(conn, session["id"])
    return Response(status_code=204)


@app.get("/api/auth/profil")
def profil(
    request: Request,
    credits: Optional[HTTPAuthorizationCredentials] = Depends(porteur),
) -> JSONResponse:
    _limiter(request, "lecture")
    contenu = _authentifie(credits)
    with bd.connexion(cfg.base_chemin) as conn:
        joueur = bd.joueur_par_id(conn, contenu["sub"])
        if joueur is None:
            raise ErreurApi("compte_inconnu", "Compte introuvable.", 404)
        appareils = bd.appareils_du_joueur(conn, joueur["id"])
        stats = bd.stats_joueur(conn, joueur["id"])
    return JSONResponse(
        {
            "joueur": {
                "id": joueur["id"],
                "pseudo": joueur["pseudo"],
                "email": joueur.get("email"),
                "cree_le": joueur.get("cree_le"),
                "dernier_vu_le": joueur.get("dernier_vu_le"),
                "langue": joueur.get("langue", "fr"),
            },
            "appareils": appareils,
            "stats": stats,
        }
    )


@app.delete("/api/auth/compte")
def supprimer_compte(
    credits: Optional[HTTPAuthorizationCredentials] = Depends(porteur),
) -> Response:
    """Suppression immédiate et irréversible (`docs/SCHEMA_BD.md` §6).

    Exigence Google Play : la suppression doit être possible dans l'app **et**
    depuis une page web — la voie web arrive avec le code à 9 caractères.
    """
    contenu = _authentifie(credits)
    with bd.connexion(cfg.base_chemin) as conn:
        supprime = bd.supprimer_joueur(conn, contenu["sub"])
    journal.info("Compte supprimé à la demande : %s", contenu["sub"] if supprime else "(inconnu)")
    return Response(status_code=204)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "serveur.auth.main:app",
        host=cfg.hote,
        port=cfg.port,
        workers=1,                 # obligatoire : état en mémoire
        proxy_headers=True,
        forwarded_allow_ips="127.0.0.1",
    )
