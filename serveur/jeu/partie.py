"""Une partie en cours sur une table : moteur, tour, rythme, doublons.

Cette classe ne touche **ni aux sockets ni à la base** : elle publie via le
callback `diffuser`, signale la fin via `sur_fin` et les triches suspectées via
`sur_suspicion`. C'est ce qui la rend testable sans réseau
(`serveur/tests/test_boucle_coups.py`, `test_fenetre_doublon.py`).

## La fenêtre de doublon (lot B)

Le moteur résout le doublon **pendant** `jouer_un_coup()` : il n'y a donc pas
de place pour une attente réseau à l'intérieur du coup. La solution retenue ne
modifie pas le moteur : le serveur **prédit** le doublon avant de jouer (il
connaît la carte du dessus du joueur et le sommet du pli), ouvre la fenêtre,
puis joue avec un résolveur déjà nourri des délais reçus.

    prédiction → doublon_ouvert (les 2 cartes) → collecte ≤ 900 ms →
    jouer_un_coup() avec ResolveurTapeReseau → carte_posee → doublon_resolu →
    pli_gagne (ou doublon_non_tape)

Conséquence assumée, documentée dans `docs/PROTOCOLE.md` §10.1 : pour la carte
qui fait le doublon, `doublon_ouvert` arrive **avant** `carte_posee`. Le client
anime la carte depuis `doublon_ouvert.cartes[1]` et démarre son chronomètre à
ce moment-là ; le `carte_posee` qui suit porte `annonce: true` et ne sert qu'à
mettre à jour l'état (tour, défi, taille du pli) — il ne doit pas rejouer
l'animation.

Le chronomètre du client part donc **au rendu de `doublon_ouvert`** : c'est
pourquoi `proxy_buffering off` sur le WebSocket est une condition d'équité et
non de confort (`docs/DEPLOIEMENT.md` §5.2).
"""
from __future__ import annotations

import asyncio
import logging
import random
import time
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple

from bataille_corse.moteur import BatailleCorse
from bataille_corse.resolveur_tape import ResolveurTape
from serveur.commun.config import Config
from serveur.jeu import evenements
from serveur.jeu.resolveur_reseau import ResolveurTapeReseau
from serveur.jeu.table import Table

journal = logging.getLogger("corsian.jeu.partie")

MAX_COUPS = 200000          # garde-fou du moteur, aligné sur jouer_partie()
DUREE_MAX_S = 1800          # 30 min : au-delà, partie nulle (PROTOCOLE §13)


class ResolveurAucuneTape(ResolveurTape):
    """Personne ne tape : le doublon passe, le pli n'est attribué à personne.

    Sert de résolveur par défaut (il n'est jamais appelé sur un coup sans
    doublon) et de repli quand `fenetre_active = False` (tests sans sockets).
    Ce n'est pas une règle inventée : c'est le comportement réel d'une table où
    le doublon est manqué, déjà géré et testé dans le moteur.
    """

    def determiner_gagnant(self, eligibles: List[Any]) -> None:
        return None


# (table, message, numéros de sièges destinataires ou None pour tous)
Diffuseur = Callable[[Table, Dict[str, Any], Optional[List[int]]], Awaitable[None]]
SurFin = Callable[["PartieEnLigne", str, Optional[int]], Awaitable[None]]
SurSuspicion = Callable[[List[Dict[str, Any]]], Awaitable[None]]


