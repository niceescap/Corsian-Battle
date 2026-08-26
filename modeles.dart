import 'package:flutter/foundation.dart';

/// Intensité visuelle de la flèche d'un adversaire, selon la taille de
/// son jeu :
/// - [epaisse] : jeu conséquent (flèche grasse, pleine)
/// - [fine] : peu de cartes (flèche fine, pleine)
/// - [creuse] : 0 carte, mais le joueur reste en jeu (flèche à contour
///   seulement — il peut encore taper sur un doublon)
enum IntensiteFleche { epaisse, fine, creuse }

@immutable
class JoueurUI {
  final String id;
  final String pseudo;
  final int nombreCartes;

  const JoueurUI({
    required this.id,
    required this.pseudo,
    required this.nombreCartes,
  });

  /// Seuils arbitraires pour l'ébauche — à recaler une fois le vrai
  /// barème de "jeu conséquent" décidé côté moteur.
  IntensiteFleche get intensite {
    if (nombreCartes <= 0) return IntensiteFleche.creuse;
    if (nombreCartes < 10) return IntensiteFleche.fine;
    return IntensiteFleche.epaisse;
  }

  JoueurUI copierAvec({int? nombreCartes}) {
    return JoueurUI(
      id: id,
      pseudo: pseudo,
      nombreCartes: nombreCartes ?? this.nombreCartes,
    );
  }
}
