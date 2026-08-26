import 'dart:math';
import 'package:flutter/material.dart';
import '../modeles.dart';
import '../widgets/entete.dart';
import '../widgets/fleche_joueur.dart';
import '../widgets/carte_widget.dart';
import '../widgets/carte_volante.dart';
import '../widgets/tas_joueur.dart';

/// Écran de la table de jeu.
///
/// IMPORTANT : cet écran simule localement les adversaires et l'issue
/// des plis (aucune connexion au moteur Python ni synchronisation
/// réseau). C'est une ébauche visuelle pour valider les animations et
/// les gestes ; le branchement au vrai moteur + au timecode réseau
/// reste à faire (voir README du projet).
class EcranTable extends StatefulWidget {
  const EcranTable({super.key});

  @override
  State<EcranTable> createState() => _EcranTableState();
}

class _CarteAuCentre {
  final String code;
  final Offset position;
  final double rotation;

  _CarteAuCentre({
    required this.code,
    required this.position,
    required this.rotation,
  });
}

class _EcranTableState extends State<EcranTable> {
  final _rng = Random();

  late List<String> _cartesRestantes = _nouveauPaquet();

  int _nombreCartesJoueur = 13;
  final List<_CarteAuCentre> _pli = [];
  final List<Widget> _cartesVolantes = [];
  bool _pliRamassable = false;
  double _progressionRamassage = 0;

  final List<JoueurUI> _adversaires = const [
    JoueurUI(id: 'p1', pseudo: 'Marc', nombreCartes: 14),
    JoueurUI(id: 'p2', pseudo: 'Julie', nombreCartes: 3),
    JoueurUI(id: 'p3', pseudo: 'Théo', nombreCartes: 0),
  ];

  List<String> _nouveauPaquet() => [
        for (final couleur in ['S', 'H', 'D', 'C'])
          for (final rang in [
            'A', '2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K'
          ])
            '$rang$couleur',
      ]..shuffle(_rng);

  String _prochaineCarte() {
    if (_cartesRestantes.isEmpty) _cartesRestantes = _nouveauPaquet();
    return _cartesRestantes.removeLast();
  }

  void _joueurLanceCarte(double vitesse, Size tailleTable) {
    if (_nombreCartesJoueur <= 0) return;

    final centre = Offset(tailleTable.width / 2, tailleTable.height * 0.40);
    final decalage = Offset(
      (_rng.nextDouble() - 0.5) * 70,
      (_rng.nextDouble() - 0.5) * 40,
    );
    final arrivee = centre + decalage;
    final depart = Offset(tailleTable.width / 2 - 32, tailleTable.height - 34);
    final rotationFinale = (_rng.nextDouble() - 0.5) * 0.6;
    final code = _prochaineCarte();

    late final Widget carte;
    carte = CarteVolante(
      key: UniqueKey(),
      depart: depart,
      arrivee: arrivee,
      vitessePixelsSeconde: vitesse,
      codeCarte: code,
      rotationFinale: rotationFinale,
      onAtterrissage: () {
        setState(() {
          _cartesVolantes.remove(carte);
          _pli.add(_CarteAuCentre(
            code: code,
            position: arrivee,
            rotation: rotationFinale,
          ));
          _nombreCartesJoueur--;
          // Condition simplifiée pour la démo : à remplacer par le vrai
          // signal "pli remporté" envoyé par le moteur.
          _pliRamassable = _pli.length >= 4;
        });
      },
    );

    setState(() => _cartesVolantes.add(carte));
  }

  void _ramasserProgression(double delta) {
    setState(() {
      _progressionRamassage = (_progressionRamassage + delta).clamp(0, 1);
    });
  }

  void _terminerRamassage() {
    if (_progressionRamassage > 0.6) {
      setState(() {
        _pli.clear();
        _pliRamassable = false;
        _progressionRamassage = 0;
        _nombreCartesJoueur += 4; // valeur de démo
      });
    } else {
      setState(() => _progressionRamassage = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B3D2E),
      body: SafeArea(
        child: Column(
          children: [
            const Entete(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, contraintes) {
                  final taille =
                      Size(contraintes.maxWidth, contraintes.maxHeight);
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _construireTapis(taille),
                      ..._positionnerAdversaires(taille),
                      ..._positionnerPli(taille),
                      ..._cartesVolantes,
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: TasJoueur(
                          nombreCartes: _nombreCartesJoueur,
                          onCarteJouee: (vitesse) =>
                              _joueurLanceCarte(vitesse, taille),
                        ),
                      ),
                      if (_pliRamassable) _construireZoneRamassage(taille),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _construireTapis(Size taille) {
    return Positioned(
      left: taille.width * 0.1,
      right: taille.width * 0.1,
      top: taille.height * 0.16,
      height: taille.height * 0.5,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0F5C3E),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white24, width: 2),
        ),
      ),
    );
  }

  List<Widget> _positionnerAdversaires(Size taille) {
    final n = _adversaires.length;
    final rayon = taille.width * 0.36;
    final centreX = taille.width / 2;
    final hautTapis = taille.height * 0.16;

    return List.generate(n, (i) {
      // Répartis de 9h à 3h en passant par midi (arc supérieur).
      final angleDeg = n == 1 ? 0.0 : -90 + (i / (n - 1)) * 180;
      final angleRad = angleDeg * pi / 180;
      final x = centreX + rayon * sin(angleRad);
      final y = hautTapis + 10 - 10 * cos(angleRad);

      return Positioned(
        left: x - 24,
        top: y,
        child: FlecheJoueur(joueur: _adversaires[i], angleRad: angleRad),
      );
    });
  }

  List<Widget> _positionnerPli(Size taille) {
    final posTas = Offset(taille.width / 2 - 32, taille.height - 34);
    return _pli.map((carte) {
      final position =
          Offset.lerp(carte.position, posTas, _progressionRamassage)!;
      return Positioned(
        left: position.dx - 32,
        top: position.dy - 45,
        child: Transform.rotate(
          angle: carte.rotation * (1 - _progressionRamassage),
          child: CarteWidget(code: carte.code, largeur: 64, hauteur: 90),
        ),
      );
    }).toList();
  }

  Widget _construireZoneRamassage(Size taille) {
    return Positioned(
      left: taille.width * 0.1,
      top: taille.height * 0.16,
      width: taille.width * 0.8,
      height: taille.height * 0.5,
      child: GestureDetector(
        onPanUpdate: (details) => _ramasserProgression(details.delta.dy / 200),
        onPanEnd: (_) => _terminerRamassage(),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.amber.withOpacity(0.06 + _progressionRamassage * 0.2),
            borderRadius: BorderRadius.circular(28),
          ),
        ),
      ),
    );
  }
}