class PartieEnLigne:
    def __init__(
        self,
        table: Table,
        diffuser: Diffuseur,
        cfg: Config,
        seed: Optional[int] = None,
        sur_fin: Optional[SurFin] = None,
        sur_suspicion: Optional[SurSuspicion] = None,
    ) -> None:
        self.table = table
        self.diffuser = diffuser
        self.cfg = cfg
        self.sur_fin = sur_fin
        self.sur_suspicion = sur_suspicion
        self.seed = seed if seed is not None else random.randrange(1, 2**31 - 1)
        self.jeu: Optional[BatailleCorse] = None
        self.par_index: List[int] = []              # index moteur → numéro de siège
        self.par_siege: Dict[int, int] = {}         # numéro de siège → index moteur
        self.index_par_nom: Dict[str, int] = {}     # nom moteur → index moteur
        self.resolveur: ResolveurTape = ResolveurAucuneTape()
        self.fenetre_active: bool = True            # False en test sans sockets
        self.coups = 0
        self.doublons_ouverts = 0
        self.doublons_tapes = 0
        self.lance_le = 0.0
        self.termine = False
        self.raison_fin: Optional[str] = None
        self.gagnant_siege: Optional[int] = None
        self.stats_sieges: Dict[int, Dict[str, Any]] = {}
        self._verrou: Optional[asyncio.Lock] = None
        self._minuteur: Optional[asyncio.Task] = None
        self._resolveur_courant: Optional[ResolveurTapeReseau] = None
        self._fin_fenetre: Optional[asyncio.Event] = None
        self._tapes_recues: set = set()
        self._delais_recus: Dict[int, float] = {}

    # ------------------------------------------------------------------ #
    # Accès
    # ------------------------------------------------------------------ #
    @property
    def verrou(self) -> asyncio.Lock:
        if self._verrou is None:
            self._verrou = asyncio.Lock()
        return self._verrou

    def _siege(self, numero: int) -> Any:
        for siege in self.table.sieges:
            if siege.numero == numero:
                return siege
        raise KeyError(f"siège {numero} absent de la table {self.table.code}")

    def _sieges_occupes(self) -> List[int]:
        return [s.numero for s in self.table.sieges if s.occupe()]

    def _sieges_connectes(self) -> List[int]:
        """Sièges en jeu **et** actuellement connectés : eux seuls peuvent taper."""
        return [
            s.numero
            for s in self.table.sieges
            if s.occupe() and s.websocket is not None and s.numero in self.par_siege
        ]

    def index_vers_siege(self, index: Optional[int]) -> Optional[int]:
        if index is None:
            return None
        return self.par_index[index]

    def tour_courant(self) -> Optional[int]:
        if self.jeu is None or self.termine:
            return None
        return self.index_vers_siege(
            evenements.siege_effectif(self.jeu, self.jeu.index_courant)
        )

    def attend_tape(self) -> bool:
        return self._resolveur_courant is not None and self._fin_fenetre is not None

    def etat_public(self) -> Dict[str, Any]:
        """Champs de partie pour `table_etat`, déjà traduits en sièges."""
        if self.jeu is None:
            return {}
        etat = evenements.Etat.capturer(self.jeu)
        defi = None
        if etat.defi_poseur is not None:
            defi = {
                "poseur": self.index_vers_siege(etat.defi_poseur),
                "repondeur": self.index_vers_siege(etat.index_courant),
                "chances_restantes": etat.defi_chances,
            }
        return {
            "pli": list(etat.pli),
            "reste_neutre": etat.reste_neutre,
            "suivant": self.index_vers_siege(
                evenements.siege_effectif(self.jeu, etat.index_courant)
            ),
            "defi": defi,
            "fenetre_tape": None,
            "nb_coups": self.coups,
        }

    # ------------------------------------------------------------------ #
    # Publication
    # ------------------------------------------------------------------ #
    async def publier(
        self, message: Dict[str, Any], vers: Optional[List[int]] = None
    ) -> None:
        message.setdefault("seq", self.table.prochain_seq())
        await self.diffuser(self.table, message, vers)

    def _traduire(self, valeur: Any) -> Any:
        """Index moteur → numéros de siège, récursivement.

        Seuls les champs listés dans `evenements.CHAMPS_INDEX` portent un index
        moteur ; les autres (codes de cartes, tailles, booléens) passent tels
        quels. Un index absent (partie bloquée → `suivant: null`) reste nul.
        """
        if isinstance(valeur, dict):
            sortie: Dict[str, Any] = {}
            for cle, sous in valeur.items():
                if cle in evenements.CHAMPS_INDEX and isinstance(sous, int):
                    sortie[cle] = self.index_vers_siege(sous)
                else:
                    sortie[cle] = self._traduire(sous)
            return sortie
        if isinstance(valeur, list):
            return [self._traduire(v) for v in valeur]
        return valeur

    # ------------------------------------------------------------------ #
    # Lancement
    # ------------------------------------------------------------------ #
    async def lancer(self) -> None:
        numeros = self._sieges_occupes()
        if len(numeros) < 2:
            raise ValueError("Il faut au moins deux joueurs pour lancer une partie.")
        self.par_index = numeros
        self.par_siege = {numero: i for i, numero in enumerate(numeros)}
        noms = [self._siege(n).pseudo or f"Joueur{n}" for n in numeros]
        if len(set(noms)) != len(noms):
            # Le résolveur réseau classe par nom : l'unicité est un prérequis.
            # L'unicité stricte des pseudos la garantit pour les humains.
            raise ValueError("Les pseudos d'une table doivent être uniques.")
        self.jeu = BatailleCorse(noms, resolveur_tape=self.resolveur, seed=self.seed)
        self.index_par_nom = {joueur.nom: i for i, joueur in enumerate(self.jeu.joueurs)}
        self.lance_le = time.time()
        self.table.etat = "en_jeu"
        self.table.lance_le = self.lance_le
        self.stats_sieges = {
            numero: {
                "doublons_gagnes": 0,
                "doublons_perdus": 0,
                "tapes_manquees": 0,
                "delais": [],
            }
            for numero in numeros
        }
        self._maj_tailles()

        await self.publier(
            {
                "type": "partie_lancee",
                "d": {
                    "nb_joueurs": len(numeros),
                    "taille_tas": [
                        self.jeu.joueurs[i].nombre_cartes() for i in range(len(numeros))
                    ],
                    "nb_reste_neutre": len(self.jeu.cartes_reste_neutres),
                    "premier_siege": self.index_vers_siege(0),
                },
            }
        )
        await self.annoncer_cartes()
        self._lancer_minuteur()
        journal.info(
            "Partie lancée · table=%s seed=%d sièges=%s", self.table.code, self.seed, numeros
        )

    def _maj_tailles(self) -> None:
        if self.jeu is None:
            return
        for index, numero in enumerate(self.par_index):
            self._siege(numero).nb_cartes = self.jeu.joueurs[index].nombre_cartes()

    async def annoncer_cartes(self) -> None:
        """`ta_carte_suivante` : privé, un seul destinataire par message."""
        if self.jeu is None:
            return
        for index, numero in enumerate(self.par_index):
            code = evenements.carte_du_dessus(self.jeu, index)
            siege = self._siege(numero)
            if siege.ma_carte == code:
                continue
            siege.ma_carte = code
            await self.publier(
                {"type": "ta_carte_suivante", "d": {"carte": code}}, vers=[numero]
            )

    # ------------------------------------------------------------------ #
    # Fenêtre de doublon
    # ------------------------------------------------------------------ #
    def _doublon_previsible(self) -> Optional[Tuple[str, str]]:
        """`(carte_du_pli, carte_a_venir)` si le prochain coup ouvre un doublon.

        Prédiction exacte : le serveur connaît le sommet du pli (public) et la
        carte du dessus du joueur dont c'est le tour. Elle ne révèle rien aux
        autres joueurs — elle sert uniquement à ouvrir la fenêtre au bon moment.
        """
        if self.jeu is None:
            return None
        index = evenements.siege_effectif(self.jeu, self.jeu.index_courant)
        if index is None or not self.jeu.pli:
            return None
        tas = self.jeu.joueurs[index].tas
        if not len(tas):
            return None
        if tas[0].rang != self.jeu.pli[-1].rang:
            return None
        return self.jeu.pli[-1].code, tas[0].code

    async def _fenetre_doublon(self, cartes: Tuple[str, str]) -> ResolveurTapeReseau:
        """Ouvre la fenêtre, collecte les `tape`, renvoie le résolveur nourri."""
        resolveur = ResolveurTapeReseau(
            plancher_ms=self.cfg.plancher_tape_ms,
            refus_ms=self.cfg.refus_tape_ms,
            fenetre_ms=self.cfg.fenetre_tape_ms,
        )
        self._resolveur_courant = resolveur
        self._fin_fenetre = asyncio.Event()
        self._tapes_recues = set()
        self._delais_recus = {}

        await self.publier(
            {
                "type": "doublon_ouvert",
                "d": {
                    "fenetre_ms": self.cfg.fenetre_tape_ms,
                    "plancher_ms": self.cfg.plancher_tape_ms,
                    "cartes": list(cartes),
                },
            }
        )
        try:
            await asyncio.wait_for(
                self._fin_fenetre.wait(),
                timeout=max(int(self.cfg.fenetre_tape_ms), 1) / 1000.0,
            )
        except asyncio.TimeoutError:
            pass
        resolveur.cloturer()
        self._resolveur_courant = None
        self._fin_fenetre = None
        return resolveur

    def recevoir_tape(self, numero_siege: int, delai_ms: Any) -> Tuple[bool, Optional[str]]:
        """Enregistre un `tape` reçu pendant la fenêtre.

        Renvoie `(accepté, motif)`. Le motif ne part **jamais** vers le joueur
        concerné : lui révéler qu'un délai est refusé serait un oracle sur le
        plancher physiologique. Il est seulement journalisé et consigné.
        """
        resolveur = self._resolveur_courant
        if resolveur is None or self._fin_fenetre is None or self.jeu is None:
            return False, "aucune_fenetre"
        index = self.par_siege.get(numero_siege)
        if index is None:
            return False, "siege_hors_jeu"
        nom = self.jeu.joueurs[index].nom
        try:
            valeur = float(delai_ms)
        except (TypeError, ValueError):
            valeur = float("nan")
        self._tapes_recues.add(numero_siege)
        if valeur == valeur:                       # ni NaN
            self._delais_recus[numero_siege] = valeur
        accepte, motif = resolveur.enregistrer(nom, delai_ms)
        if self._toutes_recues():
            self._fin_fenetre.set()                # tout le monde a répondu : clôture tôt
        return accepte, motif

    def _toutes_recues(self) -> bool:
        connectes = set(self._sieges_connectes())
        return bool(connectes) and connectes <= self._tapes_recues

    async def _consommer_verdict(self, resolveur: ResolveurTapeReseau) -> None:
        """Statistiques par siège + signalement des délais impossibles."""
        verdict = resolveur.verdict
        if verdict is None:
            return
        gagnant_index = (
            self.index_par_nom.get(verdict.gagnant_nom) if verdict.gagnant_nom else None
        )
        if gagnant_index is not None:
            self.doublons_tapes += 1
        for numero, stats in self.stats_sieges.items():
            index = self.par_siege.get(numero)
            if index is None:
                continue
            delai = self._delais_recus.get(numero)
            if delai is not None:
                stats["delais"].append(delai)
            if gagnant_index is None:
                if numero in self._tapes_recues:
                    stats["doublons_perdus"] += 1
                continue
            if index == gagnant_index:
                stats["doublons_gagnes"] += 1
            elif numero in self._tapes_recues:
                stats["doublons_perdus"] += 1
            else:
                stats["tapes_manquees"] += 1

        if self.sur_suspicion is None:
            return
        suspects = []
        for nom, motif in resolveur.suspicions():
            index = self.index_par_nom.get(nom)
            if index is None:
                continue
            numero = self.index_vers_siege(index)
            valeur = self._delais_recus.get(numero)
            suspects.append(
                {
                    "siege": numero,
                    "type": motif,
                    "valeur_ms": int(valeur) if valeur is not None else None,
                }
            )
        if suspects:
            journal.warning(
                "Table %s : %d suspicion(s) de tape — %s",
                self.table.code, len(suspects), suspects,
            )
            try:
                await self.sur_suspicion(suspects)
            except Exception:
                journal.exception("Consignation des suspicions en échec")

    # ------------------------------------------------------------------ #
    # Coups
    # ------------------------------------------------------------------ #
    async def poser_carte(self, numero_siege: int) -> bool:
        """Intention d'un joueur : pose **sa carte du dessus** (la seule légale).

        Le client ne désigne jamais une carte — c'est le serveur qui la connaît.
        """
        if self.termine or self.jeu is None:
            return False
        index = self.par_siege.get(numero_siege)
        if index is None:
            return False
        tour = evenements.siege_effectif(self.jeu, self.jeu.index_courant)
        if tour is None or tour != index:
            await self.publier(
                {
                    "type": "erreur",
                    "seq": 0,
                    "d": {"code": "pas_ton_tour", "message": "Ce n'est pas ton tour."},
                },
                vers=[numero_siege],
            )
            return False
        await self.jouer(auto=False)
        return True

    async def jouer(self, auto: bool = False) -> Optional[evenements.Coup]:
        if self.termine or self.jeu is None:
            return None
        async with self.verrou:
            if self.termine or self.jeu is None:      # revérifié sous verrou
                return None
            self._annuler_minuteur()

            # 1) Doublon prévisible ? Fenêtre AVANT le coup : le moteur résout
            #    la tape pendant jouer_un_coup(), il n'y a donc pas de place
            #    pour une attente réseau à l'intérieur du coup.
            previsible = self._doublon_previsible()
            resolveur: ResolveurTape = self.resolveur
            fenetre = False
            if previsible is not None:
                self.doublons_ouverts += 1
                if self.fenetre_active:
                    fenetre = True
                    resolveur = await self._fenetre_doublon(previsionable)
            self.jeu.resolveur_tape = resolveur
            doublon_resolu: Optional[bool] = (
                resolveur.nb_retenu() > 0
                if isinstance(resolveur, ResolveurTapeReseau)
                else None
            )

            # 2) Le coup, moteur inchangé.
            coup = evenements.jouer_coup(
                self.jeu, auto=auto, doublon_resolu=doublon_resolu
            )
            if coup is None:
                await self.finir("partie_nulle")
                return None
            self.coups += 1

            # 3) Diffusion : carte posée, verdict de la tape, puis le reste.
            if fenetre:
                premier = coup.evenements[0]
                premier["d"]["annonce"] = True      # déjà animée via doublon_ouvert
                await self.publier(
                    {"type": premier["type"], "d": self._traduire(premier["d"])}
                )
                await self._publier_verdict(resolveur)
                await self._consommer_verdict(resolveur)
                reste = coup.evenements[1:]
            else:
                reste = coup.evenements
            for evenement in reste:
                await self.publier(
                    {"type": evenement["type"], "d": self._traduire(evenement["d"])}
                )

            self._maj_tailles()
            await self.annoncer_cartes()
            self.jeu.resolveur_tape = self.resolveur     # repli pour les coups suivants

            # 4) Suite
            if coup.fini:
                await self.finir("victoire", gagnant=coup.gagnant)
            elif coup.bloque:
                journal.info(
                    "Partie bloquée (table %s) : plus personne ne peut jouer", self.table.code
                )
                await self.finir("partie_nulle")
            elif self.coups >= MAX_COUPS:
                await self.finir("partie_nulle")
            elif time.time() - self.lance_le > DUREE_MAX_S:
                await self.finir("expiration")
            else:
                self._lancer_minuteur()
            return coup

    async def _publier_verdict(self, resolveur: ResolveurTapeReseau) -> None:
        verdict = resolveur.verdict
        if verdict is None:
            return
        gagnant_index = (
            self.index_par_nom.get(verdict.gagnant_nom) if verdict.gagnant_nom else None
        )
        await self.publier(
            {
                "type": "doublon_resolu",
                "d": {
                    "gagnant": self.index_vers_siege(gagnant_index),
                    "delai_ms_gagnant": (
                        round(verdict.delai_gagnant_ms, 1)
                        if verdict.delai_gagnant_ms is not None
                        else None
                    ),
                    "personne": bool(verdict.personne),
                    "nb_tapes": resolveur.nb_retenu(),
                },
            }
        )

    # ------------------------------------------------------------------ #
    # Délai de tour
    # ------------------------------------------------------------------ #
    def _lancer_minuteur(self) -> None:
        self._annuler_minuteur()
        if self.termine:
            return
        try:
            boucle = asyncio.get_running_loop()
        except RuntimeError:
            return                       # hors boucle (test synchrone) : pas de minuteur
        self._minuteur = boucle.create_task(self._attente_tour())

    async def _attente_tour(self) -> None:
        delai_s = max(int(self.cfg.delai_tour_ms), 0) / 1000.0
        try:
            await asyncio.sleep(delai_s)
        except asyncio.CancelledError:
            return
        if not self.termine:
            journal.info("Tour expiré (table %s) : coup automatique", self.table.code)
            await self.jouer(auto=True)

    def _annuler_minuteur(self) -> None:
        if self._minuteur is not None:
            self._minuteur.cancel()
            self._minuteur = None

    def detruire(self) -> None:
        """Libère le minuteur et la fenêtre en cours (table fermée, arrêt)."""
        self._annuler_minuteur()
        if self._fin_fenetre is not None:
            self._fin_fenetre.set()

    # ------------------------------------------------------------------ #
    # Fin
    # ------------------------------------------------------------------ #
    def statistiques(self) -> List[Dict[str, Any]]:
        """Bilan par siège, pour `partie_finie` et pour la base."""
        sortie = []
        for numero in self.par_index:
            siege = self._siege(numero)
            stats = self.stats_sieges.get(numero, {})
            delais_tries = sorted(stats.get("delais") or [])
            mediane = delais_tries[len(delais_tries) // 2] if delais_tries else None
            sortie.append(
                {
                    "siege": numero,
                    "pseudo": siege.pseudo,
                    "nb_cartes": siege.nb_cartes,
                    "gagnant": numero == self.gagnant_siege,
                    "est_bot": siege.est_bot,
                    "doublons_gagnes": stats.get("doublons_gagnes", 0),
                    "doublons_perdus": stats.get("doublons_perdus", 0),
                    "tapes_manquees": stats.get("tapes_manquees", 0),
                    "delai_tape_median_ms": mediane,
                }
            )
        return sortie

    async def finir(self, raison: str, gagnant: Optional[int] = None) -> None:
        if self.termine:
            return
        self.termine = True
        self.raison_fin = raison
        self._annuler_minuteur()
        self.gagnant_siege = self.index_vers_siege(gagnant)
        self.table.etat = "terminee"
        self.table.terminee_le = time.time()
        self.table.raison_fin = raison
        self._maj_tailles()

        await self.publier(
            {
                "type": "partie_finie",
                "d": {
                    "gagnant": self.gagnant_siege,
                    "raison": raison,
                    "nb_coups": self.coups,
                    "nb_doublons": self.doublons_ouverts,
                    "nb_doublons_tapes": self.doublons_tapes,
                    "duree_ms": int((time.time() - self.lance_le) * 1000),
                    "stats": self.statistiques(),
                },
            }
        )
        journal.info(
            "Partie terminée · table=%s raison=%s gagnant=%s coups=%d doublons=%d/%d",
            self.table.code, raison, self.gagnant_siege, self.coups,
            self.doublons_tapes, self.doublons_ouverts,
        )
        if self.sur_fin is not None:
            try:
                await self.sur_fin(self, raison, self.gagnant_siege)
            except Exception:
                # Une écriture en base en échec ne doit jamais casser une fin
                # de partie côté joueurs : on journalise, on continue.
                journal.exception(
                    "Enregistrement de la partie en échec (table %s)", self.table.code
                )
