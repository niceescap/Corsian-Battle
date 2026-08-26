# Assets des cartes

Dépose ici tes PNG personnalisés, nommés selon le code poker généré par
`Carte.code` côté moteur Python (`bataille_corse/cartes.py`) :

- Rang : `A, 2, 3, 4, 5, 6, 7, 8, 9, T, J, Q, K` (T = dix)
- Couleur : `S` (Pique), `H` (Cœur), `D` (Carreau), `C` (Trèfle)

Exemples : `AH.png`, `KC.png`, `TH.png`, `9S.png`, `7D.png`.

Le dos commun à toutes les cartes : `back.png`.

Tant que les fichiers ne sont pas présents, l'appli affiche un
placeholder généré (rectangle avec le code écrit dessus) — voir
`CarteWidget` dans `lib/widgets/carte_widget.dart`.
