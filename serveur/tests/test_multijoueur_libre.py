"""Non-régression du multijoueur : ce qui bloquait les vraies parties.

Ces tests couvrent les verrous qui empêchaient deux joueurs **humains** de
jouer une vraie partie depuis l'app :

1. **Le lancement explicite.** Seul le créateur lance la partie, sans que
   les indicateurs `pret` déclenchent ou empêchent ce lancement.

2. **Le verrou de l'instantané.** L'écran de jeu s'appuie sur
   `etat.suivant` pour afficher « à toi de jouer » et autoriser la pose de la
   carte. Sans `table_etat` pendant la partie, `suivant` restait `null` :
   aucun joueur ne savait que c'était son tour, et la partie restait bloquée
   sur le premier tour — côté client.

3. **Le verrou de l'état `en_jeu`.** C'est le `table_etat` qui porte
   `etat: "en_jeu"`, et c'est sur ce champ que la salle d'attente décide de
   basculer vers l'écran de jeu. Aucun autre message ne le porte : sans cet
   instantané au lancement, le joueur reste dans la salle d'attente, la
   table est pourtant « lancée » côté serveur, et personne ne voit son tapis.

    python3 serveur/tests/test_multijoueur_libre.py
"""
from __future__ import annotations

import asyncio
import json
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any, Dict, List, Optional
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from serveur.commun.config import config_jeu  # noqa: E402
from serveur.jeu.partie import PartieEnLigne  # noqa: E402
from serveur.jeu.table import GestionnaireTables, Table  # noqa: E402

SOCKET = object()          # marqueur « ce siège est connecté »


class Collecteur:
    """Diffuseur de test : il enregistre ce que le serveur publie."""

    def __init__(self) -> None:
        self.messages: List[Dict[str, Any]] = []

    async def __call__(
        self,
        table: Table,
        message: Dict[str, Any],
        vers: Optional[List[int]] = None,
    ) -> None:
        self.messages.append(
            {"type": message.get("type"), "d": message.get("d"), "vers": vers}
        )

    def types(self) -> List[str]:
        return [message["type"] for message in self.messages]

    def du_type(self, type_: str) -> List[Dict[str, Any]]:
        return [message for message in self.messages if message["type"] == type_]


def _config(**reglages: Any):
    base = config_jeu()
    return replace(base, delai_tour_ms=600000, compte_a_rebours_s=0, **reglages)


def _table_deux_joueurs() -> Table:
    """Table de duel, deux joueurs connectés."""
    gestionnaire = GestionnaireTables()
    table, _ = gestionnaire.creer("duel", "j1", "Nina")
    siege = table.siege(1)
    siege.joueur_id = "j2"
    siege.pseudo = "Marc"
    siege.present = True
    for un_siege in table.sieges:
        un_siege.websocket = SOCKET
        un_siege.present = True
    return table


# ---------------------------------------------------------------------------
def test_indicateur_tous_prets():
    """L'indicateur reste disponible sans déterminer le lancement."""
    table = _table_deux_joueurs()
    table.siege(1).pret = False          # Marc n'est pas prêt

    assert table.tous_prets() is False, (
        "un siège non prêt doit rendre l'indicateur faux"
    )

    # Le créateur, lui, est prêt.
    table.siege(0).pret = True
    assert table.tous_prets() is False

    # Marc se déclare prêt : l'indicateur devient vrai.
    table.siege(1).pret = True
    assert table.tous_prets() is True


def test_un_seul_joueur_prêt_ne_lance_pas_la_partie():
    """Un joueur seul ne peut pas lancer : il en faut au moins deux."""
    table = _table_deux_joueurs()
    table.siege(1).joueur_id = None
    table.siege(1).pseudo = None
    table.siege(1).pret = False

    assert table.nb_humains() == 1
    assert table.tous_prets() is False


def test_pret_seul_ne_lance_jamais():
    from serveur.jeu import main as jeu_main

    async def scenario():
        table = _table_deux_joueurs()
        publie = Collecteur()
        with patch.object(jeu_main, "_diffuser", publie):
            for siege in table.sieges:
                assert await jeu_main._traiter(table, siege, {"type": "pret"})
        assert table.tous_prets()
        assert table.etat == "attente" and table.partie is None
        assert len(publie.du_type("joueur_pret")) == 2
        assert not publie.du_type("compte_a_rebours")
    asyncio.run(scenario())


