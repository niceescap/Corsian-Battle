"""Backend de Corsian-Battle.

Deux services indépendants, un seul dépôt :

- `serveur.auth`  → corsian-auth, `127.0.0.1:8111` : comptes, jetons, suppression.
- `serveur.jeu`   → corsian-jeu,  `127.0.0.1:8112` : tables, WebSocket, arbitrage.

Les règles du jeu ne sont **pas** réimplémentées ici : `serveur.jeu` importe
`bataille_corse`, qui reste la seule autorité (voir `docs/ARCHITECTURE.md` §6).

Lancement depuis la racine du dépôt :

    uvicorn serveur.auth.main:app --host 127.0.0.1 --port 8111 --workers 1
    uvicorn serveur.jeu.main:app  --host 127.0.0.1 --port 8112 --workers 1

`--workers 1` est obligatoire : l'état des tables vit dans le processus.
"""
