import 'package:flutter/material.dart';
import 'carte_widget.dart';

/// Callback quand le joueur lance sa carte du dessus.
/// [vitessePixelsSeconde] = norme de la vitesse de relâchement du doigt,
/// module toute la dynamique du lancer (rapide = jeté vif et rapide,
/// lent et contrôlé = suspens et dépose en douceur).
typedef OnCarteJouee = void Function(double vitessePixelsSeconde);

/// Tas du joueur, positionné à 6h. Note importante : la carte du dessus
/// reste TOUJOURS dos visible ici, même pour son propriétaire — la règle
/// du jeu veut qu'un joueur ne connaisse jamais sa carte avant de la
/// jouer (elle n'est révélée qu'une fois lancée au centre).
class TasJoueur extends StatefulWidget {
  final int nombreCartes;
  final double largeurCarte;
  final double hauteurCarte;
  final OnCarteJouee onCarteJouee;

  const TasJoueur({
    super.key,
    required this.nombreCartes,
    required this.onCarteJouee,
    this.largeurCarte = 76,
    this.hauteurCarte = 108,
  });

  @override
  State<TasJoueur> createState() => _TasJoueurState();
}

class _TasJoueurState extends State<TasJoueur> {
  Offset _decalageDoigt = Offset.zero;

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() => _decalageDoigt += details.delta);
  }

  void _onPanEnd(DragEndDetails details) {
    final vitesse = details.velocity.pixelsPerSecond.distance;
    // Un petit mouvement franc ou un relâchement avec de la vitesse
    // suffit à valider le lancer (le "suspens" du swipe lent doit quand
    // même pouvoir jouer la carte).
    if (_decalageDoigt.distance > 12 || vitesse > 150) {
      widget.onCarteJouee(vitesse);
    }
    setState(() => _decalageDoigt = Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nombreCartes <= 0) {
      return SizedBox(
        width: widget.largeurCarte,
        height: widget.hauteurCarte * 0.75,
      );
    }

    // 75 % de la hauteur visible : le tas "sort" du bas de l'écran.
    return Transform.translate(
      offset: Offset(0, widget.hauteurCarte * 0.25),
      child: GestureDetector(
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            // Cartes du dessous, légèrement décalées pour donner du
            // volume au tas.
            for (int i = 3; i >= 1; i--)
              Positioned(
                bottom: -i * 1.5,
                child: Opacity(
                  opacity: 0.85,
                  child: CarteWidget(
                    largeur: widget.largeurCarte,
                    hauteur: widget.hauteurCarte,
                  ),
                ),
              ),
            // La carte du dessus : celle qu'on swipe. Dos visible.
            Transform.translate(
              offset: _decalageDoigt,
              child: Transform.rotate(
                angle: _decalageDoigt.dx / 400,
                child: CarteWidget(
                  largeur: widget.largeurCarte,
                  hauteur: widget.hauteurCarte,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
