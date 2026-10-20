"""Résolveur réseau : « qui tape le premier » (`docs/PROTOCOLE.md` §10).

Implémente le contrat de `bataille_corse.resolveur_tape.ResolveurTape` à
partir des **durées mesurées localement par chaque client** entre le début du
rendu de l'événement et l'appui du joueur. Aucune horloge murale n'est
comparée : on ne classe que des durées, ce qui rend la latence réseau sans
effet sur l'équité du verdict.

Le résolveur peut conclure que **personne** n'a tapé et renvoyer `None` : le
moteur laisse alors passer le doublon (adaptation rétrocompatible de
`bataille_corse/moteur.py`).

Usage par la table de jeu :

    resolveur = ResolveurTapeReseau(fenetre_ms=cfg.fenetre_tape_ms)
    # … pendant la fenêtre, à chaque message `tape` reçu :
    resolveur.enregistrer(pseudo_du_siege, delai_ms)
    # … à la clôture de la fenêtre, le moteur est actionné :
    jeu.resolveur_tape = resolveur
    jeu.jouer_un_coup()          # appelle determiner_gagnant()
    verdict = resolveur.verdict  # pour diffuser `doublon_resolu`

Contrainte : les `Joueur.nom` doivent être **uniques au sein d'une table** —
c'est garanti par l'unicité stricte des pseudos et par le nommage des bots.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple

from bataille_corse.resolveur_tape import ResolveurTape

# Valeurs par défaut alignées sur `docs/PROTOCOLE.md` §10.2 et servies à l'app
# par `GET /api/jeu/config` (rien n'est codé en dur côté client).
PLANCHER_MS = 120.0    # plancher physiologique : en dessous, douteux
REFUS_MS = 100.0       # rejet pur et simple + suspicion
FENETRE_MS = 900.0     # durée de la fenêtre de collecte

# Motifs consignés dans `anomalies`. Les deux premiers sont des rejets qui
# alimentent le compteur de suspicion ; `delai_sous_plancher` est accepté mais
# signalé ; les deux derniers sont de simples fins de non-recevoir.
SUSPICION = ("delai_impossible", "delai_invalide")
ANOMALIES = SUSPICION + ("delai_sous_plancher", "hors_fenetre", "deja_envoye", "fenetre_close")


@dataclass(frozen=True)
class TapeRecue:
    nom: str
    delai_ms: float
    ordre_arrivee: int


@dataclass
class VerdictTape:
    """Résultat exploitable par la table pour diffuser `doublon_resolu`."""

    gagnant_nom: Optional[str] = None
    delai_gagnant_ms: Optional[float] = None
    personne: bool = True
    retenus: Dict[str, float] = field(default_factory=dict)
    anomalies: Dict[str, str] = field(default_factory=dict)


class ResolveurTapeReseau(ResolveurTape):
    def __init__(
        self,
        plancher_ms: float = PLANCHER_MS,
        refus_ms: float = REFUS_MS,
        fenetre_ms: float = FENETRE_MS,
    ) -> None:
        self.plancher_ms = float(plancher_ms)
        self.refus_ms = float(refus_ms)
        self.fenetre_ms = float(fenetre_ms)
        self.anomalies: Dict[str, str] = {}
        self.verdict: Optional[VerdictTape] = None
        self._tapes: List[TapeRecue] = []
        self._refuses: Set[str] = set()
        self._ordre = 0
        self._clos = False

    # ------------------------------------------------------------------ #
    # Alimentation — appelée par la table, jamais par le moteur
    # ------------------------------------------------------------------ #
    def enregistrer(self, nom: str, delai_ms: object) -> Tuple[bool, Optional[str]]:
        """Renvoie `(accepté, motif)`.

        Seul le **premier** envoi d'un siège compte pendant une fenêtre :
        renvoyer dix fois `1 ms` ne donne aucun avantage.
        """
        if self._clos:
            return False, "fenetre_close"
        if nom in self._refuses or nom in self.anomalies or self._deja_recu(nom):
            motif = self.anomalies.setdefault(nom, "deja_envoye")
            return False, motif
        try:
            valeur = float(delai_ms)  # type: ignore[arg-type]
        except (TypeError, ValueError):
            self._refuses.add(nom)
            self.anomalies[nom] = "delai_invalide"
            return False, "delai_invalide"
        if valeur != valeur or valeur < 0.0:      # NaN ou négatif
            self._refuses.add(nom)
            self.anomalies[nom] = "delai_invalide"
            return False, "delai_invalide"
        if valeur < self.refus_ms:
            self._refuses.add(nom)
            self.anomalies[nom] = "delai_impossible"
            return False, "delai_impossible"
        if valeur > self.fenetre_ms:
            self._refuses.add(nom)
            self.anomalies[nom] = "hors_fenetre"
            return False, "hors_fenetre"
        self._ordre += 1
        self._tapes.append(TapeRecue(nom=nom, delai_ms=valeur, ordre_arrivee=self._ordre))
        if valeur < self.plancher_ms:
            # Accepté, mais signalé : il ne gagnera contre aucun délai ≥ plancher.
            self.anomalies[nom] = "delai_sous_plancher"
            return True, "delai_sous_plancher"
        return True, None

    def _deja_recu(self, nom: str) -> bool:
        return any(tape.nom == nom for tape in self._tapes)

    def cloturer(self) -> None:
        """Ferme la fenêtre : les `tape` ultérieurs ne sont plus collectés."""
        self._clos = True

    def reinitialiser(self) -> None:
        """Remet le résolveur à zéro pour le prochain doublon."""
        self.anomalies.clear()
        self._tapes.clear()
        self._refuses.clear()
        self._ordre = 0
        self._clos = False
        self.verdict = None

    def suspicions(self) -> List[Tuple[str, str]]:
        """Anomalies à consigner en base (`suspicions.type`), pour l'audit."""
        return [(nom, motif) for nom, motif in self.anomalies.items() if motif in SUSPICION]

    def nb_retenu(self) -> int:
        return len(self._tapes)

    # ------------------------------------------------------------------ #
    # Contrat ResolveurTape — appelé par le moteur
    # ------------------------------------------------------------------ #
    def determiner_gagnant(self, eligibles):
        """Plus petit délai **plausible** ; `None` si personne n'a tapé.

        Un délai sous le plancher physiologique (100 à 120 ms) ne gagne que si
        personne d'autre n'a tapé au-dessus du plancher. À égalité parfaite,
        l'ordre d'arrivée serveur départage — c'est le seul endroit où la
        latence réseau intervient.
        """
        par_nom = {joueur.nom: joueur for joueur in eligibles}
        valides = [tape for tape in self._tapes if tape.nom in par_nom]
        self._clos = True
        if not valides:
            self.verdict = VerdictTape(
                gagnant_nom=None,
                delai_gagnant_ms=None,
                personne=True,
                retenus={},
                anomalies=dict(self.anomalies),
            )
            return None
        solides = [tape for tape in valides if tape.delai_ms >= self.plancher_ms]
        candidats = solides or valides
        candidats.sort(key=lambda tape: (tape.delai_ms, tape.ordre_arrivee))
        choix = candidats[0]
        self.verdict = VerdictTape(
            gagnant_nom=choix.nom,
            delai_gagnant_ms=choix.delai_ms,
            personne=False,
            retenus={tape.nom: tape.delai_ms for tape in valides},
            anomalies=dict(self.anomalies),
        )
        return par_nom[choix.nom]
