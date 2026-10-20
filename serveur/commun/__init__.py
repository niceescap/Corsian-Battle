"""Briques partagées par corsian-auth et corsian-jeu.

Aucun module de ce paquet ne connaît le réseau : ils sont testables seuls.

- `config`  : lecture de l'environnement (noms de `docs/DEPLOIEMENT.md` §3)
- `bd`      : accès SQLite WAL + migrations (`docs/SCHEMA_BD.md`)
- `jwt`     : émission RS256 (auth) et vérification par JWKS (jeu)
- `pseudo`  : filtre UGC des pseudos (`docs/CONFORMITE.md` §6)
- `limites` : limiteur de débit glissant, en mémoire
"""