def test_lancer_controle_createur_et_etat():
    from serveur.jeu import main as jeu_main

    async def scenario():
        table = _table_deux_joueurs()
        messages = []
        async def envoyer(websocket, message):
            messages.append((websocket, message))
            return True
        async def diffuser(tbl, message, vers=None, sauf=None):
            messages.append((None, message))

        createur, invite = table.sieges
        createur.websocket, invite.websocket = object(), object()
        with patch.object(jeu_main, "cfg", _config()), \
             patch.object(jeu_main, "_envoyer", envoyer), \
             patch.object(jeu_main, "_diffuser", diffuser):
            await jeu_main._traiter(table, invite, {"type": "lancer"})
            assert messages[-1][0] is invite.websocket
            assert messages[-1][1]["d"]["code"] == "pas_createur"
            assert table.etat == "attente" and table.partie is None

            invite.present = False
            await jeu_main._traiter(table, createur, {"type": "lancer"})
            assert messages[-1][1]["d"]["code"] == "pas_assez_joueurs"
            assert table.etat == "attente" and table.partie is None

            invite.present = True
            assert not any(s.pret for s in table.sieges)
            await jeu_main._traiter(table, createur, {"type": "lancer"})
            assert table.etat == "en_jeu" and table.partie is not None
            assert table.partie.par_index == [0, 1]
            await jeu_main._traiter(table, createur, {"type": "lancer"})
            assert messages[-1][1]["d"]["code"] == "deja_lancee"
            table.etat = "terminee"
            await jeu_main._traiter(table, createur, {"type": "lancer"})
            assert messages[-1][1]["d"]["code"] == "table_terminee"
            table.partie.detruire()
    asyncio.run(scenario())


def test_lancement_annule_si_deconnexion_pendant_rebours():
    from serveur.jeu import main as jeu_main

    async def scenario():
        table = _table_deux_joueurs()
        messages = []
        async def envoyer(websocket, message):
            messages.append(message)
            return True
        async def diffuser(tbl, message, vers=None, sauf=None):
            messages.append(message)
            if message["type"] == "compte_a_rebours" and not message["d"].get("annule"):
                table.siege(1).present = False
                table.siege(1).websocket = None
        with patch.object(jeu_main, "cfg", _config()), \
             patch.object(jeu_main, "_envoyer", envoyer), \
             patch.object(jeu_main, "_diffuser", diffuser):
            await jeu_main._traiter(table, table.siege(0), {"type": "lancer"})
        assert table.etat == "attente" and table.partie is None
        assert any(m["type"] == "compte_a_rebours" and m["d"].get("annule") for m in messages)
        assert any(m["type"] == "table_etat" and m["d"]["etat"] == "attente" for m in messages)
    asyncio.run(scenario())


def test_createur_siege_dans_instantane_sans_identifiant():
    table = _table_deux_joueurs()
    etat = table.instantane(1)
    assert etat["createur_siege"] == 0 and etat["mon_siege"] == 1
    assert "createur_id" not in etat


def test_bienvenue_porte_le_siege_du_createur():
    from serveur.jeu import main as jeu_main

    async def scenario():
        gestionnaire = GestionnaireTables()
        table, _ = gestionnaire.creer("duel", "j1", "Nina")

        class SocketFictive:
            def __init__(self):
                self.entrees = iter([
                    json.dumps({"type": "bonjour", "d": {"table": table.code}}),
                    json.dumps({"type": "quitter"}),
                ])
                self.messages = []

            async def accept(self):
                pass

            async def receive_text(self):
                return next(self.entrees)

            async def send_text(self, message):
                self.messages.append(json.loads(message))

        socket = SocketFictive()
        with patch.object(jeu_main, "tables", gestionnaire), \
             patch.object(jeu_main, "_authentifie", return_value={"sub": "j1", "pseudo": "Nina"}):
            await jeu_main.websocket_jeu(socket)
        bienvenue = next(m for m in socket.messages if m["type"] == "bienvenue")
        assert bienvenue["d"]["siege"] == 0
        assert bienvenue["d"]["createur_siege"] == 0
        assert "createur_id" not in bienvenue["d"]
        assert any(m["type"] == "table_etat" and m["d"]["createur_siege"] == 0
                   for m in socket.messages)
    asyncio.run(scenario())


