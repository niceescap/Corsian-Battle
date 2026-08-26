import 'package:flutter/material.dart';
import '../modeles.dart';

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.rotate(
          angle: angleRad,
          child: CustomPaint(
            size: const Size(28, 36),
            painter: _FlechePainter(intensite: joueur.intensite),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          joueur.pseudo,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
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
