"""Résolution du doublon : "qui tape en premier".

Le moteur de jeu (moteur.py) ne sait pas COMMENT on détermine le premier
qui tape — il délègue ça à un ResolveurTape. Ça permet de brancher :

- un résolveur de simulation (bots avec un temps de réaction crédible),
  utilisé ici pour tester le moteur tout seul ;
- plus tard, un résolveur réseau qui reçoit, pour chaque appli/joueur, le
  délai mesuré localement entre le début de l'animation de dépose (le
  "reveal") et l'appui du joueur — chaque appli timecode son propre écart,
  ce qui évite de comparer des horloges murales entre appareils. Le
  résolveur réseau n'a alors qu'à choisir le délai le plus court reçu.

Dans les deux cas, l'interface exposée au moteur est la même :
`determiner_gagnant(eligibles) -> Joueur`.
"""
from __future__ import annotations

import math
import random
from typing import TYPE_CHECKING, Dict, List, Optional

if TYPE_CHECKING:
    from .joueur import Joueur


class ResolveurTape:
    """Interface : détermine qui remporte le pli lors d'un doublon.

    Tous les joueurs sont éligibles, même ceux sans carte en main (ils
    peuvent taper pour revenir en jeu).
    """

    def determiner_gagnant(self, eligibles: List["Joueur"]) -> "Joueur":
        raise NotImplementedError


class ProfilReflexe:
    """Modélise le temps de réaction d'un bot pour qu'il reste crédible
    face à un humain (loi log-normale : asymétrique à droite, comme les
    vrais temps de réaction visuo-moteurs humains).

    temps_moyen_ms : temps de réaction "typique" du profil (~250 ms pour
        un humain moyen face à un stimulus visuel simple).
    variabilite : dispersion (sigma de la log-normale).
    temps_min_ms : plancher physiologique, pour éviter un bot inhumainement
        rapide.
    """

    def __init__(
        self,
        temps_moyen_ms: float = 250.0,
        variabilite: float = 0.25,
        temps_min_ms: float = 120.0,
    ):
        self.temps_moyen_ms = temps_moyen_ms
        self.variabilite = variabilite
        self.temps_min_ms = temps_min_ms

    def tirer_temps_reaction_ms(self, rng: random.Random) -> float:
        mu = math.log(self.temps_moyen_ms)
        t = rng.lognormvariate(mu, self.variabilite)
        return max(t, self.temps_min_ms)


class ResolveurSimulationBots(ResolveurTape):
    """Résolveur utilisé pour faire tourner/tester le moteur seul, sans
    joueurs humains : chaque bot "réagit" selon son ProfilReflexe, et le
    temps le plus court gagne — exactement comme le fera plus tard le
    résolveur réseau avec de vrais délais mesurés côté client.
    """

    def __init__(
        self,
        profils: Optional[Dict[str, ProfilReflexe]] = None,
        seed: Optional[int] = None,
    ):
        self.profils = profils or {}
        self.profil_defaut = ProfilReflexe()
        self.rng = random.Random(seed)

    def determiner_gagnant(self, eligibles: List["Joueur"]) -> "Joueur":
        temps_par_joueur = {
            j: self.profils.get(j.nom, self.profil_defaut).tirer_temps_reaction_ms(self.rng)
            for j in eligibles
        }
        return min(temps_par_joueur, key=temps_par_joueur.get)
