# Corsian-Battle — Bataille Corse

Jeu de cartes façon bataille corse : moteur de règles en **Python**, interface
tactile en **Flutter** (cible Android, APK/AAB), multijoueur en ligne sur
FastAPI.

## Structure du dépôt

```
bataille_corse/       Moteur de règles (Python pur, testé hors UI)
app/                  Application Flutter (jeu local ET jeu en ligne)
serveur/              Backend FastAPI : corsian-auth (8111) + corsian-jeu (8112)
docs/                 Spécification du multijoueur (protocole, API, base, déploiement)
demo.py               Simulation de parties entre bots (valide le moteur)
```

### `bataille_corse/` — moteur

- `cartes.py` : paquet 52 cartes, codes poker (`AH`, `KC`, `TH`, …)
- `joueur.py` : tas face cachée, carte du dessus imposée
- `moteur.py` : règles complètes (figures/défis A4-K3-Q2-V1 avec rebonds,
  doublon prioritaire absolu, reste neutre du premier pli)
- `resolveur_tape.py` : « qui tape le premier » pluggable — bots crédibles
  en simulation, et **le même** point de branchement pour le réseau (chaque
  appli timecode reveal→tap localement, le plus court gagne)

C'est la **seule** implémentation des règles. Le serveur l'utilise tel quel ;
le port Dart (`app/lib/moteur/`) ne sert qu'au jeu hors-ligne.

Tester le moteur :

```
python3 demo.py
```

### `app/` — application Flutter

Layout vertical complet : en-tête, tapis central, adversaires en arc (9h→3h),
tas joueur à 6h. Swipe = lancer, vitesse du geste pilote vol/tourbillon,
flip en plein vol, ramassage du pli au glissé.

- **Jeu local** : duel 1v1 contre une machine qui épouse votre rythme, ou
  table à 4.
- **Jeu en ligne** : compte invité (identifiant d'appareil + pseudo), tables
  par code à 6 caractères, jeu en WebSocket. Le doublon se joue en tapant
  n'importe où sur le tapis ; le chronomètre part au rendu de l'animation,
  donc le délai comparé entre joueurs est **local**, jamais mural.

> **Le serveur décide, le client affiche.** `app/lib/net/` envoie des
> intentions et affiche ce que le serveur raconte ; elle ne rejoue jamais
> les règles.

Lancer :

```
cd app
flutter pub get
flutter run
```

Le mode en ligne a besoin du backend local :

```
bash serveur/lancer_local.sh
```

### `serveur/` — backend

Deux services FastAPI derrière nginx (443 est le seul point d'entrée public) :

- `corsian-auth` (8111) : comptes invités, JWT RS256, JWKS, suppression.
- `corsian-jeu` (8112) : tables, WebSocket de jeu, arbitrage des doublons.

```
bash serveur/lancer_local.sh     # les deux services en premier plan
```

## Build de l'APK

L'arbre `android/` est versionné. GitHub Actions construit l'APK à chaque
push sur `app/**` et publie l'artefact (avec son empreinte SHA-256) :

- `.github/workflows/build-apk.yml` — analyse statique + tests bloquants,
  puis `flutter build apk --debug`.

## Feuille de route

Voir [`docs/FEUILLE_DE_ROUTE.md`](docs/FEUILLE_DE_ROUTE.md) pour le détail des
étapes S0 → S5 et leurs critères d'acceptation. En bref : l'identité (S1),
la partie en ligne (S2) et le doublon en réseau (S3) sont livrés côté
serveur et côté client ; restent la publication (AAB signé, fiche Play) et
quelques décisions de conformité.
