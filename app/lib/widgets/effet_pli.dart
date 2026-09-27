import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Effets de table : dynamiser les phases de GAIN et de PERTE d'un pli.
//
// Contrainte de conception : la demande centrale est la VITESSE et une UX
// UNIVERSELLE — il n'y a RIEN À LIRE pendant la partie. Trois règles :
//   1. tout est plafonné à 700 ms ;
//   2. tout est en IgnorePointer — un effet ne doit JAMAIS avaler un geste ;
//   3. aucun effet ne bloque le tour suivant : le moteur continue de tourner.
//
// Le sens passe exclusivement par la COULEUR (vert = gagné, rouge = perdu),
// le SIGNE (+ / −), la DIRECTION du mouvement et des PICTOGRAMMES. Aucun mot.
// ---------------------------------------------------------------------------

/// Plafond commun de durée des effets, en ms.
const int kDureeMaxEffetMs = 700;

/// Voile couleur plein écran qui s'estompe. Vert/or sur un gain, rouge sombre
/// sur une perte, blanc sur un doublon remporté.
class FlashPli extends StatelessWidget {
  final Color couleur;
  final double opaciteDepart;
  final int dureeMs;

  const FlashPli({
    super.key,
    required this.couleur,
    this.opaciteDepart = 0.42,
    this.dureeMs = 360,
  });

  @override
  Widget build(BuildContext context) {
    final duree = min(dureeMs, kDureeMaxEffetMs);
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: opaciteDepart, end: 0.0),
        duration: Duration(milliseconds: duree),
        curve: Curves.easeOut,
        builder: (context, opacite, _) => Container(
          color: couleur.withOpacity(opacite),
        ),
      ),
    );
  }
}

/// « +12 » qui monte en s'effaçant sur un gain, « −7 » qui tombe sur une
/// perte. Le signe, la couleur et le sens du mouvement suffisent à lire le
/// résultat sans aucun mot. Un [icone] optionnel précise l'événement
/// (ex. main ouverte pour un doublon, flèche de retour pour une reprise).
class PopupScore extends StatelessWidget {
  final int nombre;
  final bool estGain;
  final IconData? icone;

  const PopupScore({
    super.key,
    required this.nombre,
    required this.estGain,
    this.icone,
  });

  @override
  Widget build(BuildContext context) {
    final couleur =
        estGain ? const Color(0xFFFFD54F) : const Color(0xFFFF8A80);
    final signe = estGain ? '+' : '−';
    final monteeMax = estGain ? 54.0 : 34.0;

    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: kDureeMaxEffetMs),
        curve: Curves.easeOutCubic,
        builder: (context, t, enfant) {
          final opacite = t < 0.55 ? t / 0.55 : (1 - t) / 0.45;
          final decalage = (1 - t) * monteeMax * (estGain ? -1 : 1);
          final echelle = 0.7 + 0.3 * Curves.easeOutBack.transform(
                min(t * 1.6, 1.0),
              );
          return Opacity(
            opacity: opacite.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, decalage),
              child: Transform.scale(scale: echelle, child: enfant),
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$signe$nombre',
              style: TextStyle(
                color: couleur,
                fontSize: 44,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
                shadows: const [
                  Shadow(color: Colors.black87, blurRadius: 12),
                  Shadow(
                    color: Colors.black54,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
            ),
            if (icone != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  icone,
                  size: 26,
                  color: couleur,
                  shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Fait trembler son [enfant] à chaque changement de [declencheur].
/// Trois impulsions décroissantes sur 220 ms.
class SecousseTapis extends StatefulWidget {
  final Widget enfant;
  final int declencheur;
  final double amplitude;

  const SecousseTapis({
    super.key,
    required this.enfant,
    required this.declencheur,
    this.amplitude = 9,
  });

  @override
  State<SecousseTapis> createState() => _SecousseTapisState();
}

class _SecousseTapisState extends State<SecousseTapis>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void didUpdateWidget(covariant SecousseTapis ancien) {
    super.didUpdateWidget(ancien);
    if (ancien.declencheur != widget.declencheur) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, enfant) {
        final t = _ctrl.value;
        if (t <= 0) return enfant!;
        final oscillation = sin(t * pi * 6) * widget.amplitude * (1 - t);
        return Transform.translate(
          offset: Offset(oscillation, 0),
          child: enfant,
        );
      },
      child: widget.enfant,
    );
  }
}

/// Bannière centrale SANS TEXTE : un grand pictogramme qui pop puis s'efface.
/// Remplace les anciennes bannières à mots (« DOUBLON ! », « À TOI ! »…).
/// Le picto + la couleur portent tout le sens (main ouverte = taper, etc.).
class BanniereIcone extends StatelessWidget {
  final IconData icone;
  final Color couleur;

  const BanniereIcone({
    super.key,
    required this.icone,
    this.couleur = Colors.redAccent,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 650),
        builder: (context, t, enfant) {
          final apparition = Curves.elasticOut.transform(min(t * 1.8, 1.0));
          final opacite = t < 0.6 ? 1.0 : (1 - t) / 0.4;
          return Opacity(
            opacity: opacite.clamp(0.0, 1.0),
            child: Transform.scale(scale: apparition, child: enfant),
          );
        },
        child: Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            color: couleur,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 18),
            ],
          ),
          child: Icon(icone, size: 44, color: Colors.white),
        ),
      ),
    );
  }
}

/// Retour haptique natif : aucune dépendance ajoutée au pubspec.
class RetourTactile {
  RetourTactile._();

  static void gain() => HapticFeedback.mediumImpact();

  static Future<void> perte() async {
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.lightImpact();
  }

  static void doublon() => HapticFeedback.heavyImpact();

  static void pose() => HapticFeedback.selectionClick();

  /// Geste refusé (swipe hors tour) : double tic court, sans violence.
  static Future<void> refus() async {
    await HapticFeedback.selectionClick();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await HapticFeedback.selectionClick();
  }
}
