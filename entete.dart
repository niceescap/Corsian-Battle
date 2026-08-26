import 'package:flutter/material.dart';

/// Head léger de l'écran de jeu.
/// À gauche : emplacements pour les bonus gagnés (usage à définir).
/// À droite : score ELO, connexion compte, paramètres.
class Entete extends StatelessWidget {
  const Entete({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
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
          const Icon(Icons.emoji_events, color: Colors.amberAccent, size: 18),
          const SizedBox(width: 4),
          const Text(
            '1420',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
