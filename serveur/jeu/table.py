"""Tables de jeu en mémoire.

Un seul worker par service (`docs/DEPLOIEMENT.md` §4) : l'état des tables vit
dans le processus, la base ne conserve que l'histoire (`parties`,
`participations`) et des instantanés de reprise (`tables_snapshot`).

Périmètre de cette livraison : le cycle de vie **attente** (création, code
d'invitation, réservation de siège, arrivée/départ des sockets, expiration).
La boucle de coups et la branche sur `bataille_corse` arrivent à l'étape S2 —
la forme de `instantane()` est déjà complète et stable pour que le client
n'ait pas à changer de contrat ensuite (`docs/PROTOCOLE.md` §6).
"""
from __future__ import annotations

import secrets
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

# Alphabet sans caractère ambigu : le code se lit à voix haute comme il se saisit.
ALPHABET_CODE = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
LONGUEUR_CODE = 6

ETATS = ("attente", "compte_a_rebours", "en_jeu", "terminee")
TAILLES = {"duel": 2, "table_quatre": 4}

DUREE_ATTENTE_S = 7200.0    # 2 h : au-delà, une table sans socket est fermée
RESERVATION_S = 20.0         # siège réservé par REST mais jamais connecté → libéré


class ErreurTable(Exception):
    """Erreur de cycle de vie d'une table.

    `statut` sert au REST, `fermeture_ws` au WebSocket
    (`docs/PROTOCOLE.md` §12).
    """

    def __init__(
        self,
        code: str,
        message: str,
        statut: int = 409,
        fermeture_ws: int = 4409,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.statut = statut
        self.fermeture_ws = fermeture_ws


@dataclass
class Siege:
    numero: int
    joueur_id: Optional[str] = None
    pseudo: Optional[str] = None
    est_bot: bool = False
    pret: bool = False
    present: bool = False
    reserve_le: float = 0.0
    connecte_le: Optional[float] = None
    deconnecte_le: Optional[float] = None
    nb_cartes: Optional[int] = None
    ma_carte: Optional[str] = None          # privé : carte du dessus de CE siège
    websocket: Any = None                   # starlette WebSocket, jamais sérialisé

    # Dernier `seq_attendu` déjà consommé par ce siège. Sert à détecter un
    # REJEU : le client renvoie un `seq_attendu` déjà vu, il rejoue un coup.
    seq_pose: int = 0

    def libre(self) -> bool:
        return self.joueur_id is None

    def occupe(self) -> bool:
        return self.joueur_id is not None

    def public(self) -> Dict[str, Any]:
        """Projection diffusée à tous — jamais `ma_carte`, jamais `websocket`."""
        return {
            "siege": self.numero,
            "pseudo": self.pseudo,
            "present": self.present,
            "pret": self.pret,
            "est_bot": self.est_bot,
            "nb_cartes": self.nb_cartes,
        }


@dataclass
class Table:
    code: str
    type_partie: str
    cree_le: float = field(default_factory=time.time)
    sieges: List[Siege] = field(default_factory=list)
    createur_id: Optional[str] = None
    etat: str = "attente"
    seq: int = 0
    lance_le: Optional[float] = None
    terminee_le: Optional[float] = None
    raison_fin: Optional[str] = None
    url_partage: str = ""
    # Partie en cours (`serveur.jeu.partie.PartieEnLigne`). Typé `Any` pour
    # éviter l'importation circulaire : `partie` importe `table`, pas l'inverse.
    partie: Any = None

    # ------------------------------------------------------------------ #
    def siege(self, numero: int) -> Optional[Siege]:
        for un_siege in self.sieges:
            if un_siege.numero == numero:
                return un_siege
        return None

    @property
    def taille(self) -> int:
        return len(self.sieges)

    def siege_libre(self) -> Optional[Siege]:
        for siege in self.sieges:
            if siege.libre():
                return siege
        return None

    def siege_de(self, joueur_id: str) -> Optional[Siege]:
        for siege in self.sieges:
            if siege.joueur_id == joueur_id:
                return siege
        return None

    def nb_humains(self) -> int:
        return sum(1 for s in self.sieges if s.occupe() and not s.est_bot)

    def tous_prets(self) -> bool:
        return self.nb_humains() >= 2 and all(
            s.pret for s in self.sieges if s.occupe() and not s.est_bot
        )

    def prochain_seq(self) -> int:
        self.seq += 1
        return self.seq

    def a_des_sockets(self) -> bool:
        return any(s.websocket is not None for s in self.sieges)

    def est_expiree(self, maintenant: Optional[float] = None) -> bool:
        instant = time.time() if maintenant is None else maintenant
        if self.etat == "terminee":
            return instant - (self.terminee_le or instant) > 30.0
        if self.etat != "attente":
            return False
        if self.a_des_sockets():
            return False
        return instant - self.cree_le > DUREE_ATTENTE_S

    def liberer_reservations_perimees(self, maintenant: Optional[float] = None) -> int:
        """Libère les sièges réservés par REST mais jamais connectés."""
        instant = time.time() if maintenant is None else maintenant
        libres = 0
        if self.etat != "attente":
            return 0
        for siege in self.sieges:
            if (
                siege.occupe()
                and siege.websocket is None
                and siege.reserve_le
                and instant - siege.reserve_le > RESERVATION_S
                and siege.joueur_id != self.createur_id
            ):
                siege.joueur_id = None
                siege.pseudo = None
                siege.pret = False
                siege.reserve_le = 0.0
                libres += 1
        return libres

    # ------------------------------------------------------------------ #
    def instantane(self, mon_siege: Optional[int] = None) -> Dict[str, Any]:
        """`table_etat` filtré par destinataire (`docs/PROTOCOLE.md` §6).

        Les clés de partie (`pli`, `suivant`, `defi`, `fenetre_tape`) sont déjà
        présentes et nulles en `attente` : le client n'a qu'un seul contrat à
        implémenter, avant et après le lancement.
        """
        sieges = []
        for siege in self.sieges:
            projection = siege.public()
            if mon_siege is not None and siege.numero == mon_siege:
                projection["ma_carte"] = siege.ma_carte
            sieges.append(projection)
        return {
            "etat": self.etat,
            "type": self.type_partie,
            "sieges": sieges,
            "mon_siege": mon_siege,
            "pli": [],
            "reste_neutre": 0,
            "suivant": None,
            "defi": None,
            "fenetre_tape": None,
            "dernier_evenement": None,
        }

    def description_publique(self) -> Dict[str, Any]:
        """Ce que `GET /api/jeu/tables/{code}` expose : aucun identifiant interne."""
        return {
            "code": self.code,
            "type": self.type_partie,
            "etat": self.etat,
            "sieges": [
                {"siege": s.numero, "pseudo": s.pseudo, "pret": s.pret, "est_bot": s.est_bot}
                for s in self.sieges
            ],
        }


class GestionnaireTables:
    def __init__(self, max_tables: int = 200, origine: str = "", prefixe: str = "") -> None:
        self.max_tables = max(1, int(max_tables))
        self.origine = origine
        self.prefixe = prefixe
        self._tables: Dict[str, Table] = {}

    # ------------------------------------------------------------------ #
    def generer_code(self) -> str:
        """Code à 6 caractères, sans collision avec une table vivante."""
        for _ in range(64):
            code = "".join(secrets.choice(ALPHABET_CODE) for _ in range(LONGUEUR_CODE))
            if code not in self._tables:
                return code
        raise ErreurTable(
            "serveur_sature",
            "Le serveur est saturé, réessaie dans un instant.",
            statut=503,
            fermeture_ws=1013,
        )

    def url_partage(self, code: str) -> str:
        base = f"{self.origine}{self.prefixe}" if self.origine else self.prefixe
        return f"{base}/#table={code}"

    def actives(self) -> int:
        return len(self._tables)

    def sockets_ouverts(self) -> int:
        return sum(1 for table in self._tables.values() for s in table.sieges if s.websocket)

    def codes(self) -> List[str]:
        return sorted(self._tables)

    # ------------------------------------------------------------------ #
    def creer(self, type_partie: str, joueur_id: str, pseudo: str) -> Tuple[Table, Siege]:
        if type_partie not in TAILLES:
            raise ErreurTable(
                "type_inconnu", "Type de table inconnu.", statut=422, fermeture_ws=4410
            )
        if len(self._tables) >= self.max_tables:
            raise ErreurTable(
                "serveur_sature",
                "Le serveur est saturé, réessaie dans un instant.",
                statut=503,
                fermeture_ws=1013,
            )
        code = self.generer_code()
        table = Table(
            code=code,
            type_partie=type_partie,
            sieges=[Siege(numero=i) for i in range(TAILLES[type_partie])],
            createur_id=joueur_id,
            url_partage=self.url_partage(code),
        )
        self._tables[code] = table
        siege = table.sieges[0]
        siege.joueur_id = joueur_id
        siege.pseudo = pseudo
        siege.reserve_le = time.time()
        return table, siege

    def obtenir(self, code: str) -> Table:
        table = self._tables.get(self._normaliser(code))
        if table is None:
            raise ErreurTable(
                "table_introuvable",
                "Cette table n'existe pas ou a expiré.",
                statut=404,
                fermeture_ws=4404,
            )
        return table

    def rejoindre(self, code: str, joueur_id: str, pseudo: str) -> Tuple[Table, Siege]:
        table = self.obtenir(code)
        deja = table.siege_de(joueur_id)
        if deja is not None:
            return table, deja
        if table.etat not in ("attente", "en_jeu"):
            raise ErreurTable(
                "partie_deja_lancee",
                "La partie est déjà terminée.",
                statut=409,
                fermeture_ws=4409,
            )
        if table.etat == "en_jeu":
            # Reconnexion d'un joueur déjà connu gérée plus haut ; un inconnu
            # ne rejoint jamais une partie en cours.
            raise ErreurTable(
                "partie_en_cours",
                "La partie est déjà commencée.",
                statut=409,
                fermeture_ws=4409,
            )
        siege = table.siege_libre()
        if siege is None:
            raise ErreurTable(
                "table_pleine", "La table est complète.", statut=409, fermeture_ws=4409
            )
        siege.joueur_id = joueur_id
        siege.pseudo = pseudo
        siege.reserve_le = time.time()
        return table, siege

    def quitter(self, code: str, joueur_id: str) -> bool:
        """Libère le siège en `attente`. En `en_jeu`, le bot prend la suite (S2)."""
        table = self._tables.get(self._normaliser(code))
        if table is None or table.etat != "attente":
            return False
        siege = table.siege_de(joueur_id)
        if siege is None:
            return False
        siege.websocket = None
        siege.present = False
        siege.pret = False
        if siege.joueur_id != table.createur_id:
            siege.joueur_id = None
            siege.pseudo = None
        return True

    def fermer(self, code: str) -> bool:
        return self._tables.pop(self._normaliser(code), None) is not None

    def nettoyer(self, maintenant: Optional[float] = None) -> int:
        """Purge les tables expirées et les réservations périmées."""
        instant = time.time() if maintenant is None else maintenant
        fermees = 0
        for code in list(self._tables):
            table = self._tables[code]
            table.liberer_reservations_perimees(instant)
            if table.est_expiree(instant) and not table.a_des_sockets():
                del self._tables[code]
                fermees += 1
        return fermees

    @staticmethod
    def _normaliser(code: str) -> str:
        return (code or "").strip().upper()
