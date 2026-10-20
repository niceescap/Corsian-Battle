# Corsian-Battle — Feuille de route du multijoueur

> Découpage en six étapes, chacune **livrable et vérifiable seule**. Aucune étape ne dépend
> d'une décision prise à l'étape suivante.
>
> **État actuel : S0 partiellement dégelée.** Racine statique vérifiée (`index.html` = landing
> officielle 15 Ko + `static/` avec `logo_og.png` et `logo_site.png`, **à conserver tels quels**)
> et domaine tranché (`soft.opik.net/corsian-battle/` en V1). Restent en attente : les deux blocs
> `location` API, la directive `proxy_buffering off` sur le WS, et la validation du budget
> mémoire (`DEPLOIEMENT.md` §10). Aucun code applicatif écrit à ce stade.

---

## Vue d'ensemble

| Étape | Objectif | Débloque | Dépend de |
|---|---|---|---|
| **S0** | Socle vérifiable : 2 services qui répondent, nginx câblé, site en ligne | Tout le reste | points ⏳ |
| **S1** | Identité : compte invité, JWT, suppression de compte | Jouer en étant reconnu | S0 |
| **S2** | Première partie en ligne : table privée par code, 2 joueurs | Une vraie partie à deux | S1 |
| **S3** | Le cœur du jeu : doublon en réseau, information cachée, reconnexion, table de 4 | Le jeu complet et loyal | S2 |
| **S4** | Vie du service : matchmaking, stats, classement, signalement/blocage | Jouer sans amis sous la main | S3 |
| **S5** | Publication : arbre `android/` commité, release signée, AAB, Play Console | Le grand public | S3 (S4 non bloquant) |

## S0 — Socle

**Livrables** : squelettes `corsian-auth` (8111) et `corsian-jeu` (8112) avec `/sante` et
`/config`, création de la base et application de la migration `001_initial.sql`, units systemd,
blocs nginx API + `proxy_buffering off` sur le WS existant, pages statiques **nouvelles**
`privacy.html`, `terms.html`, `suppression-compte.html` (coquille), `support.html`. La landing
`index.html` (15 Ko) et son dossier `static/` ne sont **pas touchés**.

**Critères d'acceptation**

- [ ] `ss -ltnp` montre les deux services sur `127.0.0.1:8111` et `:8112`, rien sur `0.0.0.0`
- [ ] `curl -i https://soft.opik.net/corsian-battle/api/auth/sante` → `200`, `"etat":"ok"`
- [ ] `curl -i https://soft.opik.net/corsian-battle/api/jeu/sante` → `200`
- [ ] `curl -i -N -H "Connection: Upgrade" …/corsian-battle/ws` → **`101 Switching Protocols`**
- [ ] `https://soft.opik.net/corsian-battle/privacy.html` s'affiche sans compte ni application
- [ ] `https://soft.opik.net/corsian-battle/` affiche toujours la landing existante, logos inclus
      (empreinte SHA-256 de `index.html` identique avant/après dépôt)
- [ ] `free -m` après 30 min : les deux services restent sous leur `MemoryMax`, swap stable
- [ ] `systemctl restart corsian-jeu` → redémarrage propre, `/sante` de nouveau `ok` en < 5 s

**Répartition** : Nicolas — deux blocs `location` API, `proxy_buffering off` sur le WS,
`nginx -t`, units systemd, démarrage. Assistant — code des squelettes, migrations, pages
statiques nouvelles, recette.

## S1 — Identité

**Livrables** : `POST /api/auth/invite`, rafraîchissement avec rotation, `GET/PATCH /profil`,
JWKS, filtre de pseudo, suppression de compte (app + web via code), vérification du JWT côté
`corsian-jeu`.

**Critères d'acceptation**

- [ ] Deux installations de l'app sur deux appareils → deux comptes distincts
- [ ] Redémarrage de l'app → même compte, sans aucune saisie (idempotence par UUID appareil)
- [ ] Jeton d'accès expiré → renouvellement transparent, aucune perte de session utilisateur
- [ ] Jeton de rafraîchissement volé et réutilisé → révocation de toute la chaîne
- [ ] Pseudo injurieux refusé à la création ; pseudo en double refusé (insensible casse/accents)
- [ ] Suppression depuis l'app → le compte ne peut plus se connecter, les données ont disparu
      de la base (vérification `sqlite3` directe)
- [ ] Suppression depuis `suppression-compte.html` **sans l'app installée**, avec un code
- [ ] Une partie jouée par un compte supprimé reste visible et cohérente pour les autres
      joueurs (siège « Joueur »)

**Piège connu** : ne jamais faire tourner une attente réseau dans une transaction SQLite
(`ARCHITECTURE.md` §7 / `SCHEMA_BD.md` §2.4).

## S2 — Première partie en ligne (2 joueurs)

**Livrables** : création de table par REST, code à 6 caractères, page `#table=CODE`, WebSocket
avec `bonjour`/`table_etat`, moteur autoritaire branché sur `bataille_corse`, coups `poser_carte`,
tour de jeu avec délai de 12 s, fin de partie, enregistrement en base, déconnexion → bot.

**Critères d'acceptation**

- [ ] Deux téléphones sur le même réseau, puis **sur deux réseaux différents** (4G + wifi)
- [ ] Une partie complète se déroule jusqu'à la victoire sans intervention
- [ ] Les règles affichées en ligne sont **identiques** au hors-ligne : mêmes défis, mêmes
      rebonds, mêmes plis (comparer avec `demo.py` sur le même `seed`)
