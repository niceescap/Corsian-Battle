"""Tests de la boucle de coups — sans socket, sans base, sans réseau.

Deux niveaux :

1. `evenements.jouer_coup()` sur des parties construites à la main : chaque
   règle produit le bon événement, avec les bons index moteur.
2. `PartieEnLigne` jouée en automatique jusqu'à la fin : rythme, diffusion,
   séparation public/privé, traduction index moteur → numéros de siège,
   conservation des 52 cartes.

    python3 -m pytest serveur/tests/test_boucle_coups.py
    python3 serveur/tests/test_boucle_coups.py
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from bataille_corse.cartes import CODES_RANG, Carte  # noqa: E402
from bataille_corse.moteur import BatailleCorse  # noqa: E402
from bataille_corse.resolveur_tape import (  # noqa: E402
    ResolveurSimulationBots,
    ResolveurTape,
)
from serveur.commun.config import config_jeu  # noqa: E402
from serveur.jeu import evenements  # noqa: E402
from serveur.jeu.partie import PartieEnLigne  # noqa: E402
from serveur.jeu.table import GestionnaireTables, Table  # noqa: E402

_RANG = {code: rang for rang, code in CODES_RANG.items()}


def _carte(code: str) -> Carte:
    return Carte(_RANG[code[0]], code[1])


class ResolveurPersonne(ResolveurTape):
    def determiner_gagnant(self, eligibles: List[Any]) -> None:
        return None


class ResolveurChoisi(ResolveurTape):
    def __init__(self, nom: str) -> None:
        self.nom = nom

    def determiner_gagnant(self, eligibles: List[Any]) -> Optional[Any]:
        for joueur in eligibles:
            if joueur.nom == self.nom:
                return joueur
        return None


def _jeu(tas: List[List[str]], resolveur: ResolveurTape) -> BatailleCorse:
    noms = [chr(ord("A") + i) for i in range(len(tas))]
    jeu = BatailleCorse(noms, resolveur_tape=resolveur, seed=1)
    for joueur, codes in zip(jeu.joueurs, tas):
        joueur.tas.clear()
        for code in codes:
            joueur.tas.append(_carte(code))
    jeu.pli.clear()
    jeu.cartes_reste_neutres.clear()
    jeu.defi_en_cours = None
    jeu.index_courant = 0
    jeu.historique.clear()
    return jeu


def _types(coup: evenements.Coup) -> List[str]:
    return [evenement["type"] for evenement in coup.evenements]


class Collecteur:
    """Remplace la diffusion WebSocket : enregistre au lieu d'envoyer."""

    def __init__(self) -> None:
        self.messages: List[Dict[str, Any]] = []

    async def __call__(self, table: Table, message: Dict[str, Any], vers=None) -> None:
        self.messages.append(
            {"type": message.get("type"), "seq": message.get("seq"), "d": message.get("d"), "vers": vers}
        )

    def types(self) -> List[str]:
        return [message["type"] for message in self.messages]

    def du_type(self, type_: str) -> List[Dict[str, Any]]:
        return [message for message in self.messages if message["type"] == type_]


def _table(type_partie: str = "duel", occupes=((0, "j1", "Nina"), (1, "j2", "Marc"))) -> Table:
    gestionnaire = GestionnaireTables()
    table, _ = gestionnaire.creer(type_partie, occupes[0][1], occupes[0][2])
    for numero, joueur_id, pseudo in occupes[1:]:
        siege = table.siege(numero)
        siege.joueur_id = joueur_id
        siege.pseudo = pseudo
        siege.present = True
    return table


# ---------------------------------------------------------------------------
# 1. evenements.jouer_coup
# ---------------------------------------------------------------------------
def test_carte_posee_toujours_en_tete():
    jeu = _jeu([["2S", "3H"], ["4D", "5C"]], ResolveurPersonne())
    coup = evenements.jouer_coup(jeu)
    assert coup is not None
    assert _types(coup)[0] == "carte_posee"
    donnees = coup.evenements[0]["d"]
    assert donnees["siege"] == 0
    assert donnees["carte"] == "2S"
    assert donnees["pli"] == 1
    assert donnees["suivant"] == 1
    assert donnees["defi"] is None
    assert donnees["auto"] is False


def test_figure_produit_defi_ouvert():
    jeu = _jeu([["AH", "2S"], ["5H", "6D"]], ResolveurPersonne())
    coup = evenements.jouer_coup(jeu)
    assert _types(coup) == ["carte_posee", "defi_ouvert"]
    assert coup.evenements[1]["d"] == {"poseur": 0, "repondeur": 1, "chances": 4}
    assert coup.defi == {"poseur": 0, "repondeur": 1, "chances_restantes": 4}


