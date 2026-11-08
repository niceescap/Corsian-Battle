"""Tests du filtre de pseudo (`serveur/commun/pseudo.py`).

Lançables avec pytest **ou** seuls, sans aucune dépendance :

    python3 -m pytest serveur/tests/test_pseudo.py
    python3 serveur/tests/test_pseudo.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from serveur.commun import pseudo as filtre  # noqa: E402


# ---------------------------------------------------------------------------
# Acceptations
# ---------------------------------------------------------------------------
def test_pseudo_simple():
    net, code = filtre.valider("Nina")
    assert code is None
    assert net == "Nina"


def test_espaces_encadrants_reduits():
    net, code = filtre.valider("   Nina   ")
    assert code is None
    assert net == "Nina"


def test_accentues_tirets_points():
    for brut in ("Élodie", "Jean-Luc", "N.42", "André_2B", "Zoé"):
        net, code = filtre.valider(brut)
        assert code is None, f"{brut} refusé à tort ({code})"
        assert net == brut


def test_longueur_maximale_acceptee():
    net, code = filtre.valider("A" * filtre.LONGUEUR_MAX)
    assert code is None
    assert len(net) == filtre.LONGUEUR_MAX


def test_faux_positifs_evites():
    """« con » est un terme court : il ne doit être refusé que mot à mot.

    Sans cette règle, « Second », « Facond » ou « Concombre » seraient rejetés.
    """
    for brut in ("Second", "Facond", "Concombre", "Condor"):
        net, code = filtre.valider(brut)
        assert code is None, f"{brut} refusé à tort ({code})"


# ---------------------------------------------------------------------------
# Refus de forme
# ---------------------------------------------------------------------------
def test_trop_court():
    assert filtre.valider("A")[1] == "pseudo_trop_court"


def test_trop_long():
    assert filtre.valider("A" * (filtre.LONGUEUR_MAX + 1))[1] == "pseudo_trop_long"


def test_vide_et_non_chaine():
    assert filtre.valider("")[1] == "pseudo_vide"
    assert filtre.valider("    ")[1] == "pseudo_vide"
    assert filtre.valider(None)[1] == "pseudo_vide"
    assert filtre.valider(42)[1] == "pseudo_vide"


def test_caracteres_refuses():
    assert filtre.valider("Nina⭐")[1] == "caracteres_refuses"
    assert filtre.valider("Nina!")[1] == "caracteres_refuses"
    assert filtre.valider("Nina/42")[1] == "caracteres_refuses"


def test_sans_lettre():
    assert filtre.valider("4242")[1] == "pseudo_sans_lettre"
    assert filtre.valider("12-34")[1] == "pseudo_sans_lettre"


def test_coordonnees_refusees():
    # `@` tombe d'abord sur le jeu de caractères restreint : peu importe lequel
    # des deux codes sort, l'important est que ce soit refusé.
    assert filtre.valider("nina@mail.com")[1] in (
        "caracteres_refuses",
        "pseudo_contient_coordonnees",
    )
    assert filtre.valider("nina.fr")[1] == "pseudo_contient_coordonnees"
    assert filtre.valider("http-nina")[1] == "pseudo_contient_coordonnees"


# ---------------------------------------------------------------------------
# Termes interdits et contournements
# ---------------------------------------------------------------------------
def test_interdit_simple():
    assert filtre.valider("connard")[1] == "pseudo_interdit"
    assert filtre.valider("FUCK")[1] == "pseudo_interdit"


def test_interdit_en_mot_compose():
    assert filtre.valider("Le Con")[1] == "pseudo_interdit"
    assert filtre.valider("Admin")[1] == "pseudo_interdit"


def test_contournement_par_separateurs():
    assert filtre.valider("C.O.N")[1] == "pseudo_interdit"
    assert filtre.valider("c o n n a r d")[1] == "pseudo_interdit"


def test_interdit_long_detecte_en_sous_chaine():
    # « saloperie » contient « salope » (terme long) : refusé.
    assert filtre.valider("saloperie")[1] == "pseudo_interdit"


def test_complement_par_environnement():
    os.environ["PSEUDO_INTERDITS"] = "zorglub"
    try:
        assert filtre.valider("Zorglub")[1] == "pseudo_interdit"
        assert filtre.valider("Nina")[1] is None
    finally:
        del os.environ["PSEUDO_INTERDITS"]
    assert filtre.valider("Zorglub")[1] is None


# ---------------------------------------------------------------------------
# Clé d'unicité
# ---------------------------------------------------------------------------
def test_cle_uniq_neutralise_casse_et_accents():
    assert filtre.pseudo_min("Élodie") == filtre.pseudo_min("elodie") == "elodie"
    assert filtre.pseudo_min("Jean-Luc") == filtre.pseudo_min("JEAN LUC") == "jeanluc"
    assert filtre.pseudo_min("Nina") != filtre.pseudo_min("Nino")


def test_variante_libre_propose_un_pseudo_libre():
    """En multijoueur, deux joueurs ont le même pseudo par défaut.

    Le serveur doit donc proposer une **variante** au lieu de refuser
    sèchement : un refus sans alternative est un cul-de-sac pour le joueur.
    """
    pris = set()

    def deja_pris(cle):
        return cle in pris

    # Pseudo totalement libre : c'est le pseudo lui-même qui est renvoyé ?
    # Non : la variante en propose toujours une dérivée, pour éviter une
    # collision avec un joueur qui s'inscrirait entre-temps.
    assert filtre.variante_libre("YOU", deja_pris) == "YOU2"

    pris.add(filtre.pseudo_min("YOU2"))
    assert filtre.variante_libre("YOU", deja_pris) == "YOU3"


def test_variante_libre_respecte_le_filtre():
    """La variante proposée doit être un pseudo **valide**.

    Elle ne doit donc contourner ni la longueur maximale, ni la liste des
    termes interdits : c'est la modération qui reste garantie.
    """
    # Pseudo de longueur maximale : la variante doit être tronquée pour
    # garder le suffixe qui fait l'unicité.
    variante = filtre.variante_libre("A" * 20, lambda cle: False)
    assert variante is not None
    assert len(variante) <= filtre.LONGUEUR_MAX
    assert variante.endswith("2")

    # Un pseudo interdit doit produire une variante *valide* : le filtre
    # la rejette si elle reste interdite.
    variante = filtre.variante_libre("con", lambda cle: False)
    assert variante is not None
    assert filtre.valider(variante)[1] is None, (
        "la variante proposée doit être acceptée par le filtre"
    )


def test_variante_libre_accepte_une_casse_differente():
    """La clé d'unicité neutralise casse et accents.

    `Élodie` et `elodie` sont la même personne : la variante doit le voir.
    """
    def deja_pris(cle):
        return cle == filtre.pseudo_min("Élodie")

    variante = filtre.variante_libre("elodie", deja_pris)
    assert variante is not None
    assert variante != "elodie"


def test_messages_derreur_tous_renseignes():
    for code in filtre.MESSAGES:
        assert filtre.message_erreur(code)
    assert filtre.message_erreur("inconnu")


if __name__ == "__main__":
    echecs = 0
    for nom, fonction in sorted(list(globals().items())):
        if nom.startswith("test_") and callable(fonction):
            try:
                fonction()
                print(f"ok    {nom}")
            except AssertionError as erreur:
                echecs += 1
                print(f"ECHEC {nom} : {erreur}")
    print(f"\n{echecs} échec(s).")
    sys.exit(1 if echecs else 0)
