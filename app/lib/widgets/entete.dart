import 'package:flutter/material.dart';

/// Entête de l'écran de jeu, volontairement MINIMALISTE et sans texte.
///
/// Universalisation oblige, aucun mot n'est affiché pendant la partie :
/// - à gauche : une flèche de retour (picto) et des emplacements de bonus ;
/// - à droite : le score sous forme de NOMBRE (trophée + valeur), un avatar
///   et un picto de réglages.
///
/// Le score reste alimenté par l'indice de maîtrise mesuré en cours de
/// partie (voir moteur/rythme.dart) : la mécanique d'harmonisation demeure
/// active en interne, seule son EXPOSITION textuelle a disparu. Un chiffre
/// est universel, il peut rester visible.
class Entete extends StatelessWidget {
  /// Score affiché. `null` = valeur de repli.
  final int? score;

  /// Callback de retour vers la page de lancement. `null` = flèche masquée.
  final VoidCallback? onRetour;

  const Entete({
    super.key,
    this.score,
    this.onRetour,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (onRetour != null)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white70),
              onPressed: onRetour,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            ),
          Row(
            children: List.generate(
              3,
              (i) => Container(
                margin: const EdgeInsets.only(right: 6),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(
                  Icons.style_outlined,
                  size: 14,
                  color: Colors.white24,
                ),
              ),
            ),
          ),
          const Spacer(),
          // Score : trophée + nombre. Le chiffre est universel, aucun mot.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.emoji_events,
                color: Colors.amberAccent,
                size: 18,
              ),
              const SizedBox(width: 4),
              Text(
                '${score ?? 1420}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          const CircleAvatar(radius: 14, backgroundColor: Colors.white24),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: () {},
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          ),
        ],
      ),
    );
  }
}
