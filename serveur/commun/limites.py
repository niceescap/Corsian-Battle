"""Limiteur de débit glissant, en mémoire.

Un seul worker par service (`docs/DEPLOIEMENT.md` §4) : un compteur en
mémoire suffit, aucun Redis nécessaire. En contrepartie, les compteurs sont
perdus au redémarrage — acceptable pour une protection anti-abus.

Deux usages :
- **REST** : `Limiteur(5, 3600)` par IP sur `/invite`, `(5, 900)` sur
  `/connexion`, etc. (`docs/ENDPOINTS.md` §5).
- **WebSocket** : `Limiteur(20, 2.0)` par socket, soit ~10 messages/s avec
  une rafale autorisée de 20 (`docs/PROTOCOLE.md` §13).

Le dictionnaire est purgé paresseusement à chaque appel et explicitement par
`nettoyer()` (appelé périodiquement par le service de jeu) pour ne pas
conserver indéfiniment les clés d'IP ou de sockets disparus.
"""
from __future__ import annotations

import time
from collections import defaultdict, deque
from typing import Deque, Dict, Tuple


class Limiteur:
    def __init__(self, max_coups: int, fenetre_s: float) -> None:
        if max_coups < 1:
            raise ValueError("max_coups doit valoir au moins 1")
        if fenetre_s <= 0:
            raise ValueError("fenetre_s doit être strictement positive")
        self.max_coups = max_coups
        self.fenetre_s = float(fenetre_s)
        self._coups: Dict[str, Deque[float]] = defaultdict(deque)

    def _purger(self, file: Deque[float], instant: float) -> None:
        while file and instant - file[0] >= self.fenetre_s:
            file.popleft()

    def autorise(self, cle: str, maintenant: float | None = None) -> Tuple[bool, int]:
        """Renvoie `(autorisé, retry_after_s)`.

        Un coup refusé n'est **pas** enregistré : la fenêtre glisse donc bien
        à partir du premier coup accepté, sans pénalité cumulative.
        """
        instant = time.time() if maintenant is None else maintenant
        file = self._coups[cle]
        self._purger(file, instant)
        if len(file) >= self.max_coups:
            attendre = self.fenetre_s - (instant - file[0])
            return False, max(int(attendre) + 1, 1)
        file.append(instant)
        return True, 0

    def nettoyer(self, maintenant: float | None = None) -> int:
        """Supprime les clés vides. Renvoie le nombre de clés retirées."""
        instant = time.time() if maintenant is None else maintenant
        retirees = 0
        for cle in list(self._coups):
            self._purger(self._coups[cle], instant)
            if not self._coups[cle]:
                del self._coups[cle]
                retirees += 1
        return retirees

    def restant(self, cle: str, maintenant: float | None = None) -> int:
        """Nombre de coups encore autorisés dans la fenêtre courante."""
        instant = time.time() if maintenant is None else maintenant
        file = self._coups.get(cle)
        if not file:
            return self.max_coups
        self._purger(file, instant)
        return max(self.max_coups - len(file), 0)
