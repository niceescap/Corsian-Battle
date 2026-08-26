import 'dart:math';
import 'package:flutter/material.dart';
import 'carte_widget.dart';

/// Carte en plein vol entre le tas du joueur et le centre du tapis.
///
/// La dynamique dépend de la vitesse de relâchement du doigt :
/// - rapide -> vol court, tourbillon marqué (jeté vif)
/// - lente et contrôlée -> vol plus long, quasi pas de tourbillon (suspens)
///
/// La carte se retourne (dos -> face) en cours de vol : elle n'est
/// révélée qu'une fois "engagée", jamais avant.
class CarteVolante extends StatefulWidget {
  final Offset depart;
  final Offset arrivee;
  final double vitessePixelsSeconde;
  final String codeCarte;
  final double rotationFinale;
  final VoidCallback onAtterrissage;

  const CarteVolante({
    super.key,
    required this.depart,
    required this.arrivee,
    required this.vitessePixelsSeconde,
    required this.codeCarte,
    required this.rotationFinale,
    required this.onAtterrissage,
  });

  @override
  State<CarteVolante> createState() => _CarteVolanteState();
}

class _CarteVolanteState extends State<CarteVolante>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controleur;
  late final Animation<Offset> _position;
  late final Animation<double> _retournement; // 0 -> pi (dos vers face)
  late final Animation<double> _tourbillon;

  @override
  void initState() {
    super.initState();

    final vitesse = widget.vitessePixelsSeconde.clamp(150.0, 3000.0);
    // Rapide -> vol court (~250ms) ; lent -> vol long et suspendu (~750ms).
    final fraction = (vitesse - 150) / (3000 - 150);
    final dureeMs = (750 - fraction * 500).round();

    _controleur = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: dureeMs),
    );

    _position = Tween<Offset>(begin: widget.depart, end: widget.arrivee).animate(
      CurvedAnimation(parent: _controleur, curve: Curves.easeOutCubic),
    );

    _retournement = Tween<double>(begin: 0, end: pi).animate(
      CurvedAnimation(
        parent: _controleur,
        curve: const Interval(0.1, 0.85, curve: Curves.easeInOut),
      ),
    );

    // Plus le lancer est vif, plus la carte tourbillonne avant de se
    // stabiliser sur sa rotation finale (magnétisme du centre).
    final toursSupplementaires = (fraction * 2.5).clamp(0.2, 2.5);
    _tourbillon = Tween<double>(
      begin: 0,
      end: toursSupplementaires * 2 * pi + widget.rotationFinale,
    ).animate(CurvedAnimation(parent: _controleur, curve: Curves.easeOutQuart));

    _controleur.forward().whenComplete(widget.onAtterrissage);
  }

  @override
  void dispose() {
    _controleur.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controleur,
      builder: (context, _) {
        final estRetournee = _retournement.value > pi / 2;
        return Positioned(
          left: _position.value.dx,
          top: _position.value.dy,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.002)
              ..rotateY(_retournement.value)
              ..rotateZ(_tourbillon.value),
            child: CarteWidget(
              code: estRetournee ? widget.codeCarte : null,
              largeur: 64,
              hauteur: 90,
            ),
          ),
        );
      },
    );
  }
}
