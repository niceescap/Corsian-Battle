"""Traduction d'un coup de moteur en événements diffusables.

`bataille_corse.moteur.BatailleCorse.jouer_un_coup()` applique les règles mais
ne produit aucun événement structuré : il n'alimente que `self.historique`,
des phrases destinées aux humains. Deux options étaient ouvertes
(`docs/ARCHITECTURE.md` §6.2) — un crochet dans le moteur, ou la comparaison
d'état avant/après. **C'est la comparaison qui est implémentée ici** : le moteur
reste une bibliothèque pure, synchrone et sans E/S, et `demo.py` tourne à
l'identique.

Convention importante : tous les entiers de ce module sont des **index moteur**
(l'ordre des `Joueur` passés à la construction). La traduction en numéros de
siège est faite par `PartieEnLigne`, qui connaît l'ordre réel des sièges
occupés.

Rien d'interdit ne sort d'ici : les champs produits sont ceux de
`docs/PROTOCOLE.md` §5.2. La carte du dessus d'un joueur est lue par
`carte_du_dessus()` mais n'est diffusée qu'à son propriétaire (message privé
`ta_carte_suivante`).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

TAILLE_PAQUET_ATTENDUE = 52

# Champs d'un événement dont la valeur est un index moteur à traduire.
CHAMPS_INDEX = ("siege", "poseur", "repondeur", "nouveau_poseur", "gagnant", "suivant")


@dataclass(frozen=True)
class Etat:
    """Photographie de tout ce qui est observable dans le moteur."""

    index_courant: int
    tailles: Tuple[int, ...]
    pli: Tuple[str, ...]           # codes poker, dans l'ordre de pose
    reste_neutre: int
    defi_poseur: Optional[int]
    defi_chances: int

    @staticmethod
    def capturer(jeu: Any) -> "Etat":
        poseur: Optional[int] = None
        chances = 0
        if jeu.defi_en_cours is not None:
            poseur = jeu.joueurs.index(jeu.defi_en_cours.proprietaire)
            chances = jeu.defi_en_cours.chances_restantes
        return Etat(
            index_courant=jeu.index_courant,
            tailles=tuple(joueur.nombre_cartes() for joueur in jeu.joueurs),
            pli=tuple(carte.code for carte in jeu.pli),
            reste_neutre=len(jeu.cartes_reste_neutres),
            defi_poseur=poseur,
            defi_chances=chances,
        )


def siege_effectif(jeu: Any, depuis: Optional[int] = None) -> Optional[int]:
    """Index du joueur qui jouera vraiment : saute les tas vides, exactement
    comme `_prochain_index_avec_cartes()` du moteur. `None` si plus personne
    n'a de carte (partie bloquée)."""
    depart = jeu.index_courant if depuis is None else depuis
    total = len(jeu.joueurs)
    for pas in range(total + 1):
        index = (depart + pas) % total
        if jeu.joueurs[index].a_des_cartes():
            return index
    return None


def carte_du_dessus(jeu: Any, index: int) -> Optional[str]:
    """Code poker de la carte du dessus d'un siège, ou `None` si tas vide."""
    tas = jeu.joueurs[index].tas
    return tas[0].code if len(tas) else None


def total_cartes(jeu: Any) -> int:
    """Invariant de conservation : doit toujours valoir 52."""
    return (
        sum(joueur.nombre_cartes() for joueur in jeu.joueurs)
        + len(jeu.pli)
        + len(jeu.cartes_reste_neutres)
    )


@dataclass
class Coup:
    """Résultat d'un coup, en index moteur. `evenements[0]` est `carte_posee`."""

    siege: int
    carte: str
    etait_doublon: bool
    tailles: Tuple[int, ...]
    suivant: Optional[int] = None
    defi: Optional[Dict[str, Any]] = None
    pli_gagne: Optional[Dict[str, Any]] = None
    doublon_non_tape: bool = False
    fini: bool = False
    gagnant: Optional[int] = None
    bloque: bool = False
    evenements: List[Dict[str, Any]] = field(default_factory=list)


