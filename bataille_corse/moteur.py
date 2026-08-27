"""Moteur de jeu pour la Bataille Corse.

Règles implémentées :
- distribution égale entre joueurs, reste mis de côté (neutre) jusqu'à ce
  que le premier pli soit remporté, où il est alors intégré aux cartes
  gagnées ;
- un joueur joue toujours obligatoirement sa carte du dessus ;
- une figure (As/Roi/Dame/Valet) met le pli "en jeu" : le joueur suivant
  (et uniquement lui) dispose d'un nombre de cartes-chances selon le
  barème (As 4, Roi 3, Dame 2, Valet 1) pour ressortir une figure ;
- si une figure ressort dans ce nombre de cartes, le défi "rebondit" sur
  ce nouveau joueur, et c'est au joueur suivant de tenter sa chance selon
  le nouveau barème — sans limite d'enchaînements, jusqu'à épuisement des
  tas ;
- si le joueur qui répond n'a plus assez de cartes pour finir ses chances,
  il pose ce qu'il lui reste et le défi échoue s'il n'a pas sorti de
  figure ;
- si aucune figure ne ressort dans le nombre imparti, le dernier poseur de
  figure remporte le pli ;
- un doublon (deux cartes de même rang qui se suivent sur le pli, tous
  rangs confondus) est PRIORITAIRE À TOUT MOMENT, même en plein défi : le
  premier joueur qui tape remporte immédiatement le pli en cours ;
- un joueur sans carte reste en jeu : il peut encore taper sur un doublon
  pour revenir en jeu ;
- fin de partie : un seul joueur a remporté les 52 cartes.
"""
from __future__ import annotations

import random
from typing import List, Optional

from .cartes import TAILLE_PAQUET, Carte, construire_paquet
from .joueur import Joueur
from .resolveur_tape import ResolveurSimulationBots, ResolveurTape


class DefiEnCours:
    __slots__ = ("proprietaire", "chances_restantes")

    def __init__(self, proprietaire: Joueur, chances_restantes: int):
        self.proprietaire = proprietaire
        self.chances_restantes = chances_restantes