def test_siege_deconnecte_ne_peut_pas_lancer():
    from serveur.jeu import main as jeu_main

    async def scenario():
        table = _table_deux_joueurs()
        createur = table.siege(0)
        createur.present = False
        assert await jeu_main._traiter(table, createur, {"type": "lancer"})
        assert table.etat == "attente" and table.partie is None
    asyncio.run(scenario())


def test_headless_barriere_et_createur_2_3_4_sans_reseau():
    from serveur.tests import client_headless

    async def scenario(nombre, siege):
        class SocketFictive:
            def __init__(self):
                self.presents = 0
                self.envois = []
                self.messages = iter([
                    {"type": "bienvenue", "d": {"siege": siege, "createur_siege": 0}},
                    *[{"type": "table_etat", "d": {
                        "etat": "attente", "createur_siege": 0,
                        "sieges": [{"present": i < n} for i in range(nombre)],
                    }} for n in (1, nombre - 1, nombre, nombre)],
                    {"type": "partie_finie", "d": {"raison": "test"}},
                ])

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                pass

            async def send(self, message):
                self.envois.append((json.loads(message)["type"], self.presents))

            async def recv(self):
                message = next(self.messages)
                sieges = message.get("d", {}).get("sieges")
                if sieges is not None:
                    self.presents = sum(s["present"] for s in sieges)
                return json.dumps(message)

        socket = SocketFictive()
        barriere = client_headless.SynchronisationAttente(nombre)
        joueur = client_headless.Joueur({}, False, synchronisation=barriere)
        with patch.object(client_headless.websockets, "connect", return_value=socket):
            assert await joueur.session("sans-reseau", "TABLE") == {"raison": "test"}
        assert not any(type_ == "pret" for type_, _ in socket.envois)
        lancements = [presents for type_, presents in socket.envois if type_ == "lancer"]
        assert lancements == ([nombre] if siege == 0 else [])

    async def scenarios():
        for nombre in (2, 3, 4):
            for siege in range(nombre):
                await scenario(nombre, siege)
    asyncio.run(scenarios())


def test_le_lancement_publie_un_instantane_en_jeu():
    """Le lancement doit publier un `table_etat` en `en_jeu`.

    C'est **le** message qui fait basculer l'app de la salle d'attente vers
    l'écran de jeu : l'écran d'attente navigue sur `etat == "en_jeu"`, et
    aucun autre message ne porte cet état. Sans cet instantané, le joueur
    reste dans la salle d'attente, la table est « lancée » côté serveur, et
    personne ne voit jamais son tapis.
    """
    async def scenario():
        table = _table_deux_joueurs()
        publie = Collecteur()

        from serveur.jeu import main as jeu_main

        # Le lancement écrit dans les sockets (via `_diffuser` pour les
        # messages diffusés, et via `_instantane_par_siege` pour
        # l'instantané). On capture les DEUX : l'instantané passe par
        # `_envoyer`, pas par `_diffuser`.
        async def diffuseur_faux(tbl, message, vers=None, sauf=None):
            await publie(tbl, message, vers)

        async def envoyer_faux(websocket, message, **kwargs):
            publie.messages.append(
                {"type": message.get("type"), "d": message.get("d"), "vers": None}
            )
            return True

        with patch.object(jeu_main, "cfg", _config()), \
             patch.object(jeu_main, "_diffuser", diffuseur_faux), \
             patch.object(jeu_main, "_envoyer", envoyer_faux):
            await jeu_main._traiter(table, table.siege(0), {"type": "lancer"})
        return table, publie

    table, publie = asyncio.run(scenario())

    # La table est bien passée en jeu côté serveur.
    assert table.etat == "en_jeu", f"la table doit être en jeu, elle est en {table.etat!r}"
    assert table.partie is not None, "la partie doit exister"

    # Et un instantané en `en_jeu` a été publié : c'est lui qui débloque l'app.
    etats = publie.du_type("table_etat")
    assert etats, "le lancement doit publier un `table_etat`"
    etats_vus = [message["d"].get("etat") for message in etats]
    assert "en_jeu" in etats_vus, (
        f"un instantané doit porter `etat: en_jeu`, vus : {etats_vus}"
    )


