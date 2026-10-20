"""Tests du résolveur réseau — « qui tape le premier ».

Vérifie le contrat de `docs/PROTOCOLE.md` §10.2 : plus petit délai plausible,
plancher physiologique, rejet sous 100 ms, refus hors fenêtre, premier envoi
seul retenu, égalité départagée par l'ordre d'arrivée, et le cas
« personne n'a tapé » qui renvoie `None`.

    python3 -m pytest serveur/tests/test_resolveur_reseau.py
    python3 serveur/tests/test_resolveur_reseau.py
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from bataille_corse.joueur import Joueur  # noqa: E402
from serveur.jeu.resolveur_reseau import (  # noqa: E402
    FENETRE_MS,
    PLANCHER_MS,
    REFUS_MS,
    ResolveurTapeReseau,
)


def _joueurs(*noms: str) -> List[Joueur]:
    return [Joueur(nom) for nom in noms]


def test_le_plus_petit_delai_gagne():
    r = ResolveurTapeReseau()
    r.enregistrer("A", 310.0)
    r.enregistrer("B", 214.0)
    r.enregistrer("C", 480.0)
    gagnant = r.determiner_gagnant(_joueurs("A", "B", "C"))
    assert gagnant is not None and gagnant.nom == "B"
    assert r.verdict is not None and r.verdict.personne is False
    assert r.verdict.delai_gagnant_ms == 214.0


def test_personne_na_tape_renvoie_none():
    r = ResolveurTapeReseau()
    assert r.determiner_gagnant(_joueurs("A", "B")) is None
    assert r.verdict is not None and r.verdict.personne is True
    assert r.verdict.gagnant_nom is None


def test_delai_impossible_rejete_et_signale():
    r = ResolveurTapeReseau()
    accepte, motif = r.enregistrer("A", 42.0)
    assert accepte is False and motif == "delai_impossible"
    r.enregistrer("B", 250.0)
    assert r.determiner_gagnant(_joueurs("A", "B")).nom == "B"
    assert r.suspicions() == [("A", "delai_impossible")]


def test_sous_plancher_ne_gagne_pas_contre_un_delai_sain():
    r = ResolveurTapeReseau()
    accepte, motif = r.enregistrer("A", 110.0)          # entre 100 et 120 ms
    assert accepte is True and motif == "delai_sous_plancher"
    r.enregistrer("B", 250.0)
    assert r.determiner_gagnant(_joueurs("A", "B")).nom == "B"


def test_sous_plancher_gagne_s_il_est_seul():
    r = ResolveurTapeReseau()
    r.enregistrer("A", 110.0)
    assert r.determiner_gagnant(_joueurs("A", "B")).nom == "A"


def test_hors_fenetre_refuse():
    r = ResolveurTapeReseau()
    accepte, motif = r.enregistrer("A", FENETRE_MS + 1)
    assert accepte is False and motif == "hors_fenetre"
    assert r.determiner_gagnant(_joueurs("A")) is None


def test_seul_le_premier_envoi_compte():
    r = ResolveurTapeReseau()
    assert r.enregistrer("A", 400.0)[0] is True
    assert r.enregistrer("A", 101.0) == (False, "deja_envoye")
    assert r.determiner_gagnant(_joueurs("A")).nom == "A"
    assert r.verdict.delai_gagnant_ms == 400.0


def test_egalite_departagee_par_ordre_arrivee():
    r = ResolveurTapeReseau()
    r.enregistrer("B", 200.0)
    r.enregistrer("A", 200.0)
    assert r.determiner_gagnant(_joueurs("A", "B")).nom == "B"


def test_delais_invalides():
    r = ResolveurTapeReseau()
    assert r.enregistrer("A", "abc") == (False, "delai_invalide")
    assert r.enregistrer("B", None) == (False, "delai_invalide")
    assert r.enregistrer("C", float("nan")) == (False, "delai_invalide")
    assert r.enregistrer("D", -5) == (False, "delai_invalide")
    assert r.determiner_gagnant(_joueurs("A", "B", "C", "D")) is None


def test_cloture_refuse_les_tapes_tardives():
    r = ResolveurTapeReseau()
    r.enregistrer("A", 250.0)
    r.cloturer()
    assert r.enregistrer("B", 150.0) == (False, "fenetre_close")
    assert r.determiner_gagnant(_joueurs("A", "B")).nom == "A"


def test_reinitialisation():
    r = ResolveurTapeReseau()
    r.enregistrer("A", 250.0)
    r.determiner_gagnant(_joueurs("A"))
    r.reinitialiser()
    assert r.nb_retenu() == 0
    assert r.anomalies == {}
    assert r.verdict is None
    assert r.enregistrer("A", 180.0)[0] is True


def test_joueur_parti_non_eligible_est_ignorer():
    """Un `tape` reçu d'un siège qui n'est plus éligible ne doit rien casser."""
    r = ResolveurTapeReseau()
    r.enregistrer("Fantome", 150.0)
    r.enregistrer("A", 300.0)
    gagnant = r.determiner_gagnant(_joueurs("A"))
    assert gagnant is not None and gagnant.nom == "A"


def test_seuils_conformes_a_la_spec():
    assert (REFUS_MS, PLANCHER_MS, FENETRE_MS) == (100.0, 120.0, 900.0)
    r = ResolveurTapeReseau(fenetre_ms=500.0)
    assert r.enregistrer("A", 600.0)[0] is False


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
