"""Non-régression du multijoueur : ce qui bloquait les vraies parties.

Ces tests couvrent les verrous qui empêchaient deux joueurs **humains** de
jouer une vraie partie depuis l'app :

1. **Le verrou du `pret`.** Le serveur ne lance une partie que si *tous* les
   sièges sont prêts (`docs/PROTOCOLE.md` §4). L'app déclarait son siège
   prêt depuis l'écran de jeu — écran qu'on n'atteint qu'**après** le
   lancement. Le serveur attendait donc un `pret` qui ne venait jamais, et la
   table restait en `attente` indéfiniment, sans message d'erreur.

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
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any, Dict, List, Optional

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
    """Table de duel, deux joueurs connectés et prêts."""
    gestionnaire = GestionnaireTables()
    table, _ = gestionnaire.creer("duel", "j1", "Nina")
    siege = table.siege(1)
    siege.joueur_id = "j2"
    siege.pseudo = "Marc"
    siege.present = True
    siege.pret = True
    for un_siege in table.sieges:
        un_siege.websocket = SOCKET
        # Les DEUX joueurs sont prêts : c'est la condition de lancement.
        un_siege.pret = True
    return table


# ---------------------------------------------------------------------------
def test_la_partie_ne_demarre_qu_si_tous_les_sieges_sont_prets():
    """Le verrou du `pret` : un joueur non prêt suffit à bloquer le lancement."""
    table = _table_deux_joueurs()
    table.siege(1).pret = False          # Marc n'est pas prêt

    assert table.tous_prets() is False, (
        "un siège non prêt doit empêcher le lancement : c'est exactement le "
        "verrou qui bloquait les parties"
    )

    # Le créateur, lui, est prêt.
    table.siege(0).pret = True
    assert table.tous_prets() is False

    # Marc se déclare prêt : là, la partie peut démarrer.
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

        original_diffuser = jeu_main._diffuser
        original_envoyer = jeu_main._envoyer
        jeu_main._diffuser = diffuseur_faux
        jeu_main._envoyer = envoyer_faux
        try:
            await jeu_main._lancer_partie(table)
        finally:
            jeu_main._diffuser = original_diffuser
            jeu_main._envoyer = original_envoyer
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
        ("la partie ne démarre qu'avec tous les sièges prêts",
         test_la_partie_ne_demarre_qu_si_tous_les_sieges_sont_prets),
        ("un seul joueur prêt ne lance pas la partie",
         test_un_seul_joueur_prêt_ne_lance_pas_la_partie),
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
