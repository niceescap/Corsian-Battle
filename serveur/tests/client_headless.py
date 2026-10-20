"""Client de jeu sans interface : recetter le serveur **sans l'app Flutter**.

Crée N comptes invités, ouvre une table, fait asseoir tout le monde, se déclare
prêt, puis joue automatiquement jusqu'à la fin de la partie en imprimant le
transcript des messages. C'est l'outil de recette du lot A (boucle de coups) et
il servira tel quel au lot B (fenêtre de doublon : il répond déjà `tape`).

    # En local, services lancés par serveur/lancer_local.sh
    python3 serveur/tests/client_headless.py --joueurs 2
    python3 serveur/tests/client_headless.py --joueurs 4 --parties 3

    # À travers nginx
    python3 serveur/tests/client_headless.py \
        --auth https://soft.opik.net/corsian-battle \
        --jeu  https://soft.opik.net/corsian-battle

    # Sans auth (serveur démarré avec MODE_SANS_AUTH=1)
    python3 serveur/tests/client_headless.py --sans-auth

Dépendances : `websockets` (fourni par `uvicorn[standard]`) pour le socket, et
la bibliothèque standard (`urllib`) pour le REST — rien à installer en plus.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import sys
import time
import urllib.error
import urllib.request
import uuid
from typing import Any, Dict, List, Optional

try:
    import websockets
except ImportError:                                       # pragma: no cover
    sys.exit(
        "Le paquet `websockets` est introuvable. Il est fourni par "
        "`uvicorn[standard]` : .venv/bin/pip install -r serveur/requirements.txt"
    )

VERSION_PROTO = 1


# ---------------------------------------------------------------------------
# REST (bibliothèque standard)
# ---------------------------------------------------------------------------
def _appel(methode: str, url: str, corps: Optional[dict] = None, jeton: Optional[str] = None) -> dict:
    entetes = {"Content-Type": "application/json"}
    if jeton:
        entetes["Authorization"] = f"Bearer {jeton}"
    donnees = json.dumps(corps).encode("utf-8") if corps is not None else None
    requete = urllib.request.Request(url, data=donnees, headers=entetes, method=methode)
    try:
        with urllib.request.urlopen(requete, timeout=20) as reponse:
            brut = reponse.read().decode("utf-8")
            return json.loads(brut) if brut else {}
    except urllib.error.HTTPError as erreur:
        detail = erreur.read().decode("utf-8", "replace")
        raise SystemExit(f"HTTP {erreur.code} sur {methode} {url}\n{detail}") from erreur
    except urllib.error.URLError as erreur:
        raise SystemExit(f"Serveur injoignable sur {url} : {erreur.reason}") from erreur


def creer_compte(base_auth: str, index: int, sans_auth: bool, reutiliser: bool = False) -> Dict[str, Any]:
    """Crée — ou retrouve — un compte invité.

    Avec `reutiliser`, l'`uuid_appareil` est fixe : `POST /api/auth/invite` est
    idempotent, donc aucun compte n'est créé après le premier passage. C'est la
    seule façon d'enchaîner les parties sans buter sur la limite de création de
    comptes (5/h/IP par défaut → `429` dès la deuxième partie à 4 joueurs).
    """
    if sans_auth:
        return {
            "id": f"dev-{index}",
            "pseudo": f"Bot{index}",
            "jeton_acces": f"dev-{index}",
            "nouveau_compte": True,
        }
    uuid_appareil = (
        f"headless-fixe-{index}" if reutiliser else f"headless-{uuid.uuid4().hex[:16]}"
    )
    reponse = _appel(
        "POST",
        f"{base_auth}/api/auth/invite",
        {
            "uuid_appareil": uuid_appareil,
            "pseudo": f"Bot{index}{random.randint(10, 99)}",
            "plateforme": "test",
            "version_app": "headless",
        },
    )
    return reponse


def creer_table(base_jeu: str, jeton: str, type_partie: str) -> str:
    return _appel("POST", f"{base_jeu}/api/jeu/tables", {"type": type_partie}, jeton)["code"]


def rejoindre_table(base_jeu: str, jeton: str, code: str) -> int:
    return _appel("POST", f"{base_jeu}/api/jeu/tables/{code}/rejoindre", None, jeton)["siege"]


def url_ws(base_jeu: str) -> str:
    if base_jeu.startswith("https://"):
        return "wss://" + base_jeu[len("https://"):].rstrip("/") + "/ws"
    if base_jeu.startswith("http://"):
        return "ws://" + base_jeu[len("http://"):].rstrip("/") + "/ws"
    return base_jeu.rstrip("/") + "/ws"


# ---------------------------------------------------------------------------
# Un joueur
# ---------------------------------------------------------------------------
class Joueur:
    def __init__(self, compte: Dict[str, Any], verbeux: bool, rapide: bool = False) -> None:
        self.compte = compte
        self.pseudo = compte.get("pseudo", "?")
        self.jeton = compte.get("jeton_acces", "")
        self.siege: Optional[int] = None
        self.pret = False
        self.dernier_seq_joue = -1
        self.coups_joues = 0
        self.tapes = 0
        self.ma_carte: Optional[str] = None
        self.verbeux = verbeux
        self.rapide = rapide

    def log(self, texte: str) -> None:
        if self.verbeux:
            print(f"  [{self.pseudo:>10}] {texte}", flush=True)

    async def jouer(self, socket: Any) -> None:
        """Pose sa carte si c'est son tour. Une temporisation courte imite un
        humain et évite d'enchaîner les coups à la vitesse du serveur ;
        `--rapide` la supprime pour les recettes de charge."""
        if self.siege is None:
            return
        if not self.rapide:
            await asyncio.sleep(random.uniform(0.05, 0.30))
        await socket.send(json.dumps({"type": "poser_carte"}))
        self.coups_joues += 1
        self.log(f"pose {self.ma_carte or '?'}")

    async def taper(self, socket: Any, fenetre_ms: int) -> None:
        """Répond à `doublon_ouvert` avec un délai mesuré localement.

        Le lot A n'ouvre jamais de fenêtre (les doublons passent sans effet) ;
        ce code est déjà prêt pour le lot B.
        """
        delai = int(random.uniform(180, min(450, max(fenetre_ms - 50, 200))))
        if not self.rapide:
            # En mode rapide on n'attend pas, mais on annonce quand même un
            # délai plausible : c'est cette valeur que le serveur compare.
            await asyncio.sleep(delai / 1000.0)
        await socket.send(json.dumps({"type": "tape", "d": {"delai_ms": delai}}))
        self.tapes += 1
        self.log(f"TAPE ({delai} ms)")

    async def session(self, ws_url: str, code: str) -> Optional[Dict[str, Any]]:
        async with websockets.connect(ws_url, max_size=2**20) as socket:
            await socket.send(
                json.dumps(
                    {
                        "type": "bonjour",
                        "d": {
                            "jeton": self.jeton,
                            "table": code,
                            "version_proto": VERSION_PROTO,
                        },
                    }
                )
            )
            while True:
                try:
                    brut = await socket.recv()
                except websockets.exceptions.ConnectionClosed as fermeture:
                    self.log(f"socket fermé ({fermeture.code})")
                    return None
                message = json.loads(brut)
                type_ = message.get("type")
                donnees = message.get("d") or {}
                seq = message.get("seq", 0)

                if type_ == "bienvenue":
                    self.siege = donnees.get("siege")
                    self.log(f"connecté siège {self.siege} · table {donnees.get('table')}")

                elif type_ == "table_etat":
                    if donnees.get("etat") == "attente" and not self.pret:
                        self.pret = True
                        await socket.send(json.dumps({"type": "pret"}))
                        self.log("prêt")
                    elif donnees.get("suivant") == self.siege and seq > self.dernier_seq_joue:
                        self.dernier_seq_joue = seq
                        await self.jouer(socket)

                elif type_ == "ta_carte_suivante":
                    self.ma_carte = donnees.get("carte")
                    self.log(f"[privé] ma carte du dessus : {self.ma_carte}")

                elif type_ == "carte_posee":
                    if donnees.get("suivant") == self.siege and seq > self.dernier_seq_joue:
                        self.dernier_seq_joue = seq
                        await self.jouer(socket)

                elif type_ == "doublon_ouvert":
                    await self.taper(socket, int(donnees.get("fenetre_ms", 900)))

                elif type_ == "pli_gagne":
                    self.log(f"pli de {donnees.get('nb_cartes')} carte(s) → siège {donnees.get('gagnant')} ({donnees.get('raison')})")

                elif type_ == "partie_finie":
                    self.log("partie terminée")
                    return donnees

                elif type_ == "erreur":
                    if donnees.get("code") != "pas_ton_tour":
                        self.log(f"erreur : {donnees.get('code')}")

                elif type_ in ("joueur_rejoint", "joueur_pret", "joueur_parti",
                               "partie_lancee", "compte_a_rebours", "pong"):
                    self.log(f"· {type_}")


# ---------------------------------------------------------------------------
# Scénario complet
# ---------------------------------------------------------------------------
async def une_partie(args: argparse.Namespace, numero: int) -> Dict[str, Any]:
    type_partie = "duel" if args.joueurs == 2 else "table_quatre"
    comptes = [
        creer_compte(args.auth, i, args.sans_auth, args.reutiliser_comptes)
        for i in range(args.joueurs)
    ]
    jetons = [compte.get("jeton_acces", "") for compte in comptes]

    code = creer_table(args.jeu, jetons[0], type_partie)
    for jeton in jetons[1:]:
        rejoindre_table(args.jeu, jeton, code)

    print(
        f"\n— Partie {numero} · table {code} · {args.joueurs} joueurs · "
        f"{url_ws(args.jeu)}"
        f"{' · comptes réutilisés' if args.reutiliser_comptes else ''}"
        f"{' · rapide' if args.rapide else ''}",
        flush=True,
    )
    joueurs = [Joueur(compte, args.verbeux, args.rapide) for compte in comptes]
    debut = time.time()
    resultats = await asyncio.gather(
        *[joueur.session(url_ws(args.jeu), code) for joueur in joueurs],
        return_exceptions=True,
    )
    duree = time.time() - debut

    fin = next((r for r in resultats if isinstance(r, dict)), None)
    erreurs = [r for r in resultats if isinstance(r, BaseException)]
    print(
        f"  terminée en {duree:.1f} s · raison={fin.get('raison') if fin else '?'} · "
        f"gagnant=siège {fin.get('gagnant') if fin else '?'} · "
        f"coups={fin.get('nb_coups') if fin else '?'}",
        flush=True,
    )
    print(
        "  joueurs : "
        + " · ".join(
            f"{j.pseudo}({j.siege}) {j.coups_joues} coups, {j.tapes} tapes"
            for j in joueurs
        ),
        flush=True,
    )
    if fin and fin.get("stats"):
        for ligne in fin["stats"]:
            print(
                f"    siège {ligne['siege']} · {ligne['pseudo']} · "
                f"{ligne['nb_cartes']} cartes{' · GAGNANT' if ligne.get('gagnant') else ''}",
                flush=True,
            )
    for erreur in erreurs:
        print(f"  ⚠ exception d'un client : {type(erreur).__name__}: {erreur}", flush=True)
    return {
        "code": code,
        "raison": fin.get("raison") if fin else None,
        "gagnant": fin.get("gagnant") if fin else None,
        "coups": fin.get("nb_coups") if fin else None,
        "duree_s": round(duree, 1),
        "exceptions": len(erreurs),
    }


async def principal(args: argparse.Namespace) -> int:
    bilans: List[Dict[str, Any]] = []
    for numero in range(1, args.parties + 1):
        bilans.append(await une_partie(args, numero))
    terminees = sum(1 for b in bilans if b["raison"])
    print(
        f"\n=== {terminees}/{len(bilans)} partie(s) menée(s) à leur terme · "
        f"raisons : {sorted({b['raison'] for b in bilans if b['raison']})} · "
        f"exceptions : {sum(b['exceptions'] for b in bilans)}",
        flush=True,
    )
    return 0 if terminees == len(bilans) else 1


def lire_arguments() -> argparse.Namespace:
    analyseur = argparse.ArgumentParser(description="Client de recette sans interface")
    analyseur.add_argument("--auth", default="http://127.0.0.1:8111",
                           help="base de corsian-auth (défaut : http://127.0.0.1:8111)")
    analyseur.add_argument("--jeu", default="http://127.0.0.1:8112",
                           help="base de corsian-jeu (défaut : http://127.0.0.1:8112)")
    analyseur.add_argument("--joueurs", type=int, default=2, choices=(2, 4))
    analyseur.add_argument("--parties", type=int, default=1)
    analyseur.add_argument("--verbeux", action="store_true", help="imprime chaque message")
    analyseur.add_argument("--sans-auth", action="store_true",
                           help="serveur démarré avec MODE_SANS_AUTH=1 : jetons factices")
    analyseur.add_argument("--reutiliser-comptes", action="store_true",
                           help="uuid_appareil fixes : /invite est idempotent, aucun compte "
                                "créé après le premier passage (indispensable pour enchaîner "
                                "les parties sans buter sur la limite de 5 créations/h/IP)")
    analyseur.add_argument("--rapide", action="store_true",
                           help="supprime les temporisations de confort : les coups et les "
                                "tapes partent aussitôt (recettes de charge). Les délais de "
                                "tape annoncés restent plausibles, ce sont eux que le serveur "
                                "compare")
    return analyseur.parse_args()


if __name__ == "__main__":
    arguments = lire_arguments()
    try:
        sys.exit(asyncio.run(principal(arguments)))
    except KeyboardInterrupt:
        sys.exit(130)
