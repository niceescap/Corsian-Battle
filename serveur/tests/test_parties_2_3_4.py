"""Parties complètes à 2, 3 et 4 joueurs — distribution et roster exacts.

Le lancement doit figer le roster sur les sièges RÉELLEMENT connectés
(`Table.sieges_connectes()`), pas sur les sièges simplement réservés. Ce
fichier vérifie la distribution (26/26, 17/17/17 + 1 neutre, 13×4), le refus
d'un joueur seul, l'exclusion d'un siège vide et la conservation des 52
cartes sur une partie à 3 joueurs.

    PYTHONDONTWRITEBYTECODE=1 python3 serveur/tests/test_parties_2_3_4.py
"""
from __future__ import annotations

import asyncio
import json
import sys
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from bataille_corse.moteur import BatailleCorse  # noqa: E402
from serveur.commun.config import config_jeu  # noqa: E402
from serveur.jeu import evenements  # noqa: E402
from serveur.jeu.partie import PartieEnLigne  # noqa: E402
from serveur.jeu.resolveur_reseau import ResolveurTapeReseau  # noqa: E402
from serveur.jeu.table import ErreurTable, GestionnaireTables, Table  # noqa: E402

SOCKET = object()          # marqueur « siège réellement connecté »


class Collecteur:
    """Diffuseur de test : enregistre les messages au lieu de les envoyer."""

    def __init__(self) -> None:
        self.messages: List[Dict[str, Any]] = []

    async def __call__(self, table: Table, message: Dict[str, Any], vers=None) -> None:
        self.messages.append({"type": message.get("type"), "d": message.get("d"), "vers": vers})

    def du_type(self, type_: str) -> List[Dict[str, Any]]:
        return [message for message in self.messages if message["type"] == type_]


def _config(**reglages: Any):
    base = config_jeu()
    return replace(base, delai_tour_ms=600000, compte_a_rebours_s=0, **reglages)


def _table(type_partie: str, connectes: List[tuple], reserves: List[tuple] = ()) -> Table:
    """Table dont les sièges `connectes` ont une socket et les autres non.

    `reserves` représente les sièges attribués par REST mais jamais connectés :
    ils gardent un `joueur_id` et un pseudo, sans `present` ni socket.
    """
    gestionnaire = GestionnaireTables()
    table, _ = gestionnaire.creer(type_partie, "vide", "Vide")
    for siege in table.sieges:
        siege.joueur_id = None
        siege.pseudo = None
        siege.present = False
        siege.pret = False
        siege.websocket = None
    for numero, joueur_id, pseudo in connectes:
        siege = table.siege(numero)
        assert siege is not None
        siege.joueur_id = joueur_id
        siege.pseudo = pseudo
        siege.present = True
        siege.pret = False
        siege.websocket = SOCKET
    for numero, joueur_id, pseudo in reserves:
        siege = table.siege(numero)
        assert siege is not None
        siege.joueur_id = joueur_id
        siege.pseudo = pseudo
        siege.present = False
        siege.pret = False
        siege.websocket = None
    table.createur_id = connectes[0][1]
    return table


def _lancer(table: Table, seed: int = 1) -> tuple:
    async def scenario():
        from serveur.jeu import main as jeu_main

        publie = Collecteur()
        async def diffuser(tbl, message, vers=None, sauf=None):
            await publie(tbl, message, vers)

        async def envoyer(websocket, message):
            publie.messages.append({"type": message.get("type"), "d": message.get("d"), "vers": None})
            return True

        def construire(tbl, diffuseur, cfg, **kwargs):
            return PartieEnLigne(tbl, diffuseur, cfg, seed=seed, **kwargs)

        createur = table.siege_de(table.createur_id)
        with patch.object(jeu_main, "cfg", _config()), \
             patch.object(jeu_main, "_diffuser", diffuser), \
             patch.object(jeu_main, "_envoyer", envoyer), \
             patch.object(jeu_main, "PartieEnLigne", construire):
            await jeu_main._traiter(table, createur, {"type": "lancer"})
        assert table.partie is not None
        return table.partie, publie

    return asyncio.run(scenario())


def _tailles(partie: PartieEnLigne) -> List[int]:
    assert partie.jeu is not None
    return [joueur.nombre_cartes() for joueur in partie.jeu.joueurs]


