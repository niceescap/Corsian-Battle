# Bataille Corse — ébauche Flutter

Ébauche de l'écran de jeu, basée sur le schéma décrit : head léger,
tapis central avec adversaires en arc (9h à 3h), tas du joueur à 6h
avec swipe pour jouer, dynamique de lancer liée à la vitesse du geste.

## Ce qui est implémenté dans cette ébauche

- Layout vertical complet : en-tête, tapis, arc d'adversaires, tas joueur.
- Flèches adverses à 3 états (épaisse / fine / creuse) selon le nombre
  de cartes.
- Geste de swipe sur le tas du joueur → lancer d'une carte, avec vitesse
  du relâchement du doigt qui pilote la durée du vol et l'intensité du
  tourbillon (rapide = vol court et vif, lent = suspens).
- La carte du joueur reste dos visible jusqu'au lancer (il ne connaît
  jamais sa carte à l'avance, conformément à la règle) et se retourne
  en plein vol.
- Dépôt au centre avec léger décalage aléatoire (aspect anarchique du
  pli) et rotation finale aléatoire.
- Geste de "ramassage" du pli (glisser vers le tas) une fois le pli
  jouable, avec cartes qui suivent la progression du geste.
- Système de cartes via `CarteWidget`, compatible avec les codes poker
  générés par `cartes.py` (AH, KC, TH...), placeholder généré si l'asset
  PNG n'existe pas encore.
- Point d'accroche pour les effets (`lib/effets.dart`) : popup animé et
  flash plein écran, avec quelques lignes de commentaire d'exemple.

## Ce qui est simulé / à faire (pas dans cette ébauche)

- **Aucune connexion réseau** : les adversaires sont statiques
  (`_adversaires` dans `ecran_table.dart`), et la détection "pli
  remporté" est une condition factice (`_pli.length >= 4`). Le vrai
  déclenchement viendra du moteur Python (`bataille_corse/moteur.py`)
  via le canal réseau à définir (WebSocket a priori, vu le besoin de
  timecoder chaque appli dès le début de l'animation de dépose).
- **Doublon / défi** : aucune détection de doublon ni d'enchaînement de
  défi n'est câblée ici — l'ébauche ne montre que la mécanique de
  lancer/ramassage, pas les règles.
- **Système de bonus** (cases en haut à gauche) : emplacements visuels
  seulement, l'usage reste à définir.
- **Commentaires excités et audio** : seulement des lignes d'exemple en
  dur, pas d'intégration sonore.
- **Assets réels** : le dossier `assets/cartes/` est vide (voir son
  propre README) ; un placeholder texte s'affiche à la place.

## Lancer le projet

```
flutter pub get
flutter run
```

Cette ébauche n'a pas pu être compilée dans cet environnement (pas de
SDK Flutter disponible ici) — à tester directement sur ta VM.
