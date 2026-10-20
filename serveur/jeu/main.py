"""corsian-jeu — tables, WebSocket, arbitrage. `127.0.0.1:8112`.

Périmètre de cette livraison (S0 + socle de S2) :

    GET    /api/jeu/sante
    GET    /api/jeu/config                     réglages lus par l'app, jamais codés en dur
    POST   /api/jeu/tables                     création, idempotente par joueur
    GET    /api/jeu/tables/{code}
    POST   /api/jeu/tables/{code}/rejoindre    réserve un siège
    DELETE /api/jeu/tables/{code}              le créateur, en `attente` seulement
    WS     /ws                                 `bonjour` → `bienvenue` → `table_etat`

La **boucle de coups** (branchement sur `bataille_corse`, fenêtre de doublon,
remplacement par un bot) arrive à l'étape S2 : `poser_carte` et `tape` sont
reconnus mais répondent `pas_encore_en_partie`. Le contrat des messages est
déjà celui de `docs/PROTOCOLE.md`, donc le client n'aura pas à changer.

`--workers 1` est obligatoire : les tables vivent dans ce processus.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from serveur.commun import bd
from serveur.commun import jwt as jetons
from serveur.commun.config import VERSION_PROTO, Config, config_jeu, verifier_production
from serveur.commun.limites import Limiteur
from serveur.jeu.partie import PartieEnLigne
from serveur.jeu.table import TAILLES, ErreurTable, GestionnaireTables, Siege, Table

journal = logging.getLogger("corsian.jeu")

cfg: Config = config_jeu()
_etat: Dict[str, Any] = {}
porteur = HTTPBearer(auto_error=False)
tables = GestionnaireTables(max_tables=cfg.max_tables, origine=cfg.origine_publique, prefixe=cfg.prefixe_public)

# ~10 msg/s avec une rafale de 20 (`docs/PROTOCOLE.md` §13).
_limiteur_ws = Limiteur(cfg.max_messages_par_s * 2, 2.0)
_limiteur_rest = Limiteur(60, 60)

TAILLE_MESSAGE_MAX = 8192


class ErreurApi(Exception):
    def __init__(self, code: str, message: str, statut: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.statut = statut


# ---------------------------------------------------------------------------
# Cycle de vie
# ---------------------------------------------------------------------------
async def _entretien_periodique() -> None:
    """Purge les tables expirées et les réservations périmées, toutes les 60 s."""
    while True:
        await asyncio.sleep(60)
        try:
            abandonnees = await _cloturer_tables_abandonnees()
            fermees = tables.nettoyer()
            _limiteur_ws.nettoyer()
            _limiteur_rest.nettoyer()
            if fermees or abandonnees:
                journal.info(
                    "Entretien : %d table(s) fermée(s), %d partie(s) close(s), %d active(s)",
                    fermees, abandonnees, tables.actives(),
                )
        except Exception:
            journal.exception("Entretien périodique en échec")


@asynccontextmanager
async def cycle_de_vie(app: FastAPI):
    verifier_production(cfg)
    bd.initialiser(cfg.base_chemin)          # idempotent : le jeu démarre seul
    _etat["verificateur"] = jetons.VerificateurJwks(cfg.url_jwks)
    tache = asyncio.create_task(_entretien_periodique())
    journal.info(
        "%s démarré · environnement=%s · ws=%s · jwks=%s · mode_sans_auth=%s",
        cfg.service, cfg.environnement, "/ws", cfg.url_jwks, cfg.mode_sans_auth,
    )
    yield
    tache.cancel()
    _etat.clear()


app = FastAPI(
    title="Corsian-Battle — jeu",
    version=cfg.version,
    lifespan=cycle_de_vie,
    docs_url=None,
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
        status_code=exc.statut, content={"erreur": {"code": exc.code, "message": exc.message}}
    )


@app.exception_handler(ErreurTable)
async def _gerer_erreur_table(request: Request, exc: ErreurTable) -> JSONResponse:
    return JSONResponse(
        status_code=exc.statut, content={"erreur": {"code": exc.code, "message": exc.message}}
    )


@app.exception_handler(RequestValidationError)
async def _gerer_validation(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={"erreur": {"code": "requete_invalide", "message": "La requête est incomplète ou malformée."}},
    )


@app.exception_handler(Exception)
async def _gerer_imprevu(request: Request, exc: Exception) -> JSONResponse:
    journal.exception("Erreur non gérée sur %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=500,
        content={"erreur": {"code": "erreur_interne", "message": "Le service n'a pas pu traiter la demande."}},
    )


# ---------------------------------------------------------------------------
# Aides
# ---------------------------------------------------------------------------
def _ip(request: Request) -> str:
    reelle = request.headers.get("x-real-ip")
    if reelle:
        return reelle.strip()
    transferee = request.headers.get("x-forwarded-for")
    if transferee:
        return transferee.split(",")[0].strip()
    return request.client.host if request.client else "inconnue"


def _memoire_rss_mo() -> int:
    """RSS du processus, pour `/sante`. -1 si indisponible (non-Linux)."""
    try:
        with open("/proc/self/status", "r", encoding="ascii") as fichier:
            for ligne in fichier:
                if ligne.startswith("VmRSS:"):
                    return int(ligne.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return -1


def _authentifie(
    credits: Optional[HTTPAuthorizationCredentials] = None,
    jeton_brut: Optional[str] = None,
    pseudo_secours: str = "Joueur",
) -> Dict[str, Any]:
    """Vérifie le JWT (JWKS local) ou, en `MODE_SANS_AUTH`, accepte un jeton factice.

    `MODE_SANS_AUTH` est une échappatoire de **développement** : refusée au
    démarrage si `ENVIRONNEMENT=prod` (`config.verifier_production`).
    """
    if cfg.mode_sans_auth:
        identite = jeton_brut if jeton_brut is not None else (
            credits.credentials if credits is not None else ""
        )
        return {"sub": f"dev-{identite or 'local'}", "pseudo": pseudo_secours, "typ": "acces"}
    if credits is None or not credits.credentials:
        if not jeton_brut:
            raise ErreurApi("non_autorise", "Authentification requise.", 401)
    brut = jeton_brut if jeton_brut else (credits.credentials if credits else "")
    try:
        return _etat["verificateur"].verifier(brut)
    except jetons.ErreurJeton as erreur:
        raise ErreurApi(erreur.code, erreur.message, 401) from erreur
    except KeyError:
        raise ErreurApi("service_indisponible", "Le service n'est pas prêt.", 503)


def _message_erreur(code: str, message: str) -> Dict[str, Any]:
    return {"type": "erreur", "seq": 0, "d": {"code": code, "message": message}}


def _json(brut: str) -> Optional[Dict[str, Any]]:
    if not brut or len(brut) > TAILLE_MESSAGE_MAX:
        return None
    try:
        message = json.loads(brut)
    except ValueError:
        return None
    return message if isinstance(message, dict) else None


async def _envoyer(websocket: WebSocket, message: Dict[str, Any]) -> bool:
    """Envoie sans lever : un socket mort ne doit pas casser la diffusion."""
    try:
        await websocket.send_text(json.dumps(message, ensure_ascii=False))
        return True
    except Exception:
        return False


async def _diffuser(
    table: Table,
    message: Dict[str, Any],
    vers: Optional[List[int]] = None,
    sauf: Optional[int] = None,
) -> None:
    """Diffuse aux sièges connectés.

    `vers=None` → tout le monde ; `vers=[2]` → uniquement le siège 2 (messages
    privés comme `ta_carte_suivante`) ; `sauf=n` → tout le monde sauf n.
    C'est ici, et nulle part ailleurs, qu'un message privé est borné à son
    destinataire : `PartieEnLigne` ne connaît pas les sockets.
    La signature correspond à `serveur.jeu.partie.Diffuseur`.
    """
    for siege in table.sieges:
        if siege.websocket is None:
            continue
        if vers is not None and siege.numero not in vers:
            continue
        if sauf is not None and siege.numero == sauf:
            continue
        await _envoyer(siege.websocket, message)


async def _instantane_par_siege(table: Table, seq: int) -> None:
    """`table_etat` **filtré** : chaque siège reçoit sa propre copie.

    Les champs de partie (pli, reste neutre, tour, défi) viennent de la partie
    en cours s'il y en a une ; sinon l'instantané reste celui d'une table en
    attente. Le client n'a donc qu'un seul contrat, avant et après le
    lancement (`docs/PROTOCOLE.md` §6).
    """
    complement = table.partie.etat_public() if table.partie is not None else {}
    for siege in table.sieges:
        if siege.websocket is None:
            continue
        donnees = table.instantane(siege.numero)
        donnees.update(complement)
        await _envoyer(
            siege.websocket, {"type": "table_etat", "seq": seq, "d": donnees}
        )


async def _fermer(websocket: WebSocket, code: int) -> None:
    try:
        await websocket.close(code=code)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Modèles
# ---------------------------------------------------------------------------
class TableRequete(BaseModel):
    type: str = Field(default="duel", pattern="^(duel|table_quatre)$")


# ---------------------------------------------------------------------------
# REST
# ---------------------------------------------------------------------------
@app.get("/api/jeu/sante")
def sante() -> JSONResponse:
    etat_base = "ok"
    try:
        with bd.connexion(cfg.base_chemin) as conn:
            conn.execute("SELECT 1").fetchone()
    except Exception:
        journal.exception("Base illisible")
        etat_base = "erreur"
    disque = bd.pourcentage_disque(cfg.base_chemin)
    actives = tables.actives()
    if etat_base != "ok":
        etat = "erreur"
    elif disque >= 90:
        etat = "degrade"
    elif actives >= int(cfg.max_tables * 0.9):
        etat = "degrade"
    else:
        etat = "ok"
    return JSONResponse(
        {
            "etat": etat,
            "service": cfg.service,
            "version": cfg.version,
            "version_proto": VERSION_PROTO,
            "tables_actives": actives,
            "sockets_ouverts": tables.sockets_ouverts(),
            "base": etat_base,
            "memoire_mo": _memoire_rss_mo(),
            "disque_pourcent": disque,
            "auth_joignable": _etat.get("verificateur") is not None,
            "mode_sans_auth": cfg.mode_sans_auth,
            "heure_utc": bd.maintenant_iso(),
        }
    )


@app.get("/api/jeu/config")
def configuration() -> JSONResponse:
    """Réglages servis à l'app : rien n'est codé en dur côté client
    (`docs/ENDPOINTS.md` §4.2)."""
    return JSONResponse(
        {
            "version_proto": VERSION_PROTO,
            "fenetre_tape_ms": cfg.fenetre_tape_ms,
            "plancher_tape_ms": cfg.plancher_tape_ms,
            "delai_tour_ms": cfg.delai_tour_ms,
            "grace_deconnexion_s": cfg.grace_deconnexion_s,
            "compte_a_rebours_s": cfg.compte_a_rebours_s,
            "tailles_table": sorted(TAILLES.values()),
            "ws": f"{cfg.prefixe_public}/ws",
            "prefixe_api": f"{cfg.prefixe_public}/api/jeu",
            "mode_sans_auth": cfg.mode_sans_auth,
        }
    )


@app.post("/api/jeu/tables", status_code=201)
def creer_table(
    request: Request,
    corps: TableRequete,
    credits: Optional[HTTPAuthorizationCredentials] = Depends(porteur),
) -> JSONResponse:
    ok, retry = _limiteur_rest.autorise(f"tables:{_ip(request)}")
    if not ok:
        raise ErreurApi("trop_de_demandes", "Trop de tables créées, patiente un moment.", 429)
    contenu = _authentifie(credits=credits)
    joueur_id, pseudo = contenu["sub"], contenu.get("pseudo", "Joueur")

    # Une seule table active par joueur : on rend la sienne s'il en a déjà une.
    for code in tables.codes():
        existante = tables.obtenir(code)
        if existante.createur_id == joueur_id and existante.etat == "attente":
            table, siege = existante, existante.sieges[0]
            return JSONResponse(_reponse_table(table, siege), status_code=200)

    table, siege = tables.creer(corps.type, joueur_id, pseudo)
    journal.info("Table %s créée (%s) par %s", table.code, table.type_partie, pseudo)
    return JSONResponse(_reponse_table(table, siege), status_code=201)


def _reponse_table(table: Table, siege: Siege) -> Dict[str, Any]:
    return {
        "code": table.code,
        "type": table.type_partie,
        "siege": siege.numero,
        "etat": table.etat,
        "url_partage": table.url_partage,
        "ws": f"{cfg.prefixe_public}/ws",
        "expire_le": bd.maintenant_iso(table.cree_le + 7200 - time.time()),
    }


@app.get("/api/jeu/tables/{code}")
def voir_table(
    code: str, credits: Optional[HTTPAuthorizationCredentials] = Depends(porteur)
) -> JSONResponse:
    _authentifie(credits=credits)
    table = tables.obtenir(code)
    return JSONResponse(table.description_publique())


@app.post("/api/jeu/tables/{code}/rejoindre")
def rejoindre_table(
    code: str, credits: Optional[HTTPAuthorizationCredentials] = Depends(porteur)
) -> JSONResponse:
    contenu = _authentifie(credits=credits)
    table, siege = tables.rejoindre(code, contenu["sub"], contenu.get("pseudo", "Joueur"))
    return JSONResponse(
        {"code": table.code, "siege": siege.numero, "ws": f"{cfg.prefixe_public}/ws"}
    )


@app.delete("/api/jeu/tables/{code}")
def fermer_table(
    code: str, credits: Optional[HTTPAuthorizationCredentials] = Depends(porteur)
) -> Response:
    contenu = _authentifie(credits=credits)
    table = tables.obtenir(code)
    if table.createur_id != contenu["sub"]:
        raise ErreurApi("interdit", "Seul le créateur peut fermer la table.", 403)
    if table.etat != "attente":
        raise ErreurApi("partie_en_cours", "La partie est lancée : impossible de la dissoudre.", 409)
    tables.fermer(table.code)
    return Response(status_code=204)


# ---------------------------------------------------------------------------
# Lancement, fin et persistance des parties
# ---------------------------------------------------------------------------
async def _lancer_partie(table: Table) -> None:
    """Compte à rebours puis lancement, une fois tous les humains prêts."""
    table.etat = "compte_a_rebours"
    await _diffuser(
        table,
        {"type": "compte_a_rebours", "seq": table.prochain_seq(),
         "d": {"secondes": cfg.compte_a_rebours_s}},
    )
    await asyncio.sleep(cfg.compte_a_rebours_s)
    if table.partie is not None:
        return                                    # lancée entre-temps
    if not table.tous_prets():
        table.etat = "attente"                    # un joueur est parti : on attend
        await _diffuser(
            table,
            {"type": "compte_a_rebours", "seq": table.prochain_seq(),
             "d": {"secondes": 0, "annule": True}},
        )
        return
    async def sur_suspicion(suspects: List[Dict[str, Any]]) -> None:
        await _consigner_suspicions(table, suspects)

    partie = PartieEnLigne(
        table, _diffuser, cfg, sur_fin=_persister_partie, sur_suspicion=sur_suspicion
    )
    table.partie = partie
    await partie.lancer()


async def _persister_partie(partie: PartieEnLigne, raison: str, gagnant_siege) -> None:
    """Écrit la partie terminée en base — E/S bloquante, donc dans un thread."""
    await asyncio.to_thread(_ecrire_partie, partie, raison, gagnant_siege)


def _ecrire_partie(partie: PartieEnLigne, raison: str, gagnant_siege) -> None:
    partie_id = uuid.uuid4().hex
    table = partie.table
    gagnant_id = None
    if gagnant_siege is not None:
        siege_gagnant = table.siege(gagnant_siege)
        gagnant_id = siege_gagnant.joueur_id if siege_gagnant is not None else None
    with bd.connexion(cfg.base_chemin) as conn:
        bd.creer_partie(
            conn,
            partie_id=partie_id,
            code_table=table.code,
            type_partie=table.type_partie,
            # `maintenant_iso(decalage)` : un décalage négatif ramène à l'instant
            # de lancement, sans avoir à formater une date soi-même.
            cree_le=bd.maintenant_iso(partie.lance_le - time.time()),
            seed=partie.seed,
            terminee_le=bd.maintenant_iso(),
            gagnant_id=gagnant_id,
            raison_fin=raison,
            nb_coups=partie.coups,
            nb_doublons=partie.doublons_ouverts,
            duree_ms=int((time.time() - partie.lance_le) * 1000),
        )
        for ligne in partie.statistiques():
            siege = table.siege(ligne["siege"])
            if siege is None:
                continue
            bd.creer_participation(
                conn,
                partie_id=partie_id,
                siege=ligne["siege"],
                joueur_id=siege.joueur_id,
                pseudo_affiche=siege.pseudo,
                est_bot=siege.est_bot,
                nb_cartes_final=ligne["nb_cartes"],
                doublons_gagnes=ligne["doublons_gagnes"],
                doublons_perdus=ligne["doublons_perdus"],
                tapes_manquees=ligne["tapes_manquees"],
                delai_tape_median_ms=ligne["delai_tape_median_ms"],
            )
    journal.info("Partie %s enregistrée (%s, %d coups)", partie_id, raison, partie.coups)


# Valeurs acceptées par la contrainte CHECK de `suspicions.type`
# (`serveur/migrations/001_initial.sql`). Tout motif hors liste est ramené à
# `delai_impossible` : une écriture en base ne doit jamais échouer à cause
# d'un vocabulaire interne. À élargir par une migration 002 si besoin.
_TYPES_SUSPICION = ("delai_impossible", "delai_sous_plancher", "rafale_messages", "coup_perime")


async def _consigner_suspicions(table: Table, suspects: List[Dict[str, Any]]) -> None:
    await asyncio.to_thread(_ecrire_suspicions, table, suspects)


def _ecrire_suspicions(table: Table, suspects: List[Dict[str, Any]]) -> None:
    with bd.connexion(cfg.base_chemin) as conn:
        for suspect in suspects:
            siege = table.siege(suspect.get("siege"))
            joueur_id = siege.joueur_id if siege is not None else None
            if not joueur_id:
                continue                     # bot ou siège libéré : rien à consigner
            motif = suspect.get("type")
            bd.enregistrer_suspicion(
                conn,
                suspicion_id=uuid.uuid4().hex,
                joueur_id=joueur_id,
                type_suspicion=motif if motif in _TYPES_SUSPICION else "delai_impossible",
                valeur_ms=suspect.get("valeur_ms"),
            )
    journal.warning(
        "Table %s : %d suspicion(s) de tape consignée(s)", table.code, len(suspects)
    )


async def _cloturer_tables_abandonnees() -> int:
    """Clos une partie que plus personne ne regarde.

    En `attente`, l'expiration relève de `GestionnaireTables.nettoyer()`. En
    `en_jeu`, il ne faut pas laisser une partie tourner indéfiniment à coups
    automatiques sans aucun joueur connecté : après le délai de grâce (30 s,
    celui laissé à la reconnexion), elle est close en `abandon`. Le lot C
    remplacera cette clôture par la prise de main des bots.
    """
    cloturees = 0
    for code in tables.codes():
        table = tables.obtenir(code)
        if table.etat != "en_jeu" or table.partie is None or table.a_des_sockets():
            continue
        deconnectes = [s.deconnecte_le or 0.0 for s in table.sieges]
        if not deconnectes:
            continue
        if time.time() - max(deconnectes) > cfg.grace_deconnexion_s:
            await table.partie.finir("abandon")
            cloturees += 1
    return cloturees


# ---------------------------------------------------------------------------
# WebSocket
# ---------------------------------------------------------------------------
@app.websocket("/ws")
async def websocket_jeu(websocket: WebSocket) -> None:
    await websocket.accept()

    brut = await _recevoir(websocket, cfg.bonjour_max_s)
    if brut is None:
        await _fermer(websocket, 4408)          # `bonjour` jamais arrivé
        return
    message = _json(brut)
    if message is None or message.get("type") != "bonjour":
        await _envoyer(websocket, _message_erreur("protocole", "Le premier message doit être `bonjour`."))
        await _fermer(websocket, 4410)
        return

    donnees = message.get("d")
    donnees = donnees if isinstance(donnees, dict) else {}
    if donnees.get("version_proto") not in (None, VERSION_PROTO):
        await _fermer(websocket, 4413)          # version de protocole inconnue
        return

    try:
        contenu = _authentifie(
            jeton_brut=donnees.get("jeton"), pseudo_secours=str(donnees.get("pseudo") or "Testeur")
        )
    except ErreurApi:
        await _fermer(websocket, 4401)
        return

    joueur_id = contenu["sub"]
    pseudo = str(contenu.get("pseudo") or "Joueur")[:20]
    code_table = str(donnees.get("table") or "").strip()
    if not code_table:
        await _envoyer(websocket, _message_erreur("table_manquante", "Indique le code de table."))
        await _fermer(websocket, 4410)
        return

    try:
        table, siege = tables.rejoindre(code_table, joueur_id, pseudo)
    except ErreurTable as erreur:
        await _envoyer(websocket, _message_erreur(erreur.code, erreur.message))
        await _fermer(websocket, erreur.fermeture_ws)
        return

    siege.websocket = websocket
    siege.present = True
    siege.connecte_le = time.time()
    siege.deconnecte_le = None

    await _envoyer(
        websocket,
        {
            "type": "bienvenue",
            "seq": 0,
            "d": {"table": table.code, "siege": siege.numero, "seq_courant": table.seq},
        },
    )
    await _instantane_par_siege(table, table.prochain_seq())
    await _diffuser(
        table,
        {"type": "joueur_rejoint", "seq": table.prochain_seq(),
         "d": {"siege": siege.numero, "pseudo": siege.pseudo, "est_bot": siege.est_bot}},
        sauf=siege.numero,
    )
    journal.info("WS ouvert · table=%s siège=%d pseudo=%s", table.code, siege.numero, pseudo)

    try:
        while True:
            brut = await _recevoir(websocket, cfg.silence_max_s)
            if brut is None:
                await _fermer(websocket, 1000)   # silence : le client ne ping plus
                break
            ok, _retry = _limiteur_ws.autorise(f"{table.code}:{siege.numero}")
            if not ok:
                await _fermer(websocket, 4429)
                break
            message = _json(brut)
            if message is None:
                await _envoyer(websocket, _message_erreur("message_invalide", "JSON attendu."))
                await _fermer(websocket, 4410)
                break
            if not await _traiter(table, siege, message):
                break
    except WebSocketDisconnect:
        pass
    except Exception:
        journal.exception("Boucle WS interrompue (table=%s siège=%d)", table.code, siege.numero)
    finally:
        siege.websocket = None
        siege.present = False
        siege.pret = False
        siege.deconnecte_le = time.time()
        if table.etat == "attente":
            tables.quitter(table.code, joueur_id)
        # Les autres doivent voir le siège se vider, en attente comme en jeu.
        # En `en_jeu` le siège n'est PAS libéré : le joueur peut se reconnecter
        # et le récupérer, et le délai de tour fait avancer la partie en son
        # absence. Le lot C ajoutera le bot de remplacement après 30 s.
        await _diffuser(
            table,
            {"type": "joueur_parti", "seq": table.prochain_seq(),
             "d": {"siege": siege.numero, "remplace_par_bot": False}},
        )
        journal.info("WS fermé · table=%s siège=%d", table.code, siege.numero)


async def _recevoir(websocket: WebSocket, delai_s: float) -> Optional[str]:
    """`receive_text` borné dans le temps : `None` si silence ou socket mort."""
    try:
        return await asyncio.wait_for(websocket.receive_text(), timeout=delai_s)
    except asyncio.TimeoutError:
        return None
    except WebSocketDisconnect:
        raise
    except Exception:
        return None


async def _traiter(table: Table, siege: Siege, message: Dict[str, Any]) -> bool:
    """Traite un message client. Renvoie `False` pour fermer la boucle."""
    type_ = message.get("type")
    seq_attendu = message.get("seq_attendu")

    if type_ == "ping":
        await _envoyer(siege.websocket, {"type": "pong", "seq": 0, "d": {"seq_courant": table.seq}})
        return True

    if type_ == "resynchroniser":
        await _envoyer(
            siege.websocket,
            {"type": "table_etat", "seq": table.prochain_seq(), "d": table.instantane(siege.numero)},
        )
        return True

    if type_ == "pret":
        if table.etat != "attente":
            await _envoyer(siege.websocket, _message_erreur("etat_refuse", "La partie est déjà lancée."))
            return True
        siege.pret = True
        await _diffuser(
            table,
            {"type": "joueur_pret", "seq": table.prochain_seq(), "d": {"siege": siege.numero}},
        )
        if table.tous_prets() and table.partie is None:
            await _lancer_partie(table)
        return True

    if type_ == "quitter":
        return False

    if type_ == "poser_carte":
        if table.partie is None or table.etat != "en_jeu":
            await _envoyer(
                siege.websocket,
                _message_erreur("pas_encore_en_partie", "La table n'est pas encore en jeu."),
            )
            return True
        if seq_attendu is not None and seq_attendu != table.seq:
            # Action périmée (double appui, retard) : refusée plutôt que
            # rejouée — c'est le rôle de `seq_attendu` (`PROTOCOLE.md` §2).
            await _envoyer(
                siege.websocket,
                _message_erreur("coup_perime", "Coup refusé : la table a avancé."),
            )
            return True
        await table.partie.poser_carte(siege.numero)
        return True

    if type_ == "tape":
        if table.partie is None or not table.partie.attend_tape():
            # Aucune fenêtre ouverte : ignoré silencieusement, comme prévu par
            # `PROTOCOLE.md` §10.2 (le message compte quand même dans le débit).
            return True
        donnees_tape = message.get("d")
        delai = donnees_tape.get("delai_ms") if isinstance(donnees_tape, dict) else None
        _accepte, motif = table.partie.recevoir_tape(siege.numero, delai)
        if motif and motif != "deja_envoye":
            journal.info("tape siège=%d table=%s : %s", siege.numero, table.code, motif)
        # Volontairement AUCUN retour au joueur : lui signaler que son délai est
        # refusé lui révélerait le plancher physiologique, donc un oracle pour
        # tricher. Le verdict arrive pour tout le monde via `doublon_resolu`.
        return True

    if type_ == "signaler":
        # Étape S4 : signalements et blocages.
        await _envoyer(
            siege.websocket,
            _message_erreur("pas_encore_en_partie", "Pas encore pris en charge par le serveur."),
        )
        return True

    await _envoyer(siege.websocket, _message_erreur("type_inconnu", "Message non reconnu."))
    return True


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "serveur.jeu.main:app",
        host=cfg.hote,
        port=cfg.port,
        workers=1,                 # obligatoire : les tables vivent en mémoire
        proxy_headers=True,
        forwarded_allow_ips="127.0.0.1",
    )
