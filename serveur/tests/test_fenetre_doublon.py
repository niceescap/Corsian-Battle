"""Tests de la fenêtre de doublon (lot B) — sans socket réel ni réseau.

Les sièges reçoivent un objet factice en guise de WebSocket : `PartieEnLigne`
ne fait que tester `websocket is not None` pour savoir qui est connecté et peut
taper. Les `tape` sont injectés directement par `recevoir_tape()`, ce qui rend
la fenêtre testable de façon déterministe et rapide.

    python3 -m pytest serveur/tests/test_fenetre_doublon.py
    python3 serveur/tests/test_fenetre_doublon.py
"""
from __future__ import annotations

import asyncio
import sys
import time
from dataclasses import replace
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from bataille_corse.cartes import CODES_RANG, Carte  # noqa: E402
from bataille_corse.moteur import DefiEnCours  # noqa: E402
from serveur.commun.config import config_jeu  # noqa: E402
from serveur.jeu.partie import PartieEnLigne  # noqa: E402
from serveur.jeu.table import GestionnaireTables, Table  # noqa: E402

_RANG = {code: rang for rang, code in CODES_RANG.items()}
SOCKET = object()          # marqueur « ce siège est connecté »


def _carte(code: str) -> Carte:
    return Carte(_RANG[code[0]], code[1])


class Collecteur:
    def __init__(self) -> None:
        self.messages: List[Dict[str, Any]] = []

    async def __call__(self, table: Table, message: Dict[str, Any], vers=None) -> None:
        self.messages.append(
            {"type": message.get("type"), "d": message.get("d"), "vers": vers}
        )

    def types(self) -> List[str]:
        return [message["type"] for message in self.messages]

    def du_type(self, type_: str) -> List[Dict[str, Any]]:
        return [message for message in self.messages if message["type"] == type_]


def _table(connectee: bool = True) -> Table:
    gestionnaire = GestionnaireTables()
    table, _ = gestionnaire.creer("duel", "j1", "Nina")
    siege = table.siege(1)
    siege.joueur_id = "j2"
    siege.pseudo = "Marc"
    siege.present = True
    if connectee:
        for un_siege in table.sieges:
            un_siege.websocket = SOCKET
    return table


def _config(**reglages: Any):
    base = config_jeu()
    return replace(base, delai_tour_ms=600000, **reglages)


def _imposer(
    partie: PartieEnLigne,
    pli: List[str],
    tas_a: List[str],
    tas_b: List[str],
    index_courant: int = 0,
    defi: Optional[DefiEnCours] = None,
) -> None:
    """Fixe l'état du moteur pour provoquer la situation voulue."""
    jeu = partie.jeu
    assert jeu is not None
    for joueur in jeu.joueurs:
        joueur.tas.clear()
    for code in tas_a:
        jeu.joueurs[0].tas.append(_carte(code))
    for code in tas_b:
        jeu.joueurs[1].tas.append(_carte(code))
    jeu.pli.clear()
    for code in pli:
        jeu.pli.append(_carte(code))
    jeu.cartes_reste_neutres.clear()
    jeu.defi_en_cours = defi
    jeu.index_courant = index_courant
    jeu.historique.clear()


# ---------------------------------------------------------------------------
def test_prediction_du_doublon():
    async def scenario():
        table = _table(connectee=False)
        partie = PartieEnLigne(table, Collecteur(), _config(), seed=1)
        await partie.lancer()
        avant = partie._doublon_previsible()          # tas mélangés : en général None
        _imposer(partie, ["5S"], ["5H", "2C"], ["3D", "4S"])
        previsible = partie._doublon_previsible()
        _imposer(partie, ["5S"], ["9H", "2C"], ["3D", "4S"])
        pas_doublon = partie._doublon_previsible()
        partie.detruire()
        return previsible, pas_doublon

    previsible, pas_doublon = asyncio.run(scenario())
    assert previsible == ("5S", "5H")
    assert pas_doublon is None


def test_fenetre_ordre_des_messages_et_verdict():
    async def scenario():
        table = _table()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, _config(fenetre_tape_ms=2000), seed=1)
        await partie.lancer()
        _imposer(partie, ["5S"], ["5H", "2C"], ["3D", "4S"])
        tache = asyncio.create_task(partie.jouer(auto=False))
        await asyncio.sleep(0.05)
        en_attente = partie.attend_tape()
        partie.recevoir_tape(1, 300)                  # Marc, plus lent
        partie.recevoir_tape(0, 180)                  # Nina gagne
        coup = await asyncio.wait_for(tache, timeout=5)
        partie.detruire()
        return publie, partie, coup, en_attente

    publie, partie, coup, en_attente = asyncio.run(scenario())
    assert en_attente is True
    types = publie.types()

    ouverture = publie.du_type("doublon_ouvert")[0]["d"]
    assert ouverture["cartes"] == ["5S", "5H"]
    assert ouverture["fenetre_ms"] == 2000
    assert ouverture["plancher_ms"] == 120

    # Ordre imposé par la prédiction : ouverture → carte → verdict → pli.
    assert types.index("doublon_ouvert") < types.index("carte_posee")
    assert types.index("carte_posee") < types.index("doublon_resolu")
    assert types.index("doublon_resolu") < types.index("pli_gagne")

    posee = publie.du_type("carte_posee")[0]["d"]
    assert posee["annonce"] is True, "le client ne doit pas rejouer l'animation"
    assert posee["carte"] == "5H" and posee["siege"] == 0

    resolu = publie.du_type("doublon_resolu")[0]["d"]
    assert resolu["gagnant"] == 0
    assert resolu["delai_ms_gagnant"] == 180.0
    assert resolu["personne"] is False
    assert resolu["nb_tapes"] == 2

    pli = publie.du_type("pli_gagne")[0]["d"]
    assert pli["raison"] == "doublon"
    assert pli["gagnant"] == 0
    assert pli["nb_cartes"] == 2

    assert coup is not None and coup.etait_doublon and not coup.doublon_non_tape
    assert partie.doublons_ouverts == 1 and partie.doublons_tapes == 1
    stats = {ligne["siege"]: ligne for ligne in partie.statistiques()}
    assert stats[0]["doublons_gagnes"] == 1
    assert stats[1]["doublons_perdus"] == 1
    assert stats[0]["delai_tape_median_ms"] == 180