class BatailleCorse:
    def __init__(
        self,
        noms_joueurs: List[str],
        resolveur_tape: Optional[ResolveurTape] = None,
        seed: Optional[int] = None,
    ):
        if len(noms_joueurs) < 2:
            raise ValueError("Il faut au moins 2 joueurs.")

        self.rng = random.Random(seed)
        self.joueurs: List[Joueur] = [Joueur(n) for n in noms_joueurs]
        self.pli: List[Carte] = []  # dernier élément = dessus du pli en cours
        self.cartes_reste_neutres: List[Carte] = []
        self.resolveur_tape = resolveur_tape or ResolveurSimulationBots(seed=seed)
        self.index_courant = 0
        self.defi_en_cours: Optional[DefiEnCours] = None
        self.historique: List[str] = []

        self._distribuer()

    # ---------------------------------------------------------------- #
    # Distribution
    # ---------------------------------------------------------------- #
    def _distribuer(self) -> None:
        paquet = construire_paquet(self.rng)
        n = len(self.joueurs)
        part = len(paquet) // n
        for i, j in enumerate(self.joueurs):
            j.tas.extend(paquet[i * part : (i + 1) * part])
        # Le reste non distribuable est neutre : il rejoindra les cartes
        # du gagnant du tout premier pli, sans influer sur les règles
        # avant ça (pas de figure/doublon "gratuit" au départ).
        self.cartes_reste_neutres = paquet[n * part :]

    # ---------------------------------------------------------------- #
    # Utilitaires de tour
    # ---------------------------------------------------------------- #
    def _prochain_index_avec_cartes(self, depuis: int) -> Optional[int]:
        n = len(self.joueurs)
        for pas in range(1, n + 1):
            i = (depuis + pas) % n
            if self.joueurs[i].a_des_cartes():
                return i
        return None

    def gagnant_final(self) -> Optional[Joueur]:
        for j in self.joueurs:
            if j.nombre_cartes() == TAILLE_PAQUET:
                return j
        return None

    def _attribuer_pli(self, gagnant: Joueur) -> None:
        cartes = self.pli
        if self.cartes_reste_neutres:
            cartes = cartes + self.cartes_reste_neutres
            self.cartes_reste_neutres = []
        gagnant.recevoir_pli(cartes)
        self.pli = []
        self.defi_en_cours = None
        self.index_courant = self.joueurs.index(gagnant)

    # ---------------------------------------------------------------- #
    # Doublon (priorité absolue)
    # ---------------------------------------------------------------- #
    def _est_doublon(self) -> bool:
        return len(self.pli) >= 2 and self.pli[-1].rang == self.pli[-2].rang

    def _resoudre_doublon(self) -> Joueur:
        gagnant = self.resolveur_tape.determiner_gagnant(self.joueurs)
        taille_pli = len(self.pli) + len(self.cartes_reste_neutres)
        self.historique.append(
            f"Doublon ! {gagnant.nom} tape et remporte {taille_pli} carte(s)."
        )
        self._attribuer_pli(gagnant)
        return gagnant

    # ---------------------------------------------------------------- #
    # Échec d'un défi (aucune figure ressortie à temps)
    # ---------------------------------------------------------------- #
    def _cloturer_defi_echec(self) -> None:
        assert self.defi_en_cours is not None
        gagnant = self.defi_en_cours.proprietaire
        taille_pli = len(self.pli) + len(self.cartes_reste_neutres)
        self.historique.append(
            f"Défi manqué : {gagnant.nom} remporte {taille_pli} carte(s)."
        )
        self._attribuer_pli(gagnant)

    # ---------------------------------------------------------------- #
    # Un coup de jeu
    # ---------------------------------------------------------------- #
    def jouer_un_coup(self) -> None:
        """Fait jouer sa carte du dessus au joueur courant et applique
        toutes les règles qui en découlent (figure, défi, doublon)."""
        if self.gagnant_final() is not None:
            return

        joueur = self.joueurs[self.index_courant]
        if not joueur.a_des_cartes():
            suivant = self._prochain_index_avec_cartes(self.index_courant)
            if suivant is None:
                return
            self.index_courant = suivant
            joueur = self.joueurs[self.index_courant]

        carte = joueur.jouer_carte_du_dessus()
        self.pli.append(carte)
        self.historique.append(f"{joueur.nom} joue {carte}.")

        # 1) Le doublon est TOUJOURS prioritaire, même en plein défi.
        if self._est_doublon():
            self._resoudre_doublon()
            return

        # 2) Une figure (re)lance ou fait rebondir le défi, qu'il y en ait
        #    déjà un en cours ou non.
        if carte.est_figure:
            self.defi_en_cours = DefiEnCours(joueur, carte.chances)
            suivant = self._prochain_index_avec_cartes(self.index_courant)
            if suivant is None:
                self._cloturer_defi_echec()
                return
            self.index_courant = suivant
            return

        # 3) Carte normale pendant un défi : elle consomme une chance du répondeur.
        if self.defi_en_cours is not None:
            self.defi_en_cours.chances_restantes -= 1
            if self.defi_en_cours.chances_restantes <= 0 or not joueur.a_des_cartes():
                self._cloturer_defi_echec()
                return
            # C'est toujours au joueur répondeur de continuer à jouer ses chances restantes
            return

        # 4) Jeu normal, pas de défi en cours : le pli continue de tourner.
        suivant = self._prochain_index_avec_cartes(self.index_courant)
        if suivant is not None:
            self.index_courant = suivant

    # ---------------------------------------------------------------- #
    # Boucle complète (pratique pour les tests / simulations)
    # ---------------------------------------------------------------- #
    def jouer_partie(self, max_coups: int = 200_000) -> Joueur:
        coups = 0
        while self.gagnant_final() is None and coups < max_coups:
            self.jouer_un_coup()
            coups += 1
        gagnant = self.gagnant_final()
        if gagnant is None:
            raise RuntimeError(
                f"Partie non terminée après {max_coups} coups (boucle infinie ?)."
            )
        return gagnant