def jouer_coup(
    jeu: Any, auto: bool = False, doublon_resolu: Optional[bool] = None
) -> Optional[Coup]:
    """Actionne le moteur une fois et traduit le changement d'état.

    Renvoie `None` si plus personne ne peut jouer avant même le coup (tas
    vides, pas de gagnant) : c'est la situation que le garde-fou du moteur
    tranche en `RuntimeError`, traitée ici en `partie_nulle`.

    `auto` marque le coup comme joué par le serveur à l'expiration du délai de
    tour (`docs/PROTOCOLE.md` §7.1) — l'app l'affiche par un pictogramme.

    `doublon_resolu` est le verdict de la fenêtre de tape, quand l'appelant la
    connaît (`True` = quelqu'un a tapé, `False` = personne) :

    - `True`  → le pli est attribué par la tape, raison `doublon` ;
    - `False` → événement `doublon_non_tape`, et si un pli tombe quand même sur
      ce coup c'est qu'un défi a échoué : raison `defi_manque` ;
    - `None`  → l'appelant ne sait pas (résolveur de simulation, tests) : on le
      déduit, un pli attribué sur un coup de doublon ne pouvant l'être que par
      la tape.

    Sans ce paramètre, un doublon **non tapé** qui fermait aussi un défi était
    étiqueté `doublon` alors que le pli revenait au poseur de figure : c'était
    exactement l'ambiguïté relevée en recette du lot A.
    """
    avant = Etat.capturer(jeu)
    index = siege_effectif(jeu, avant.index_courant)
    if index is None:
        return None
    carte = carte_du_dessus(jeu, index) or ""
    # Un doublon se reconnaît avant le coup : le rang de la carte du dessus
    # contre celui du sommet du pli (rangs portés par la 1re lettre du code).
    etait_doublon = bool(avant.pli) and bool(carte) and avant.pli[-1][0] == carte[0]

    jeu.jouer_un_coup()

    apres = Etat.capturer(jeu)
    coup = Coup(
        siege=index,
        carte=carte,
        etait_doublon=etait_doublon,
        tailles=apres.tailles,
        suivant=siege_effectif(jeu, apres.index_courant),
    )

    # --- défi -----------------------------------------------------------
    if apres.defi_poseur is not None:
        coup.defi = {
            "poseur": apres.defi_poseur,
            "repondeur": apres.index_courant,
            "chances_restantes": apres.defi_chances,
        }
        if avant.defi_poseur is None:
            coup.evenements.append(
                {
                    "type": "defi_ouvert",
                    "d": {
                        "poseur": apres.defi_poseur,
                        "repondeur": apres.index_courant,
                        "chances": apres.defi_chances,
                    },
                }
            )
        elif avant.defi_poseur != apres.defi_poseur:
            coup.evenements.append(
                {
                    "type": "defi_rebondit",
                    "d": {
                        "nouveau_poseur": apres.defi_poseur,
                        "repondeur": apres.index_courant,
                        "chances": apres.defi_chances,
                    },
                }
            )

    # --- pli attribué ou doublon passé ----------------------------------
    # Détection par le total des mains : un coup retire exactement une carte
    # d'une main, donc `delta >= 0` signifie qu'un pli (>= 1 carte) a été
    # redistribué. Le nombre de cartes gagnées vaut alors `delta + 1`, carte
    # posée pendant ce coup et reste neutre compris.
    delta_mains = sum(apres.tailles) - sum(avant.tailles)
    pli_attribue = delta_mains >= 0
    if pli_attribue:
        deltas = [b - a for a, b in zip(avant.tailles, apres.tailles)]
        gagnant = next((i for i, delta in enumerate(deltas) if delta > 0), None)
        if gagnant is None:
            # Cas limite : le poseur gagne un pli d'une seule carte (défi clos
            # immédiatement parce que personne d'autre n'a de carte) — il rend
            # d'un côté ce qu'il reçoit de l'autre, son delta vaut 0.
            gagnant = index
        nb_cartes = delta_mains + 1
        coup.pli_gagne = {
            "gagnant": gagnant,
            "nb_cartes": nb_cartes,
            "raison": "doublon" if etait_doublon else "defi_manque",
            "reste_neutre_inclus": avant.reste_neutre > 0 and apres.reste_neutre == 0,
        }
        coup.evenements.append({"type": "pli_gagne", "d": dict(coup.pli_gagne)})
    elif etait_doublon:
        # Doublon détecté, pli non attribué : personne n'a tapé (lot A : c'est
        # systématique ; lot B : seulement si la fenêtre s'est écoulée).
        coup.doublon_non_tape = True
        coup.evenements.append(
            {"type": "doublon_non_tape", "d": {"cartes": [avant.pli[-1], carte]}}
        )

    # --- carte posée, toujours en tête ----------------------------------
    coup.evenements.insert(
        0,
        {
            "type": "carte_posee",
            "d": {
                "siege": index,
                "carte": carte,
                "pli": len(apres.pli),
                "suivant": coup.suivant,
                "defi": coup.defi,
                "auto": auto,
            },
        },
    )

    # --- fin de partie ---------------------------------------------------
    gagnant_final = jeu.gagnant_final()
    if gagnant_final is not None:
        coup.fini = True
        coup.gagnant = jeu.joueurs.index(gagnant_final)
    coup.bloque = (not coup.fini) and coup.suivant is None
    return coup