def test_creation_rest_quatre_sieges_pour_chaque_type():
    from serveur.jeu import main as jeu_main

    requete = SimpleNamespace(headers={}, client=SimpleNamespace(host="test"))
    for type_demande in (None, "duel", "table_quatre"):
        gestionnaire = GestionnaireTables()
        corps = jeu_main.TableRequete() if type_demande is None else jeu_main.TableRequete(type=type_demande)
        with patch.object(jeu_main, "tables", gestionnaire), \
             patch.object(jeu_main, "_authentifie", return_value={"sub": "j1", "pseudo": "Nina"}), \
             patch.object(jeu_main._limiteur_rest, "autorise", return_value=(True, 0)):
            reponse = jeu_main.creer_table(requete, corps, credits=None)
        donnees = json.loads(reponse.body)
        table = gestionnaire.obtenir(donnees["code"])
        assert reponse.status_code == 201
        assert donnees["type"] == "table_quatre" and donnees["capacite"] == 4
        assert table.type_partie == "table_quatre" and len(table.sieges) == 4
        assert table.instantane(0)["capacite"] == 4
        assert len(table.instantane(0)["sieges"]) == 4


def test_quatrieme_accepte_cinquieme_refuse():
    from serveur.jeu import main as jeu_main

    gestionnaire = GestionnaireTables()
    table, createur = gestionnaire.creer("table_quatre", "j1", "Nina")
    createur.present, createur.websocket = True, object()
    with patch.object(jeu_main, "tables", gestionnaire):
        for numero in (1, 2, 3):
            if numero == 3:
                assert len(table.sieges_connectes()) == 3
            identite = {"sub": f"j{numero + 1}", "pseudo": f"Joueur{numero + 1}"}
            with patch.object(jeu_main, "_authentifie", return_value=identite):
                reponse = jeu_main.rejoindre_table(table.code, credits=None)
            assert reponse.status_code == 200
            assert json.loads(reponse.body)["siege"] == numero
            siege = table.siege(numero)
            siege.present, siege.websocket = True, object()
        assert len(table.sieges_connectes()) == 4
        with patch.object(jeu_main, "_authentifie", return_value={"sub": "j5", "pseudo": "Joueur5"}):
            try:
                jeu_main.rejoindre_table(table.code, credits=None)
            except ErreurTable as erreur:
                assert erreur.code == "table_complete" and erreur.statut == 409
                reponse = asyncio.run(jeu_main._gerer_erreur_table(None, erreur))
                assert json.loads(reponse.body)["erreur"]["code"] == "table_complete"
            else:
                raise AssertionError("un cinquième joueur aurait dû être refusé")


# ---------------------------------------------------------------------------
# a. Distribution à 2
# ---------------------------------------------------------------------------
def test_distribution_a_deux():
    table = _table("table_quatre", [(0, "j1", "Nina"), (1, "j2", "Marc")])
    partie, publie = _lancer(table)
    try:
        assert len(table.sieges) == 4 and partie.par_index == [0, 1]
        assert _tailles(partie) == [26, 26]
        assert len(partie.jeu.cartes_reste_neutres) == 0
        lancement = publie.du_type("partie_lancee")[0]["d"]
        assert lancement["nb_joueurs"] == 2
        assert lancement["taille_tas"] == [26, 26]
        assert lancement["nb_reste_neutre"] == 0
    finally:
        partie.detruire()


# ---------------------------------------------------------------------------
# b. Distribution à 3
# ---------------------------------------------------------------------------
def test_distribution_a_trois():
    table = _table(
        "table_quatre",
        [(0, "j1", "Nina"), (1, "j2", "Marc"), (2, "j3", "Julie")],
    )
    partie, publie = _lancer(table)
    try:
        assert _tailles(partie) == [17, 17, 17]
        assert len(partie.jeu.cartes_reste_neutres) == 1
        assert sum(_tailles(partie)) + len(partie.jeu.cartes_reste_neutres) == 52
        lancement = publie.du_type("partie_lancee")[0]["d"]
        assert lancement["nb_joueurs"] == 3
        assert lancement["taille_tas"] == [17, 17, 17]
        assert lancement["nb_reste_neutre"] == 1
    finally:
        partie.detruire()