def test_fenetre_sans_tape_personne():
    async def scenario():
        table = _table()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, _config(fenetre_tape_ms=80), seed=1)
        await partie.lancer()
        _imposer(partie, ["5S"], ["5H", "2C"], ["3D", "4S"])
        debut = time.time()
        coup = await asyncio.wait_for(partie.jouer(auto=False), timeout=5)
        duree = time.time() - debut
        partie.detruire()
        return publie, partie, coup, duree

    publie, partie, coup, duree = asyncio.run(scenario())
    assert duree >= 0.08, "la fenêtre doit aller jusqu'à son terme si personne ne tape"
    resolu = publie.du_type("doublon_resolu")[0]["d"]
    assert resolu["personne"] is True and resolu["gagnant"] is None
    assert "doublon_non_tape" in publie.types()
    assert "pli_gagne" not in publie.types()
    assert coup.pli_gagne is None and coup.doublon_non_tape is True
    assert partie.doublons_tapes == 0


def test_fenetre_se_clot_des_que_tout_le_monde_a_tape():
    async def scenario():
        table = _table()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, _config(fenetre_tape_ms=5000), seed=1)
        await partie.lancer()
        _imposer(partie, ["5S"], ["5H", "2C"], ["3D", "4S"])
        tache = asyncio.create_task(partie.jouer(auto=False))
        await asyncio.sleep(0.05)
        partie.recevoir_tape(0, 200)
        partie.recevoir_tape(1, 260)
        debut = time.time()
        await asyncio.wait_for(tache, timeout=5)
        duree = time.time() - debut
        partie.detruire()
        return duree

    duree = asyncio.run(scenario())
    assert duree < 1.0, f"clôture anticipée attendue, {duree:.2f} s mesurées"


def test_delai_impossible_rejete_et_consigne():
    async def scenario():
        table = _table()
        publie = Collecteur()
        suspects: List[Dict[str, Any]] = []

        async def sur_suspicion(liste):
            suspects.extend(liste)

        partie = PartieEnLigne(
            table, publie, _config(fenetre_tape_ms=2000), seed=1,
            sur_suspicion=sur_suspicion,
        )
        await partie.lancer()
        _imposer(partie, ["5S"], ["5H", "2C"], ["3D", "4S"])
        tache = asyncio.create_task(partie.jouer(auto=False))
        await asyncio.sleep(0.05)
        partie.recevoir_tape(0, 40)                   # Nina : 40 ms, impossible
        partie.recevoir_tape(1, 300)                  # Marc : valable
        await asyncio.wait_for(tache, timeout=5)
        partie.detruire()
        return publie, suspects

    publie, suspects = asyncio.run(scenario())
    resolu = publie.du_type("doublon_resolu")[0]["d"]
    assert resolu["gagnant"] == 1, "le délai impossible ne doit pas gagner"
    assert resolu["nb_tapes"] == 1
    assert suspects == [{"siege": 0, "type": "delai_impossible", "valeur_ms": 40}]


def test_tape_hors_fenetre_ignorer():
    async def scenario():
        table = _table(connectee=False)
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, _config(), seed=1)
        await partie.lancer()
        accepte, motif = partie.recevoir_tape(0, 200)
        partie.detruire()
        return accepte, motif, publie

    accepte, motif, publie = asyncio.run(scenario())
    assert accepte is False and motif == "aucune_fenetre"
    assert "doublon_resolu" not in publie.types()


def test_doublon_non_tape_et_defi_manque_sur_le_meme_coup():
    """Le cas relevé en recette du lot A : `raison` doit dire **defi_manque**.

    Le doublon passe (personne n'a tapé) mais la carte posée épuisait la
    dernière chance du défi : le pli revient au poseur de figure. Les deux
    événements sont émis, dans cet ordre, et la raison du pli est la bonne.
    """

    async def scenario():
        table = _table(connectee=False)
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, _config(), seed=1)
        partie.fenetre_active = False                 # personne ne peut taper
        await partie.lancer()
        jeu = partie.jeu
        defi = DefiEnCours(jeu.joueurs[1], 1)         # Marc poseur, 1 chance left
        _imposer(partie, ["KH", "5S"], ["5H"], ["3D"], index_courant=0, defi=defi)
        await partie.jouer(auto=False)
        partie.detruire()
        return publie, partie

    publie, partie = asyncio.run(scenario())
    types = publie.types()
    assert "doublon_non_tape" in types
    assert "pli_gagne" in types
    assert types.index("doublon_non_tape") < types.index("pli_gagne")
    pli = publie.du_type("pli_gagne")[0]["d"]
    assert pli["raison"] == "defi_manque", "le pli vient du défi manqué, pas de la tape"
    assert pli["gagnant"] == 1
    assert pli["nb_cartes"] == 3                     # KH + 5S + 5H
    assert partie.doublons_ouverts == 1 and partie.doublons_tapes == 0


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
