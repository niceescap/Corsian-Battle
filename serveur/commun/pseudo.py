"""Filtre de pseudos — verrou n°1 de l'obligation UGC de Google Play.

Le pseudo est la seule donnée qu'un joueur crée et qui soit visible des
autres (il n'y a pas de chat en V1). Play exige malgré tout filtrage,
signalement, blocage et modération : voir `docs/CONFORMITE.md` §6.

Ce module est **pur** (aucune E/S, aucune dépendance à FastAPI) donc
testable immédiatement : `python3 -m pytest serveur/tests/test_pseudo.py`.

Règles appliquées à la création et à chaque changement de pseudo :

1. longueur 2 à 20 caractères, espaces internes réduits à un seul ;
2. jeu de caractères restreint : lettres (accentuées comprises), chiffres,
   espace, tiret, tiret bas, point — ni emoji, ni caractère de contrôle,
   ni ponctuation exotique ;
3. au moins une lettre (pas de pseudo purement numérique) ;
4. aucune coordonnée : pas de `@`, pas d'URL, pas de TLD ;
5. aucun terme interdit (liste ci-dessous, extensible par l'environnement
   `PSEUDO_INTERDITS`) ;
6. unicité gérée ailleurs sur `pseudo_min()` (casse et accents neutralisés).

La détection d'interdits combine trois tests pour limiter les faux positifs
tout en résistant au contournement (`c.o.n`, `CON`, `C0n`) :
- égalité du pseudo compacté avec un terme interdit ;
- égalité d'un **mot** du pseudo avec un terme interdit ;
- inclusion d'un terme interdit **long** (≥ 5 lettres) dans le pseudo
  compacté. Un terme court n'est donc jamais cherché en sous-chaîne :
  « Second » ou « Facond » ne sont pas refusés à cause de « con ».
"""
from __future__ import annotations

import os
import re
import unicodedata
from typing import List, Optional, Set, Tuple

LONGUEUR_MIN = 2
LONGUEUR_MAX = 20

# Lettres (y compris accentuées), chiffres, espace, tiret, tiret bas, point.
_CARACTERES_OK = re.compile(r"^[\w .\-]+$", re.UNICODE)
_SEPARE_EN_MOTS = re.compile(r"[^0-9a-z]+")
_TLD = re.compile(r"\.(fr|com|net|org|io|eu|gg|be|ch|ca|uk|de|es|it|xyz|info)\b")

# Codes d'erreur renvoyés (affichés par l'app en pictogramme, jamais en clair
# pendant une partie) et messages associés côté API.
MESSAGES = {
    "pseudo_vide": "Choisis un pseudo.",
    "pseudo_trop_court": "Le pseudo doit faire au moins 2 caractères.",
    "pseudo_trop_long": "Le pseudo doit faire au plus 20 caractères.",
    "caracteres_refuses": "Lettres, chiffres, espace, tiret et point uniquement.",
    "pseudo_sans_lettre": "Le pseudo doit contenir au moins une lettre.",
    "pseudo_contient_coordonnees": "Pas d'adresse ni de lien dans un pseudo.",
    "pseudo_interdit": "Ce pseudo n'est pas accepté.",
}

# ---------------------------------------------------------------------------
# Termes interdits. Liste volontairement courte et assumée : elle n'a pas
# vocation à être exhaustive mais à bloquer l'évident. Elle s'étend sans
# modification de code via la variable d'environnement PSEUDO_INTERDITS
# (termes séparés par des virgules, en minuscules, sans accent).
# ---------------------------------------------------------------------------
_INTERDITS_DE_BASE: Tuple[str, ...] = (
    # vulgarité et insultes — français
    "con", "conne", "connard", "connasse", "cul", "encule", "enculer",
    "fdp", "merde", "nique", "niquer", "ntm", "pd", "pute", "putain",
    "salaud", "salope", "tg", "chie", "chier", "branleur",
    # vulgarité et insultes — anglais
    "asshole", "bastard", "bitch", "cunt", "dick", "fag", "fuck", "fucker",
    "nigger", "nigga", "shit", "whore",
    # haine, apologie, extrémisme
    "nazi", "nazisme", "hitler", "juifsale", "terroriste", "pedophile",
    "pedophile00", "viol", "violeur",
    # usurpation d'identité de la maison ou des modérateurs
    "admin", "administrateur", "modo", "moderateur", "moderator", "officiel",
    "official", "support", "corsianbattle", "corsian_battle", "corsian",
)