# ---------------------------------------------------------------------------
# c. Distribution à 4
# ---------------------------------------------------------------------------
def test_distribution_a_quatre():
    table = _table(
        "table_quatre",
        [
            (0, "j1", "Nina"),
            (1, "j2", "Marc"),
            (2, "j3", "Julie"),
            (3, "j4", "Théo"),
        ],
    )
    partie, publie = _lancer(table)
    try:
        assert _tailles(partie) == [13, 13, 13, 13]
        assert len(partie.jeu.cartes_reste_neutres) == 0
        assert sum(_tailles(partie)) == 52
        lancement = publie.du_type("partie_lancee")[0]["d"]
        assert lancement["nb_joueurs"] == 4
        assert lancement["taille_tas"] == [13, 13, 13, 13]
    finally:
        partie.detruire()


# ---------------------------------------------------------------------------
# d. Un siège réservé mais non connecté n'entre pas dans la partie
# ---------------------------------------------------------------------------
def test_siege_reserve_non_connecte_exclu():
    table = _table(
        "table_quatre",
        [(0, "j1", "Nina"), (1, "j2", "Marc")],
        reserves=[(2, "j3", "Julie")],
    )
    assert [s.numero for s in table.sieges_connectes()] == [0, 1]
    partie, publie = _lancer(table)
    try:
        assert partie.par_index == [0, 1]
        assert 2 not in partie.par_siege
        assert len(partie.jeu.joueurs) == 2
        assert _tailles(partie) == [26, 26]
        assert table.siege(2).nb_cartes is None
        lancement = publie.du_type("partie_lancee")[0]["d"]
        assert lancement["nb_joueurs"] == 2
    finally:
        partie.detruire()


# ---------------------------------------------------------------------------
# e. Un seul joueur connecté : refus
# ---------------------------------------------------------------------------
def test_lancer_refuse_un_seul_joueur_connecte():
    table = _table("duel", [(0, "j1", "Nina")], reserves=[(1, "j2", "Marc")])
    partie = PartieEnLigne(table, Collecteur(), _config(), seed=1)
    try:
        asyncio.run(partie.lancer())
    except ValueError as erreur:
        assert "pas_assez_joueurs" in str(erreur)
    else:
        raise AssertionError("lancer() aurait dû refuser un seul joueur connecté")
    finally:
        partie.detruire()
    assert partie.jeu is None
    assert table.etat == "attente"


# ---------------------------------------------------------------------------
# f. Trois connectés sur une table à 4 : partie à 3, siège vide exclu
# ---------------------------------------------------------------------------
def test_trois_connectes_sur_table_a_quatre():
    table = _table(
        "table_quatre",
        [(0, "j1", "Nina"), (2, "j3", "Julie"), (3, "j4", "Théo")],
    )
    partie, publie = _lancer(table, seed=3)
    try:
        assert partie.par_index == [0, 2, 3]
        assert partie.par_siege == {0: 0, 2: 1, 3: 2}
        assert 1 not in partie.par_siege
        assert len(partie.jeu.joueurs) == 3
        assert _tailles(partie) == [17, 17, 17]
        assert len(partie.jeu.cartes_reste_neutres) == 1
        assert [s.nb_cartes for s in table.sieges] == [17, None, 17, 17]
        premier = publie.du_type("partie_lancee")[0]["d"]["premier_siege"]
        assert premier in (0, 2, 3)
        assert table.siege(1).nb_cartes is None
    finally:
        partie.detruire()


# ---------------------------------------------------------------------------
# g. Partie complète simulée à 3 : total 52 à chaque coup
# ---------------------------------------------------------------------------
def test_partie_complete_a_trois_conserve_52_cartes():
    table = _table(
        "table_quatre",
        [(0, "j1", "Nina"), (1, "j2", "Marc"), (2, "j3", "Julie")],
    )
    partie, publie = _lancer(table, seed=1)
    try:
        assert partie.jeu is not None
        coups = 0
        while partie.jeu.gagnant_final() is None and coups < 200000:
            before = evenements.total_cartes(partie.jeu)
            assert before == 52
            partie.jeu.jouer_un_coup()
            coups += 1
            assert evenements.total_cartes(partie.jeu) == 52, f"total cassé au coup {coups}"
        assert partie.jeu.gagnant_final() is not None
        assert coups > 0
        assert evenements.total_cartes(partie.jeu) == 52
        assert any(j.nombre_cartes() == 52 for j in partie.jeu.joueurs)
    finally:
        partie.detruire()