def test_lancer_partie_publie_un_instantane_par_siege():
    """Après chaque coup, chaque siège reçoit son propre `table_etat`.

    C'est cet instantané qui porte `suivant` : sans lui, l'app ne sait
    jamais que c'est au joueur de poser.
    """
    async def scenario():
        table = _table_deux_joueurs()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, _config(), seed=1)
        await partie.lancer()
        await partie.jouer(auto=False)
        partie.detruire()
        return publie, table, partie

    publie, table, partie = asyncio.run(scenario())

    etats = publie.du_type("table_etat")
    assert etats, (
        "chaque coup doit publier un `table_etat` : sans lui, le client ne "
        "connaît jamais le tour et la partie reste bloquée"
    )

    # Un instantané par siège connecté, et chacun sa copie.
    sieges = {message["vers"][0] for message in etats if message["vers"]}
    assert sieges == {0, 1}, "chaque siège doit recevoir sa propre copie"

    # L'instantané dit bien à qui c'est le tour.
    dernier = etats[-1]["d"]
    assert "suivant" in dernier, "l'instantané doit porter `suivant`"
    assert dernier["suivant"] in (0, 1)

    # Et la carte du dessus ne fuite que vers son propriétaire.
    for message in etats:
        donnees = message["d"]
        siege = message["vers"][0]
        for autre in donnees["sieges"]:
            if autre["siege"] != siege:
                assert "ma_carte" not in autre, (
                    "la carte du dessus ne doit jamais fuiter vers un autre siège"
                )


def test_l_instantane_porte_le_tour_et_le_pli():
    """`suivant` doit avancer : c'est lui que l'écran lit pour autoriser le coup."""
    async def scenario():
        table = _table_deux_joueurs()
        publie = Collecteur()
        partie = PartieEnLigne(table, publie, _config(), seed=1)
        await partie.lancer()
        tours = []
        for _ in range(3):
            await partie.jouer(auto=False)
            dernier = publie.du_type("table_etat")[-1]["d"]
            tours.append(dernier["suivant"])
        partie.detruire()
        return tours

    tours = asyncio.run(scenario())
    assert len(tours) == 3
    assert all(tour in (0, 1) for tour in tours), (
        f"le tour doit toujours désigner un joueur réel, pas null : {tours}"
    )
    # Le tour **alterne** : c'est la preuve que la partie progresse.
    assert tours[0] != tours[1], f"le tour doit avancer d'un coup à l'autre : {tours}"


# ---------------------------------------------------------------------------
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
        ("indicateur tous prêts", test_indicateur_tous_prets),
        ("un seul joueur prêt ne lance pas la partie",
         test_un_seul_joueur_prêt_ne_lance_pas_la_partie),
        ("pret seul ne lance pas", test_pret_seul_ne_lance_jamais),
        ("contrôle du créateur et de l'état", test_lancer_controle_createur_et_etat),
        ("annulation après déconnexion", test_lancement_annule_si_deconnexion_pendant_rebours),
        ("siège du créateur dans l'instantané", test_createur_siege_dans_instantane_sans_identifiant),
        ("siège du créateur dans bienvenue", test_bienvenue_porte_le_siege_du_createur),
        ("un siège déconnecté ne lance pas", test_siege_deconnecte_ne_peut_pas_lancer),
        ("headless 2, 3, 4 : barrière et créateur", test_headless_barriere_et_createur_2_3_4_sans_reseau),
        ("le lancement publie un instantané en jeu",
         test_le_lancement_publie_un_instantane_en_jeu),
        ("chaque coup publie un instantané par siège",
         test_lancer_partie_publie_un_instantane_par_siege),
        ("l'instantané porte le tour et le pli",
         test_l_instantane_porte_le_tour_et_le_pli),
    ]
    reussis = sum(_executer(nom, fn) for nom, fn in cas)
    echecs = len(cas) - reussis
    print(f"\n{reussis} succès, {echecs} échec(s).")
    sys.exit(1 if echecs else 0)
