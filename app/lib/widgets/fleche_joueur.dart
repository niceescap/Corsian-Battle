import 'package:flutter/material.dart';
import '../modeles.dart';
import 'carte_widget.dart';

/// Pastille d'un adversaire de la table à 4 (disposition en arc).
///
/// Minimaliste et UNIVERSELLE : aucun mot descriptif. On y lit
/// - une flèche dont l'intensité traduit l'état du joueur (pleine / fine /
///   creuse quand il est à sec mais encore en jeu), orientée vers le centre ;
/// - le NOM (nom propre, seul texte conservé) ;
/// - un dos de paquet + le NOMBRE de cartes (chiffre universel).
class FlecheJoueur extends StatelessWidget {
  final JoueurUI joueur;

  /// Orientation de la flèche, pointe vers le centre du tapis.
  final double angleRad;

  const FlecheJoueur({
    super.key,
    required this.joueur,
    required this.angleRad,
  });

  @override
  Widget build(BuildContext context) {
    final aSec = joueur.nombreCartes <= 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          angle: angleRad,
          child: CustomPaint(
            size: const Size(26, 32),
            painter: _FlechePainter(intensite: joueur.intensite),
          ),
        ),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.34),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: aSec ? Colors.white24 : const Color(0xFFFFD54F).withOpacity(0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Dos de paquet miniature = identité visuelle de l'adversaire.
              Transform.scale(
                scale: 0.9,
                child: CarteWidget(largeur: 16, hauteur: 23),
              ),
              const SizedBox(width: 6),
              Text(
                joueur.pseudo,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  '${joueur.nombreCartes}',
                  style: TextStyle(
                    color: aSec ? Colors.white38 : const Color(0xFFFFD54F),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FlechePainter extends CustomPainter {
  final IntensiteFleche intensite;

  _FlechePainter({required this.intensite});

  @override
  void paint(Canvas canvas, Size size) {
    final double demiLargeur = switch (intensite) {
      IntensiteFleche.epaisse => size.width / 2,
      IntensiteFleche.fine => size.width / 5,
      IntensiteFleche.creuse => size.width / 5,
    };

    final chemin = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width / 2 + demiLargeur, size.height)
      ..lineTo(size.width / 2, size.height * 0.75)
      ..lineTo(size.width / 2 - demiLargeur, size.height)
      ..close();

    final peinture = Paint();
    if (intensite == IntensiteFleche.creuse) {
      peinture
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white54;
    } else {
      peinture
        ..style = PaintingStyle.fill
        ..color = Colors.amberAccent;
    }

    canvas.drawPath(chemin, peinture);
  }

  @override
  bool shouldRepaint(covariant _FlechePainter oldDelegate) =>
      oldDelegate.intensite != intensite;
}
