import 'package:flutter/material.dart';

/// Petit popup animé pour les moments forts (doublon, défi, victoire de
/// pli...) : flash de couleur + texte qui "pop" avec un effet élastique.
///
/// Les vraies illustrations sonores/visuelles façon jeu en ligne restent
/// à concevoir (assets, voix, timing précis) — ceci pose juste le point
/// d'accroche pour les brancher facilement plus tard.
class EffetPopup extends StatelessWidget {
  final String texte;
  final Color couleur;

  const EffetPopup({
    super.key,
    required this.texte,
    this.couleur = Colors.amberAccent,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.elasticOut,
      builder: (context, valeur, enfant) => Opacity(
        opacity: valeur.clamp(0, 1),
        child: Transform.scale(scale: 0.6 + valeur * 0.4, child: enfant),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: couleur,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 12),
          ],
        ),
        child: Text(
          texte,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: Colors.black,
          ),
        ),
      ),
    );
  }
}

/// Flash plein écran très bref (par ex. sur un doublon remporté).
class FlashEcran extends StatelessWidget {
  final Color couleur;
  const FlashEcran({super.key, this.couleur = Colors.white});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.55, end: 0),
      duration: const Duration(milliseconds: 350),
      builder: (context, opacite, _) => IgnorePointer(
        child: Container(color: couleur.withOpacity(opacite)),
      ),
    );
  }
}

/// Exemples de lignes de "commentaire excité" façon jeu en ligne, à
/// remplacer par de vraies lignes (et de l'audio) plus tard.
const List<String> commentairesExemple = [
  'INCROYABLE !',
  'Doublon fulgurant !',
  'Il tape au dernier moment !',
  'Le pli explose !',
];
