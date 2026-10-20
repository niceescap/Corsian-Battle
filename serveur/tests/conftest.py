"""Rend le dépôt importable quel que soit le dossier d'où les tests sont lancés.

`serveur.*` importe `bataille_corse.*` : les deux paquets sont à la racine du
dépôt, donc c'est cette racine qu'il faut ajouter à `sys.path`.

    python3 -m pytest serveur/tests           # depuis la racine du dépôt
    python3 serveur/tests/test_pseudo.py      # sans pytest, depuis n'importe où
"""
from __future__ import annotations

import sys
from pathlib import Path

RACINE_DEPOT = Path(__file__).resolve().parents[2]

if str(RACINE_DEPOT) not in sys.path:
    sys.path.insert(0, str(RACINE_DEPOT))
