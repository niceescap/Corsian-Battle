"""Tests de non-régression du moteur de règles.

Le moteur Python est **l'autorité** du jeu en ligne (`docs/ARCHITECTURE.md` §6) :
ces tests verrouillent les règles déjà validées sur téléphone — barème des
figures, répondeur unique qui pose toutes ses chances, rebond au barème plein
non cumulatif, doublon prioritaire absolu même en plein défi, joueur sans carte
qui peut taper, reste neutre intégré au premier pli — **et** le nouveau cas
« personne n'a tapé » introduit pour le réseau.

    python3 -m pytest serveur/tests/test_moteur_nonregression.py
    python3 serveur/tests/test_moteur_nonregression.py
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import List, Optional, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from bataille_corse.cartes import CODES_RANG, TAILLE_PAQUET, Carte, Rang  # noqa: E402
from bataille_corse.joueur import Joueur  # noqa: E402
from bataille_corse.moteur import BatailleCorse  # noqa: E402
from bataille_corse.resolveur_tape import (  # noqa: E402
    ResolveurSimulationBots,
    ResolveurTape,
)

_RANG_PAR_CODE = {code: rang for rang, code in CODES_RANG.items()}


def _carte(code: str) -> Carte:
    """`'AH'`, `'5S'`, `'TD'` → Carte. Même code poker que les assets PNG."""
    return Carte(_RANG_PAR_CODE[code[0]], code[1])


def _tas(codes: Sequence[str]) -> List[Carte]:
    return [_carte(code) for code in codes]


class ResolveurPersonne(ResolveurTape):
    """Personne ne tape : le doublon doit passer sans attribuer le pli."""

    def determiner_gagnant(self, eligibles: List[Joueur]) -> Optional[Joueur]:
        return None


class ResolveurChoisi(ResolveurTape):
    """Désigne un gagnant fixe et compte les appels (tests d'attribution)."""

    def __init__(self, nom: str) -> None:
        self.nom = nom
        self.appels = 0

    def determiner_gagnant(self, eligibles: List[Joueur]) -> Optional[Joueur]:
        self.appels += 1
        for joueur in eligibles:
            if joueur.nom == self.nom:
                return joueur
        return None


def _partie(
    tas: Sequence[Sequence[str]],
    resolveur: ResolveurTape,
    seed: int = 1,
) -> BatailleCorse:
    """Construit une partie dont les tas sont imposés, pour tester une règle
    précise sans dépendre du mélange. Les joueurs s'appellent A, B, C…"""
    noms = [chr(ord("A") + i) for i in range(len(tas))]
    jeu = BatailleCorse(noms, resolveur_tape=resolveur, seed=seed)
    for joueur, codes in zip(jeu.joueurs, tas):
        joueur.tas.clear()
        for carte in _tas(codes):
            joueur.tas.append(carte)
    jeu.pli.clear()
    jeu.cartes_reste_neutres.clear()
    jeu.defi_en_cours = None
    jeu.index_courant = 0
    jeu.historique.clear()
    return jeu


# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------
def test_distribution_a_deux():
    jeu = BatailleCorse(["A", "B"], seed=5)
    assert [j.nombre_cartes() for j in jeu.joueurs] == [26, 26]
    assert jeu.cartes_reste_neutres == []


def test_distribution_a_trois_laisse_un_reste_neutre():
    jeu = BatailleCorse(["A", "B", "C"], seed=5)
    assert [j.nombre_cartes() for j in jeu.joueurs] == [17, 17, 17]
    assert len(jeu.cartes_reste_neutres) == 1


def test_reste_neutre_integre_au_premier_pli():
    jeu = BatailleCorse(["A", "B", "C"], resolveur_tape=ResolveurChoisi("A"), seed=7)
    assert len(jeu.cartes_reste_neutres) == 1
    for joueur, codes in zip(jeu.joueurs, (["5S"], ["5H"], ["9C"])):
        joueur.tas.clear()
        joueur.tas.extend(_tas(codes))
    jeu.pli.clear()
    jeu.index_courant = 0
    jeu.jouer_un_coup()          # A pose 5S
    jeu.jouer_un_coup()          # B pose 5H → doublon → A tape
    assert jeu.cartes_reste_neutres == []
    assert jeu.joueurs[0].nombre_cartes() == 3      # 5S + 5H + la carte neutre
    assert jeu.joueurs[1].nombre_cartes() == 0


# ---------------------------------------------------------------------------
# Défis
# ---------------------------------------------------------------------------
def test_figure_ouvre_le_defi_avec_le_bareme():
    for code, attendu in (("AH", 4), ("KS", 3), ("QD", 2), ("JC", 1)):
        jeu = _partie([[code, "2S"], ["5H", "6D"]], ResolveurPersonne())
        jeu.jouer_un_coup()
        assert jeu.defi_en_cours is not None, code
        assert jeu.defi_en_cours.chances_restantes == attendu, code
        assert jeu.defi_en_cours.proprietaire.nom == "A", code
        assert jeu.index_courant == 1, code          # seul le suivant répond
        assert _carte(code).chances == attendu, code


def test_le_repondeur_pose_toutes_ses_chances_d_affilee():
    jeu = _partie(
        [["AH", "2S"], ["5H", "6D", "7S", "8C", "9H"]], ResolveurPersonne()
    )
    jeu.jouer_un_coup()                              # A pose l'As → 4 chances
    assert jeu.index_courant == 1
    for attendu in (3, 2, 1):
        jeu.jouer_un_coup()
        assert jeu.defi_en_cours is not None
        assert jeu.defi_en_cours.chances_restantes == attendu
        assert jeu.index_courant == 1, "le tour ne doit pas tourner pendant le défi"
    jeu.jouer_un_coup()                              # 4e carte : défi manqué
    assert jeu.defi_en_cours is None
    assert jeu.pli == []


def test_defi_manque_attribue_le_pli_au_dernier_poseur_de_figure():
    jeu = _partie(
        [["AH", "2S"], ["5H", "6D", "7S", "8C", "9H"]], ResolveurPersonne()
    )
    for _ in range(5):
        jeu.jouer_un_coup()
    assert jeu.joueurs[0].nombre_cartes() == 6       # 2S + les 5 cartes du pli
    assert jeu.joueurs[1].nombre_cartes() == 1       # 9H
    assert jeu.index_courant == 0                    # le gagnant relance
    assert any("Défi manqué" in ligne for ligne in jeu.historique)


def test_rebond_au_bareme_plein_non_cumulatif():
    jeu = _partie([["AH", "2S"], ["KH", "3D", "4S"]], ResolveurPersonne())
    jeu.jouer_un_coup()                              # A pose l'As → 4 chances
    jeu.jouer_un_coup()                              # B sort le Roi → rebond
    assert jeu.defi_en_cours is not None
    assert jeu.defi_en_cours.proprietaire.nom == "B"
    assert jeu.defi_en_cours.chances_restantes == 3, "barème du Roi, pas 4 + 3"
    assert jeu.index_courant == 0                    # A devient le répondeur


def test_repondeur_a_court_de_cartes_clot_le_defi():
    jeu = _partie([["AH", "2S"], ["5H"]], ResolveurPersonne())
    jeu.jouer_un_coup()                              # défi(A, 4)
    jeu.jouer_un_coup()                              # B pose 5H, n'a plus rien
    assert jeu.defi_en_cours is None
    assert jeu.joueurs[0].nombre_cartes() == 3       # 2S + AH + 5H
    assert jeu.joueurs[1].nombre_cartes() == 0


# ---------------------------------------------------------------------------
# Doublon
# ---------------------------------------------------------------------------
def test_doublon_prioritaire_meme_en_plein_defi():
    resolveur = ResolveurChoisi("B")
    jeu = _partie([["AH", "5S", "5H", "9C"], ["KH", "3D", "4S"]], resolveur)
    jeu.jouer_un_coup()                              # AH → défi(A, 4)
    jeu.jouer_un_coup()                              # KH → rebond défi(B, 3)
    jeu.jouer_un_coup()                              # A pose 5S → 2 chances
    assert jeu.defi_en_cours.chances_restantes == 2
    jeu.jouer_un_coup()                              # A pose 5H → DOUBLON
    assert resolveur.appels == 1
    assert jeu.pli == []
    assert jeu.defi_en_cours is None, "le doublon efface le défi en cours"
    assert jeu.joueurs[1].nombre_cartes() == 6       # 3D, 4S + les 4 cartes du pli
    assert jeu.joueurs[0].nombre_cartes() == 1       # 9C
    assert jeu.index_courant == 1


def test_doublon_non_tape_laisse_passer_le_pli():
    """Cas introduit pour le réseau : personne ne tape, le jeu continue."""
    jeu = _partie([["AH", "5S", "5H", "9C"], ["KH", "3D", "4S"]], ResolveurPersonne())
    for _ in range(3):
        jeu.jouer_un_coup()
    assert jeu.defi_en_cours is not None
    jeu.jouer_un_coup()                              # 5H après 5S : doublon ignoré
    assert len(jeu.pli) == 4, "le pli ne doit être attribué à personne"
    assert jeu.joueurs[1].nombre_cartes() == 2, "B n'a rien gagné"
    assert jeu.joueurs[0].nombre_cartes() == 1
    assert jeu.defi_en_cours is not None
    assert jeu.defi_en_cours.chances_restantes == 1, "la carte a consommé une chance"
    assert jeu.index_courant == 0
    assert any("Doublon non tapé" in ligne for ligne in jeu.historique)


def test_joueur_sans_carte_peut_taper_pour_revenir_en_jeu():
    resolveur = ResolveurChoisi("A")
    jeu = _partie([["5S"], ["5H", "9C"]], resolveur)
    jeu.jouer_un_coup()                              # A pose son unique carte
    assert jeu.joueurs[0].nombre_cartes() == 0
    jeu.jouer_un_coup()                              # B pose 5H → doublon
    assert jeu.joueurs[0].nombre_cartes() == 2, "A revient en jeu en tapant"
    assert jeu.joueurs[1].nombre_cartes() == 1
    assert jeu.index_courant == 0


def test_la_simulation_ne_conclut_jamais_a_personne():
    """Garantie de rétrocompatibilité : `demo.py` et les simulations existantes
    conservent un comportement strictement identique."""
    resolveur = ResolveurSimulationBots(seed=3)
    jeu = BatailleCorse(["A", "B"], resolveur_tape=resolveur, seed=3)
    for _ in range(20):
        assert resolveur.determiner_gagnant(jeu.joueurs) is not None


# ---------------------------------------------------------------------------
# Intégrité globale
# ---------------------------------------------------------------------------
def test_determinisme_a_seed_identique():
    def derouler(seed: int) -> List[str]:
        jeu = BatailleCorse(["A", "B", "C", "D"], seed=seed)
        for _ in range(40):
            if jeu.gagnant_final() is not None:
                break
            jeu.jouer_un_coup()
        return list(jeu.historique)

    assert len(derouler(42)) > 5
    assert derouler(42) == derouler(42)
    assert derouler(42) != derouler(43)


def test_partie_complete_conserve_les_52_cartes():
    jeu = BatailleCorse(["A", "B", "C", "D"], seed=11)
    try:
        gagnant = jeu.jouer_partie(max_coups=200000)
    except RuntimeError:
        gagnant = None      # boucle infinie détectée : cas prévu (« partie nulle »)
    total = sum(j.nombre_cartes() for j in jeu.joueurs) + len(jeu.pli)
    assert total == TAILLE_PAQUET, "aucune carte ne doit apparaître ni disparaître"
    if gagnant is not None:
        assert gagnant.nombre_cartes() == TAILLE_PAQUET


def test_garde_fou_de_boucle_infinie():
    """Ni figure ni doublon possible : la partie ne peut pas se terminer."""
    jeu = _partie([["2S", "3H"], ["4D", "5C"]], ResolveurPersonne())
    try:
        jeu.jouer_partie(max_coups=200)
    except RuntimeError:
        return
    raise AssertionError("le garde-fou de boucle infinie n'a pas tranché")


if __name__ == "__main__":
    echecs = 0
    for nom, fonction in sorted(list(globals().items())):
        if nom.startswith("test_") and callable(fonction):
            try:
                fonction()
                print(f"ok    {nom}")
            except AssertionError as erreur:
                echecs += 1
                print(f"ECHEC {nom} : {erreur or 'assertion'}")
    print(f"\n{echecs} échec(s).")
    sys.exit(1 if echecs else 0)
