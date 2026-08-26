"""Représentation d'un joueur et de son tas de cartes.

Le tas est toujours face cachée. Le joueur n'a jamais le choix de la carte
jouée : c'est toujours celle du dessus (index 0 du tas). Aucun mélange ni
coupe n'est autorisé en cours de partie.
"""
from __future__ import annotations

from collections import deque
from typing import Deque, Iterable

from .cartes import Carte


class Joueur:
    def __init__(self, nom: str):
        self.nom = nom
        # index 0 = dessus du tas (prochaine carte jouée)
        self.tas: Deque[Carte] = deque()

    def a_des_cartes(self) -> bool:
        return len(self.tas) > 0

    def nombre_cartes(self) -> int:
        return len(self.tas)

    def jouer_carte_du_dessus(self) -> Carte:
        if not self.a_des_cartes():
            raise ValueError(f"{self.nom} n'a plus de cartes à jouer.")
        return self.tas.popleft()

    def recevoir_pli(self, cartes: Iterable[Carte]) -> None:
        """Les cartes gagnées sont remises face cachée SOUS le tas, dans
        l'ordre strict de ramassage."""
        self.tas.extend(cartes)

    def __repr__(self) -> str:
        return f"Joueur({self.nom!r}, {self.nombre_cartes()} cartes)"
