# Corsian-Battle — Bataille Corse

Jeu de cartes façon bataille corse : moteur de règles en **Python**, interface
 tactile en **Flutter** (cible Android, APK/AAB).

## Structure du dépôt

```
bataille_corse/       Moteur de règles (Python pur, testé hors UI)
app/                  Projet Flutter (ébauche visuelle de la table)
demo.py               Simulation de parties entre bots (valide le moteur)
```

### `bataille_corse/` — moteur

- `cartes.py` : paquet 52 cartes, codes poker (`AH`, `KC`, `TH`, …)
- `joueur.py` : tas face cachée, carte du dessus imposée
- `moteur.py` : règles complètes (figures/défis A4-K3-Q2-V1 avec rebonds,
  doublon prioritaire absolu, reste neutre du premier pli)
- `resolveur_tape.py` : « qui tape le premier » pluggable — bots crédibles
  en simulation, futur résolveur réseau (timecode mesuré localement côté
  client : reveal → tap, le plus court gagne)

Tester le moteur :

```
python3 demo.py
```

### `app/` — interface Flutter

Layout vertical complet : en-tête, tapis central, adversaires en arc (9h→3h),
tas joueur à 6h. Swipe = lancer, vitesse du geste pilote vol/tourbillon,
flip en plein vol, ramassage du pli au glissé.

**État : ébauche visuelle** — adversaires statiques, aucune connexion au
moteur ni réseau. Le placeholder carte s'affiche tant que les PNG
(`assets/cartes/`) manquent — voir `app/assets/cartes/README.md`.

Lancer (machine avec SDK) :

```
cd app
flutter pub get
flutter run
```

## Feuille de route

1. Câbler moteur ↔ UI (l'app pilote `BatailleCorse` ; détection vraie du
   « pli remporté » et du doublon)
2. Résolveur réseau WebSocket : chaque appli timecode reveal→tap localement
3. Pipeline build APK via GitHub Actions (récupération des artifacts, pas de
   PC nécessaire)
4. Assets PNG réels des cartes + effets sonores/commentaires
