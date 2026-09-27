import 'package:flutter/material.dart';

/// Head léger de l'écran de jeu.
/// À gauche : emplacements pour les bonus gagnés (usage à définir).
/// À droite : score ELO, connexion compte, paramètres.
///
/// [score] et [libelle] étaient auparavant codés en dur (`1420`). Ils sont
/// désormais alimentés par l'indice de maîtrise mesuré en cours de partie :
/// l'entête devient vivante et reflète réellement le niveau du joueur.
class Entete extends StatelessWidget {
  /// Score affiché. `null` = valeur historique figée.
  final int? score;

  /// Libellé de maîtrise (« Débutant », « Aguerri », ...). `null` = masqué.
  final String? libelle;

  /// Callback de retour vers la page de lancement. `null` = flèche masquée.
  final VoidCallback? onRetour;

  const Entete({
    super.key,
    this.score,
    this.libelle,
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
              tooltip: 'Quitter la table',
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
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white24),
                ),
              ),
            ),
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
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
                    ),
                  ),
                ],
              ),
              if (libelle != null)
                Text(
                  libelle!,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          const CircleAvatar(radius: 14, backgroundColor: Colors.white24),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}