def test_resolveur_simulation_ne_filtre_pas_les_tas_vides():
    """Le résolveur réseau accepte un joueur sans cartes, comme le moteur."""
    jeu = BatailleCorse(["A", "B", "C"], seed=4)
    # Vider un tas doit conserver les 52 cartes : on les transfère au joueur 0
    # au lieu de les supprimer, puis on vérifie que le joueur 2 reste éligible.
    jeu.joueurs[0].tas.extend(jeu.joueurs[2].tas)
    jeu.joueurs[2].tas.clear()
    assert jeu.joueurs[2].nombre_cartes() == 0
    assert evenements.total_cartes(jeu) == 52
    resolveur = ResolveurTapeReseau()
    accepte, motif = resolveur.enregistrer("C", 200)
    assert (accepte, motif) == (True, None)
    gagnant = resolveur.determiner_gagnant(jeu.joueurs)
    assert gagnant is jeu.joueurs[2]
    assert gagnant.nombre_cartes() == 0


def test_lancer_partie_ignore_un_siege_reserve():
    """Le message `lancer` ne distribue pas au réservataire."""
    from serveur.jeu import main as jeu_main

    table = _table(
        "table_quatre",
        [(0, "j1", "Nina"), (1, "j2", "Marc")],
        reserves=[(2, "j3", "Julie")],
    )
    publie = Collecteur()

    async def diffuseur_faux(tbl, message, vers=None, sauf=None):
        await publie(tbl, message, vers)

    async def envoyer_faux(websocket, message, **kwargs):
        publie.messages.append({"type": message.get("type"), "d": message.get("d"), "vers": None})
        return True

    with patch.object(jeu_main, "cfg", _config()), \
         patch.object(jeu_main, "_diffuser", diffuseur_faux), \
         patch.object(jeu_main, "_envoyer", envoyer_faux):
        asyncio.run(jeu_main._traiter(table, table.siege(0), {"type": "lancer"}))

    try:
        assert table.etat == "en_jeu"
        assert table.partie is not None
        assert table.partie.par_index == [0, 1]
        assert table.partie.jeu is not None
        assert [j.nombre_cartes() for j in table.partie.jeu.joueurs] == [26, 26]
        assert table.siege(2).nb_cartes is None
        etats = publie.du_type("table_etat")
        assert etats and any(e["d"].get("etat") == "en_jeu" for e in etats)
    finally:
        if table.partie is not None:
            table.partie.detruire()


def _executer(nom: str, fonction) -> bool:
    try:
        fonction()
    except AssertionError as erreur:
        print(f"ÉCHEC  {nom} : {erreur}")
        return False
    except Exception as erreur:  # pragma: no cover
        print(f"ERREUR {nom} : {erreur!r}")
        return False
    print(f"ok     {nom}")
    return True


if __name__ == "__main__":
    cas = [
        ("création REST à quatre sièges", test_creation_rest_quatre_sieges_pour_chaque_type),
        ("quatrième accepté, cinquième refusé", test_quatrieme_accepte_cinquieme_refuse),
        ("distribution 2 -> 26/26", test_distribution_a_deux),
        ("distribution 3 -> 17/17/17 + 1", test_distribution_a_trois),
        ("distribution 4 -> 13/13/13/13", test_distribution_a_quatre),
        ("siège réservé non connecté exclu", test_siege_reserve_non_connecte_exclu),
        ("un seul connecté refusé", test_lancer_refuse_un_seul_joueur_connecte),
        ("3 connectés sur table à 4", test_trois_connectes_sur_table_a_quatre),
        ("partie complète à 3 conserve 52", test_partie_complete_a_trois_conserve_52_cartes),
        ("résolveur accepte un tas vide", test_resolveur_simulation_ne_filtre_pas_les_tas_vides),
        ("lancer ignore un réservataire", test_lancer_partie_ignore_un_siege_reserve),
    ]
    reussis = sum(_executer(nom, fonction) for nom, fonction in cas)
    echecs = len(cas) - reussis
    print(f"\n{reussis} succès, {echecs} échec(s).")
    sys.exit(1 if echecs else 0)