- [ ] Coupure réseau de 10 s → reconnexion et reprise, la table n'est pas perdue
- [ ] Coupure de 60 s → le bot joue, la partie va à son terme, le joueur revenu récupère son siège
- [ ] Redémarrage de `corsian-jeu` en pleine partie → table restaurée depuis le snapshot
- [ ] Le client **ne reçoit jamais** autre chose que sa propre carte du dessus (vérification par
      capture du trafic WebSocket)

## S3 — Le cœur : doublon, loyauté, table de 4

**Livrables** : `ResolveurTapeReseau`, fenêtre de 900 ms, bornes de plausibilité et suspicions,
cas « personne n'a tapé » (adaptation rétrocompatible du moteur), table de 4 joueurs,
reconnexion avec `resynchroniser`, statistiques de tape par joueur.

**Critères d'acceptation**

- [ ] Deux joueurs tapent : le plus rapide **en délai local** gagne, quel que soit son ping
- [ ] Un `delai_ms` de 40 est rejeté et consigné ; un de 130 est accepté
- [ ] Personne ne tape → la partie continue, le pli n'est attribué à personne, aucun blocage
- [ ] 200 parties simulées en tête-à-tête réseau sans plantage ni table bloquée
      (client headless, script rejouable)
- [ ] Table de 4 : un joueur sans carte peut toujours taper pour revenir en jeu
- [ ] Le défi et le doublon simultanés sont traités dans le bon ordre (le doublon prime)
- [ ] Aucune fuite d'information : un client instrumenté ne peut pas deviner la carte suivante
      d'un adversaire

## S4 — Vie du service

**Livrables** : file d'attente et appariement, classement, historique, signalements, blocages,
`/maintenance`, purge automatique (sessions expirées, snapshots orphelins, signalements
traités), sauvegarde quotidienne par timer.

**Critères d'acceptation**

- [ ] Deux joueurs inconnus sont appariés en moins de 30 s en heure pleine
- [ ] Deux joueurs qui se bloquent mutuellement ne sont jamais appariés
- [ ] Un signalement apparaît dans la file de modération et peut être traité
- [ ] Le classement exclut les bots et les comptes supprimés
- [ ] La sauvegarde quotidienne produit un fichier restaurable (test de restauration réel)
- [ ] `POST /api/jeu/maintenance` coupe les nouvelles tables sans interrompre les parties en cours

## S5 — Publication

**Prérequis structurel** : **commiter un vrai arbre `android/`** et modifier `build-apk.yml` en
conséquence. Sans cela : pas d'AAB signé, pas d'AdMob, pas d'App Links, pas de nom d'application
correct sous l'icône.

**Livrables** : `android/` versionné, icône adaptative + nom « Corsian Battle », workflow de
release (tag + APK/AAB signés + publication GitHub), keystore sécurisé, AAB téléversé sur Play
Console, fiche produit (captures, description, classification IARC, Data Safety, URL de
politique de confidentialité et de suppression), test interne → test fermé → production.

**Critères d'acceptation**

- [ ] `flutter build appbundle --release` produit un AAB signé, installable en test interne
- [ ] Le nom sous l'icône est « Corsian Battle », pas `bataille_corse`
- [ ] Le Data Safety est cohérent avec `CONFORMITE.md` §4
- [ ] L'URL de suppression de compte fonctionne depuis un navigateur sans app installée
- [ ] L'app passe la revue Play sans demande de correction

---

## Ce qui peut avancer **pendant** le gel d'infrastructure

Travaux sans aucune dépendance à la topologie nginx/ports — à autoriser au cas par cas :

| Travail | Fichiers | Risque |
|---|---|---|
| `ResolveurTapeReseau` + adaptation rétrocompatible « personne n'a tapé » | `serveur/`, `bataille_corse/resolveur_tape.py` | nul : testable hors ligne |
| Filtre de pseudo (liste, normalisation) | `serveur/commun/pseudo.py` | nul |
| Client headless de test (joue des parties complètes) | `serveur/tests/` | nul |
| Tests de non-régression du moteur (défis, rebonds, doublons, reste neutre) | `bataille_corse/`, `demo.py` | nul — utile dès aujourd'hui |
| Texte définitif de `privacy.html` / `terms.html` | `site/` | nul, mais **3 champs à trancher** (`CONFORMITE.md` §3.2) |
| Écran « Compte » dans l'app (pseudo, suppression, lien politique) | `app/lib/screens/` | faible, ne suppose aucun serveur |
| Décision sur le nom de paquet définitif | — | **irréversible après publication** |

## Décisions en attente (hors infrastructure)

1. Nom de paquet final : `fr.niceescap.bataille_corse` (existant) ou `fr.niceescap.corsianbattle`.
2. Adresse électronique de contact pour la politique de confidentialité et le support.
3. Publicité : V1 sans AdMob (recommandé, `CONFORMITE.md` §9) ou avec.
4. ✅ **Tranché** — `soft.opik.net/corsian-battle/` en V1 (nginx déjà câblé, aucun certificat à
   émettre) ; `jeu.opik.net` reporté en V2, seulement si un besoin concret apparaît (App Links
   natifs, cookies de premier niveau, isolation des limites de débit).
5. Unicité stricte des pseudos en V1 (choix actuel) ou pseudos libres avec discriminant.