def test_rebond_produit_defi_rebondit_au_bareme_plein():
    jeu = _jeu([["AH", "2S"], ["KH", "3D"]], ResolveurPersonne())
    evenements.jouer_coup(jeu)                       # AH → défi(A, 4)
    coup = evenements.jouer_coup(jeu)                # KH → rebond
    assert _types(coup) == ["carte_posee", "defi_rebondit"]
    assert coup.evenements[1]["d"] == {"nouveau_poseur": 1, "repondeur": 0, "chances": 3}


def test_defi_manque_produit_pli_gagne_avec_le_bon_nombre():
    jeu = _jeu([["AH", "2S"], ["5H", "6D", "7S", "8C"]], ResolveurPersonne())
    for _ in range(4):
        evenements.jouer_coup(jeu)
    coup = evenements.jouer_coup(jeu)                # 4e carte du répondeur
    assert "pli_gagne" in _types(coup)
    assert coup.pli_gagne["gagnant"] == 0
    assert coup.pli_gagne["raison"] == "defi_manque"
    assert coup.pli_gagne["nb_cartes"] == 5          # AH + les 4 cartes du répondeur
    assert coup.pli_gagne["reste_neutre_inclus"] is False


def test_doublon_tape_attribue_le_pli():
    jeu = _jeu([["5S", "2C"], ["5H", "3D"]], ResolveurChoisi("B"))
    evenements.jouer_coup(jeu)                       # A pose 5S
    coup = evenements.jouer_coup(jeu)                # B pose 5H → doublon
    assert coup.etait_doublon is True
    assert coup.doublon_non_tape is False
    assert "pli_gagne" in _types(coup)
    assert coup.pli_gagne["gagnant"] == 1
    assert coup.pli_gagne["raison"] == "doublon"
    assert coup.pli_gagne["nb_cartes"] == 2


def test_doublon_non_tape_passe_sans_effet():
    jeu = _jeu([["5S", "2C"], ["5H", "3D"]], ResolveurPersonne())
    evenements.jouer_coup(jeu)
    coup = evenements.jouer_coup(jeu)
    assert coup.etait_doublon is True
    assert coup.doublon_non_tape is True
    assert "pli_gagne" not in _types(coup)
    assert coup.evenements[-1]["d"]["cartes"] == ["5S", "5H"]
    assert len(jeu.pli) == 2


def test_reste_neutre_compte_dans_le_premier_pli():
    jeu = BatailleCorse(["A", "B", "C"], resolveur_tape=ResolveurChoisi("A"), seed=7)
    assert len(jeu.cartes_reste_neutres) == 1
    for joueur, code in zip(jeu.joueurs, ("5S", "5H", "9C")):
        joueur.tas.clear()
        joueur.tas.append(_carte(code))
    jeu.pli.clear()
    jeu.index_courant = 0
    evenements.jouer_coup(jeu)
    coup = evenements.jouer_coup(jeu)
    assert coup.pli_gagne is not None
    assert coup.pli_gagne["reste_neutre_inclus"] is True
    assert coup.pli_gagne["nb_cartes"] == 3          # 5S + 5H + la carte neutre


def test_plus_personne_ne_peut_jouer_renvoie_none():
    jeu = _jeu([[], []], ResolveurPersonne())
    assert evenements.jouer_coup(jeu) is None


def test_partie_bloquee_marquee_comme_telle():
    jeu = _jeu([["2S"], ["4D"]], ResolveurPersonne())
    evenements.jouer_coup(jeu)
    coup = evenements.jouer_coup(jeu)
    assert coup is not None
    assert coup.bloque is True
    assert coup.fini is False
    assert coup.suivant is None


def test_conservation_des_52_cartes_a_chaque_coup():
    jeu = BatailleCorse(["A", "B", "C", "D"], seed=99)
    for _ in range(80):
        assert evenements.total_cartes(jeu) == 52
        if jeu.gagnant_final() is not None:
            break
        evenements.jouer_coup(jeu)
    assert evenements.total_cartes(jeu) == 52


# ---------------------------------------------------------------------------
# 2. PartieEnLigne
# ---------------------------------------------------------------------------
def test_lancement_passe_la_table_en_jeu():
    async def scenario():
        table = _table()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, config_jeu(), seed=4242)
        await partie.lancer()
        partie.detruire()
        return table, publie, partie

    table, publie, partie = asyncio.run(scenario())
    assert table.etat == "en_jeu"
    assert partie.par_index == [0, 1]
    assert publie.types()[0] == "partie_lancee"
    lancement = publie.du_type("partie_lancee")[0]["d"]
    assert lancement["nb_joueurs"] == 2
    assert lancement["taille_tas"] == [26, 26]
    assert lancement["premier_siege"] == 0
    assert [s.nb_cartes for s in table.sieges] == [26, 26]