def _interdits() -> Set[str]:
    """Liste de base + apports de l'environnement (lus à chaque appel pour
    permettre un test qui modifie `os.environ`)."""
    complement = os.environ.get("PSEUDO_INTERDITS", "")
    termes = {terme.strip().lower() for terme in complement.split(",")}
    termes.discard("")
    return set(_INTERDITS_DE_BASE) | termes


def sans_accents(texte: str) -> str:
    """`Élodie` → `Elodie`. Utilisé pour l'unicité et la détection d'interdits."""
    decompose = unicodedata.normalize("NFKD", texte)
    return "".join(c for c in decompose if not unicodedata.combining(c))


def compacter(texte: str) -> str:
    """Pseudo réduit à `[a-z0-9]` : `C.o.n !` → `con`, `Nina_42` → `nina42`.

    C'est la forme utilisée pour déjouer les contournements évidents.
    """
    return re.sub(r"[^a-z0-9]+", "", sans_accents(texte).lower())


def mots(texte: str) -> List[str]:
    """Découpe en mots compacts : `Nina la Chipie` → `["nina","la","chipie"]`."""
    nettoye = re.sub(r"[^0-9a-z]+", " ", sans_accents(texte).lower())
    return [mot for mot in _SEPARE_EN_MOTS.split(nettoye) if mot]


def pseudo_min(pseudo: str) -> str:
    """Clé d'unicité stockée en base : casse, accents et séparateurs neutralisés.

    `Élodie`, `elodie` et `É L O D I E` donnent la même clé. SQLite `NOCASE`
    ne gère pas les accents, d'où cette colonne dédiée (`docs/SCHEMA_BD.md` §4).
    """
    return compacter(pseudo)


def contient_interdit(pseudo: str) -> bool:
    compact = compacter(pseudo)
    interdits = _interdits()
    if not compact:
        return False
    if compact in interdits:
        return True
    if any(mot in interdits for mot in mots(pseudo)):
        return True
    return any(long in compact for long in interdits if len(long) >= 5)


def nettoyer(brut: object) -> Optional[str]:
    """Normalise les espaces et supprime les caractères de contrôle."""
    if brut is None:
        return None
    if not isinstance(brut, str):
        return None
    # `split()` sans argument retire tous les blancs (y compris \n, \t, \x00
    # après filtrage) et les regroupe proprement.
    controle = "".join(c for c in brut if unicodedata.category(c)[0] != "C" or c == " ")
    net = " ".join(controle.split())
    return net or None


def valider(brut: object) -> Tuple[Optional[str], Optional[str]]:
    """Renvoie `(pseudo_propre, None)` ou `(None, code_erreur)`.

    Le pseudo propre est celui qui sera stocké et affiché : espaces simples,
    casse et accents d'origine conservés.
    """
    net = nettoyer(brut)
    if not net:
        return None, "pseudo_vide"
    if len(net) < LONGUEUR_MIN:
        return None, "pseudo_trop_court"
    if len(net) > LONGUEUR_MAX:
        return None, "pseudo_trop_long"
    if not _CARACTERES_OK.match(net):
        return None, "caracteres_refuses"
    if not any(c.isalpha() for c in net):
        return None, "pseudo_sans_lettre"
    if "@" in net or _TLD.search(net.lower()) or "http" in compacter(net) or "www" in compacter(net):
        return None, "pseudo_contient_coordonnees"
    if contient_interdit(net):
        return None, "pseudo_interdit"
    return net, None


def message_erreur(code: Optional[str]) -> str:
    return MESSAGES.get(code or "", "Ce pseudo n'est pas accepté.")
