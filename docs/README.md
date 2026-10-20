# Dossier — multijoueur en ligne

Spécification du jeu en réseau de **Corsian-Battle**. Aucune ligne de code applicatif dans ce
dossier : ce sont les documents de référence qui précèdent l'implémentation.

| Document | Contenu | À lire quand |
|---|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Principes, topologie, ports 8111/8112, les deux services, réutilisation du moteur Python, sécurité, anti-triche, reprise sur panne | Pour comprendre **pourquoi** c'est fait comme ça |
| [`PROTOCOLE.md`](PROTOCOLE.md) | WebSocket : enveloppes, `seq`, cycle de vie d'une table, tous les messages, déroulé d'un coup, fenêtre de doublon, reconnexion, codes de fermeture | Pour écrire le client **ou** le serveur de jeu |
| [`ENDPOINTS.md`](ENDPOINTS.md) | REST des deux services, conventions d'erreur, limites de débit, recette de vérification `curl` | Pour câbler l'app au serveur |
| [`SCHEMA_BD.md`](SCHEMA_BD.md) | SQLite WAL : DDL complet, index, requêtes types, suppression de compte, sauvegarde, migrations | Avant toute écriture en base |
| [`DEPLOIEMENT.md`](DEPLOIEMENT.md) | noe : arborescence, venv, variables, units systemd durcies, blocs nginx, recette de mise en service, exploitation, contraintes CI | Au moment d'installer |
| [`CONFORMITE.md`](CONFORMITE.md) | Google Play : Data Safety, suppression de compte, UGC, classification IARC, iOS/TestFlight, texte de politique de confidentialité prêt à publier | Avant de soumettre |
| [`FEUILLE_DE_ROUTE.md`](FEUILLE_DE_ROUTE.md) | Étapes S0 → S5, critères d'acceptation, travaux possibles pendant le gel, décisions en attente | Pour savoir **quoi faire ensuite** |

## Rappels utiles

- **Autorité** : le serveur décide, le client affiche. Une seule implémentation des règles :
  `bataille_corse/moteur.py`.
- **Ports** : `corsian-auth` = `127.0.0.1:8111`, `corsian-jeu` = `127.0.0.1:8112` (REST + WS).
  Bind loopback uniquement ; nginx 443 est le seul point d'entrée public.
- **Public** : `https://soft.opik.net/corsian-battle/` → site statique, `/api/auth/*`,
  `/api/jeu/*`, `/ws`.
- **Base** : SQLite WAL, `~/corsian-battle/var/corsian.db`. L'état vivant des tables reste en
  mémoire.
- **Gel en cours** : pas d'installation tant que la racine statique n'est pas inspectée et que
  les blocs `location` API ne sont pas posés (`DEPLOIEMENT.md` §10).