def test_chaque_siege_recoit_sa_carte_en_prive():
    async def scenario():
        table = _table()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, config_jeu(), seed=4242)
        await partie.lancer()
        partie.detruire()
        return publie

    publie = asyncio.run(scenario())
    annonces = publie.du_type("ta_carte_suivante")
    assert len(annonces) == 2
    for annonce in annonces:
        assert isinstance(annonce["vers"], list) and len(annonce["vers"]) == 1
        assert len(annonce["d"]["carte"]) == 2


def test_aucune_carte_adverse_ne_fuit_dans_les_messages_publics():
    async def scenario():
        table = _table()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, config_jeu(), seed=17)
        await partie.lancer()
        for _ in range(30):
            if partie.termine:
                break
            await partie.jouer(auto=True)
        partie.detruire()
        return publie, partie

    publie, partie = asyncio.run(scenario())
    mains = [
        partie.jeu.joueurs[i].tas[0].code
        for i in range(2)
        if partie.jeu.joueurs[i].a_des_cartes()
    ]
    for message in publie.messages:
        if message["vers"] is not None:
            continue                     # message privé : hors contrôle public
        if message["type"] == "carte_posee":
            continue                     # la carte posée est publique par règle
        brut = str(message["d"])
        for code in mains:
            assert code not in brut, f"{code} a fui dans {message['type']}"


def test_hors_tour_refuse_et_tour_accepte():
    async def scenario():
        table = _table()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, config_jeu(), seed=3)
        await partie.lancer()
        tour = partie.tour_courant()
        autre = 1 if tour == 0 else 0
        refuse = await partie.poser_carte(autre)
        dernier = publie.messages[-1]
        accepte = await partie.poser_carte(tour)
        partie.detruire()
        return refuse, dernier, accepte, autre, tour

    refuse, dernier, accepte, autre, tour = asyncio.run(scenario())
    assert refuse is False
    assert dernier["type"] == "erreur"
    assert dernier["d"]["code"] == "pas_ton_tour"
    assert dernier["vers"] == [autre]
    assert accepte is True


def test_partie_complete_jusqu_a_la_fin():
    async def scenario():
        table = _table()
        publie = Collecteur()
        fin = []

        async def sur_fin(partie, raison, gagnant):
            fin.append((raison, gagnant))

        partie = PartieEnLigne(table, publie, config_jeu(), seed=20260916, sur_fin=sur_fin)
        await partie.lancer()
        garde = 0
        while not partie.termine and garde < 5000:
            await partie.jouer(auto=True)
            garde += 1
        partie.detruire()
        return table, publie, partie, fin, garde

    table, publie, partie, fin, garde = asyncio.run(scenario())
    assert partie.termine is True, "la partie doit se terminer"
    assert partie.raison_fin in ("victoire", "partie_nulle", "expiration")
    assert publie.types()[-1] == "partie_finie"
    assert len(fin) == 1
    assert garde < 5000
    assert evenements.total_cartes(partie.jeu) == 52
    cloture = publie.du_type("partie_finie")[0]["d"]
    assert cloture["raison"] == partie.raison_fin
    assert cloture["nb_coups"] == partie.coups
    assert sum(1 for s in cloture["stats"] if s["gagnant"]) in (0, 1)
    assert table.etat == "terminee"


def test_index_moteur_traduits_en_numeros_de_siege():
    """Sièges 1 et 2 occupés (le 0 est vide) : l'index moteur 0 → siège 1."""

    async def scenario():
        table = _table("table_quatre", occupes=((1, "j1", "Nina"), (2, "j2", "Marc")))
        table.createur_id = "j1"
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, config_jeu(), seed=8)
        await partie.lancer()
        await partie.jouer(auto=True)
        partie.detruire()
        return publie, partie

    publie, partie = asyncio.run(scenario())
    assert partie.par_index == [1, 2]
    assert publie.du_type("partie_lancee")[0]["d"]["premier_siege"] == 1
    posee = publie.du_type("carte_posee")[0]["d"]
    assert posee["siege"] == 1
    assert posee["suivant"] == 2
    etat = partie.etat_public()
    assert etat["suivant"] == 2
    annonces = publie.du_type("ta_carte_suivante")
    assert {a["vers"][0] for a in annonces} == {1, 2}


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
            except Exception as erreur:                     # noqa: BLE001
                echecs += 1
                print(f"ERREUR {nom} : {type(erreur).__name__}: {erreur}")
    print(f"\n{echecs} échec(s).")
    sys.exit(1 if echecs else 0)
