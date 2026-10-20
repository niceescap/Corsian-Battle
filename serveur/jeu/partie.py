"""Une partie en cours sur une table : moteur, tour, rythme, diffusion.

Cette classe ne touche **ni aux sockets ni à la base** : elle publie des
messages via le callback `diffuser` et signale la fin via `sur_fin`. C'est ce
qui la rend testable sans réseau (`serveur/tests/test_boucle_coups.py`).

Lot A : la boucle de coups est complète (carte posée, défi, rebond, pli gagné,
fin de partie, délai de tour avec coup automatique). Les doublons y passent
**sans effet** — le résolveur installé est `ResolveurAucuneTape`, qui emprunte
le chemin « personne n'a tapé » déjà testé du moteur. Le lot B remplacera ce
résolveur par `ResolveurTapeReseau` et ajoutera la fenêtre de collecte : aucun
autre changement ne sera nécessaire.
"""
from __future__ import annotations

import asyncio
import logging
import random
import time
from typing import Any, Awaitable, Callable, Dict, List, Optional

from bataille_corse.moteur import BatailleCorse
from bataille_corse.resolveur_tape import ResolveurTape
from serveur.commun.config import Config
from serveur.jeu import evenements
from serveur.jeu.table import Table

journal = logging.getLogger("corsian.jeu.partie")

MAX_COUPS = 200000          # garde-fou du moteur, aligné sur jouer_partie()
DUREE_MAX_S = 1800          # 30 min : au-delà, partie nulle (PROTOCOLE §13)


class ResolveurAucuneTape(ResolveurTape):
    """Personne ne tape : le doublon passe, le pli n'est attribué à personne.

    Ce n'est pas une règle inventée pour la V1 réseau, c'est le comportement
    réel d'une table où le doublon est manqué — et le moteur le gère déjà.
    """

    def determiner_gagnant(self, eligibles: List[Any]) -> None:
        return None


# (table, message, numéros de sièges destinataires ou None pour tous)
Diffuseur = Callable[[Table, Dict[str, Any], Optional[List[int]]], Awaitable[None]]
SurFin = Callable[["PartieEnLigne", str, Optional[int]], Awaitable[None]]


class PartieEnLigne:
    def __init__(
        self,
        table: Table,
        diffuser: Diffuseur,
        cfg: Config,
        seed: Optional[int] = None,
        sur_fin: Optional[SurFin] = None,
    ) -> None:
        self.table = table
        self.diffuser = diffuser
        self.cfg = cfg
        self.sur_fin = sur_fin
        self.seed = seed if seed is not None else random.randrange(1, 2**31 - 1)
        self.jeu: Optional[BatailleCorse] = None
        self.par_index: List[int] = []          # index moteur → numéro de siège
        self.par_siege: Dict[int, int] = {}     # numéro de siège → index moteur
        self.resolveur: ResolveurTape = ResolveurAucuneTape()
        self.coups = 0
        self.doublons_ouverts = 0
        self.lance_le = 0.0
        self.termine = False
        self.raison_fin: Optional[str] = None
        self.gagnant_siege: Optional[int] = None
        self._verrou: Optional[asyncio.Lock] = None
        self._minuteur: Optional[asyncio.Task] = None

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

    def index_vers_siege(self, index: Optional[int]) -> Optional[int]:
        if index is None:
            return None
        return self.par_index[index]

    def tour_courant(self) -> Optional[int]:
        """Numéro de siège dont c'est le tour, ou `None`."""
        if self.jeu is None or self.termine:
            return None
        return self.index_vers_siege(
            evenements.siege_effectif(self.jeu, self.jeu.index_courant)
        )

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
        """Index moteur → numéros de siège, récursivement."""
        if isinstance(valeur, dict):
            return {
                cle: self._traduire(v) if cle not in evenements.CHAMPS_INDEX else self.index_vers_siege(v)
                if isinstance(v, int)
                else self._traduire(v)
                for cle, v in valeur.items()
            }
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
        self.jeu = BatailleCorse(noms, resolveur_tape=self.resolveur, seed=self.seed)
        self.lance_le = time.time()
        self.table.etat = "en_jeu"
        self.table.lance_le = self.lance_le
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
            if code is not None and siege.ma_carte != code:
                siege.ma_carte = code
                await self.publier({"type": "ta_carte_suivante", "d": {"carte": code}}, vers=[numero])
            elif code is None and siege.ma_carte is not None:
                siege.ma_carte = None
                await self.publier({"type": "ta_carte_suivante", "d": {"carte": None}}, vers=[numero])

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
            coup = evenements.jouer_coup(self.jeu, auto=auto)
            if coup is None:
                await self.finir("partie_nulle")
                return None
            self.coups += 1
            if coup.etait_doublon:
                self.doublons_ouverts += 1
            for evenement in coup.evenements:
                await self.publier(
                    {"type": evenement["type"], "d": self._traduire(evenement["d"])}
                )
            self._maj_tailles()
            await self.annoncer_cartes()
            if coup.fini:
                await self.finir("victoire", gagnant=coup.gagnant)
            elif coup.bloque:
                journal.info("Partie bloquée (table %s) : plus personne ne peut jouer", self.table.code)
                await self.finir("partie_nulle")
            elif self.coups >= MAX_COUPS:
                await self.finir("partie_nulle")
            elif time.time() - self.lance_le > DUREE_MAX_S:
                await self.finir("expiration")
            else:
                self._lancer_minuteur()
            return coup

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
        """Libère le minuteur (table fermée, service arrêté)."""
        self._annuler_minuteur()

    # ------------------------------------------------------------------ #
    # Fin
    # ------------------------------------------------------------------ #
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

        stats = []
        for index, numero in enumerate(self.par_index):
            siege = self._siege(numero)
            stats.append(
                {
                    "siege": numero,
                    "pseudo": siege.pseudo,
                    "nb_cartes": siege.nb_cartes,
                    "gagnant": numero == self.gagnant_siege,
                    "est_bot": siege.est_bot,
                }
            )
        await self.publier(
            {
                "type": "partie_finie",
                "d": {
                    "gagnant": self.gagnant_siege,
                    "raison": raison,
                    "nb_coups": self.coups,
                    "duree_ms": int((time.time() - self.lance_le) * 1000),
                    "stats": stats,
                },
            }
        )
        journal.info(
            "Partie terminée · table=%s raison=%s gagnant=%s coups=%d",
            self.table.code, raison, self.gagnant_siege, self.coups,
        )
        if self.sur_fin is not None:
            try:
                await self.sur_fin(self, raison, self.gagnant_siege)
            except Exception:
                # Une écriture en base en échec ne doit jamais casser une fin
                # de partie côté joueurs : on journalise, on continue.
                journal.exception("Enregistrement de la partie en échec (table %s)", self.table.code)
