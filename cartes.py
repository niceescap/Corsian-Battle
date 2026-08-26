"""Cartes et paquet pour la Bataille Corse.

Paquet standard de 52 cartes (As à Roi, sans joker). Le rang est ce qui
compte pour les règles du jeu ; la couleur ne sert qu'à distinguer les
cartes et à retrouver l'asset visuel correspondant.

Chaque carte expose un `code` façon poker (ex: "AH", "KC", "TH", "9S",
"7D") destiné à retrouver l'image PNG personnalisée correspondante :
rang (A,2..9,T,J,Q,K) + couleur (S,H,D,C).
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path
from typing import List

TAILLE_PAQUET = 52
EXTENSION_IMAGE = "png"

# Couleurs identifiées par leur lettre poker : Pique, Cœur, Carreau, Trèfle.
COULEURS = ("S", "H", "D", "C")

SYMBOLES_COULEUR = {
    "S": "♠",
    "H": "♥",
    "D": "♦",
    "C": "♣",
}

NOMS_COULEUR = {
    "S": "Pique",
    "H": "Cœur",
    "D": "Carreau",
    "C": "Trèfle",
}


class Rang(IntEnum):
    AS = 1
    DEUX = 2
    TROIS = 3
    QUATRE = 4
    CINQ = 5
    SIX = 6
    SEPT = 7
    HUIT = 8
    NEUF = 9
    DIX = 10
    VALET = 11
    DAME = 12
    ROI = 13


NOMS_RANG = {
    Rang.AS: "As",
    Rang.VALET: "Valet",
    Rang.DAME: "Dame",
    Rang.ROI: "Roi",
}

# Code poker du rang : A, 2..9, T (dix), J, Q, K.
CODES_RANG = {
    Rang.AS: "A",
    Rang.DEUX: "2",
    Rang.TROIS: "3",
    Rang.QUATRE: "4",
    Rang.CINQ: "5",
    Rang.SIX: "6",
    Rang.SEPT: "7",
    Rang.HUIT: "8",
    Rang.NEUF: "9",
    Rang.DIX: "T",
    Rang.VALET: "J",
    Rang.DAME: "Q",
    Rang.ROI: "K",
}

# Barème du nombre de "cartes-chances" accordées au joueur suivant
# lorsqu'une figure sort.
BAREME_FIGURES = {
    Rang.AS: 4,
    Rang.ROI: 3,
    Rang.DAME: 2,
    Rang.VALET: 1,
}


@dataclass(frozen=True, slots=True)
class Carte:
    rang: Rang
    couleur: str  # "S", "H", "D" ou "C"

    @property
    def est_figure(self) -> bool:
        return self.rang in BAREME_FIGURES

    @property
    def chances(self) -> int:
        """Nombre de cartes-chances si la carte est une figure, sinon 0."""
        return BAREME_FIGURES.get(self.rang, 0)

    @property
    def code(self) -> str:
        """Code façon poker, ex: 'AH', 'KC', 'TH', '9S', '7D'.
        Sert d'identifiant pour retrouver l'asset PNG correspondant."""
        return f"{CODES_RANG[self.rang]}{self.couleur}"

    @property
    def libelle(self) -> str:
        """Libellé lisible en français, ex: 'Roi de Pique', '7 de Cœur'."""
        nom = NOMS_RANG.get(self.rang, str(int(self.rang)))
        return f"{nom} de {NOMS_COULEUR[self.couleur]}"

    def nom_fichier(self, extension: str = EXTENSION_IMAGE) -> str:
        """Nom de fichier de l'asset, ex: 'AH.png'."""
        return f"{self.code}.{extension}"

    def chemin_image(self, dossier_assets: str | Path, extension: str = EXTENSION_IMAGE) -> Path:
        """Chemin complet vers l'asset PNG de la carte dans `dossier_assets`."""
        return Path(dossier_assets) / self.nom_fichier(extension)

    def __repr__(self) -> str:
        return self.code


# Le dos de carte est unique et commun à toutes les cartes (il ne dépend
# ni du rang ni de la couleur) : utile pour l'affichage des tas cachés.
NOM_BASE_DOS = "back"


def chemin_dos(dossier_assets: str | Path, extension: str = EXTENSION_IMAGE) -> Path:
    """Chemin vers l'asset du dos de carte, ex: dossier_assets/back.png."""
    return Path(dossier_assets) / f"{NOM_BASE_DOS}.{extension}"


def construire_paquet(rng: random.Random) -> List[Carte]:
    """Construit un paquet de 52 cartes mélangé (mélange rigoureux)."""
    paquet = [Carte(Rang(r), c) for c in COULEURS for r in range(1, 14)]
    rng.shuffle(paquet)
    assert len(paquet) == TAILLE_PAQUET
    return paquet
