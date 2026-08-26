import 'dart:math';

import 'package:flutter/material.dart';

import '../modeles.dart';
import '../moteur/partie_locale.dart';
import '../widgets/carte_volante.dart';
import '../widgets/carte_widget.dart';
import '../widgets/entete.dart';
import '../widgets/fleche_joueur.dart';
import '../widgets/tas_joueur.dart';

/// Écran de la table animé par [PartieLocale] : tu joues contre 3 bots
/// dont les temps de réaction suivent une loi log-normale crédible.
/// Règles complètes câblées (défis, doublon prioritaire, victoire 52).
class EcranTable extends StatefulWidget {
  const EcranTable({super.key});

  @override
  State<EcranTable> createState() => _EcranTableState();
}

class _CarteCentre {
  final String code;
  final Offset position;
  final double rotation;
  _CarteCentre({
    required this.code,
    required this.position,
    required this.rotation,
  });
}

class _LotRamasse {
  final List<_CarteCentre> cartes;
  final Offset arrivee;
  _LotRamasse({required this.cartes, required this.arrivee});
}

class _EcranTableState extends State<EcranTable>
    with SingleTickerProviderStateMixin {
  final _rng = Random();
  late final PartieLocale _partie;

  final List<_CarteCentre> _pliVisible = [];
  final List<Widget> _volantes = [];

  double _derniereVitesseHumain = 1200;
  bool _feuDoublon = false;

  late final AnimationController _ctrlRamasse;
  _LotRamasse? _ramassage;

  @override
  void initState() {
    super.initState();

    _ctrlRamasse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(() => setState(() {}));

    _partie = PartieLocale();
    _partie.surPose = _onCartePosee;
    _partie.surPliRamasse = _onPliRamasse;
    _partie.surDoublon = () => setState(() => _feuDoublon = true);
    _partie.addListener(_surNotifMoteur);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _partie.nouvellePartie();
    });
  }

  @override
  void dispose() {
    _partie.removeListener(_surNotifMoteur);
    _partie.dispose();
    _ctrlRamasse.dispose();
    super.dispose();
  }

  void _surNotifMoteur() {
    if (!mounted) return;
    setState(() {});
    if (_partie.phase == PhasePartie.partieFinie && !_dialogAffiche) {
      _dialogAffiche = true;
      final gagnant = _partie.vainqueurFinal;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF0F5C3E),
          title: Text(
            gagnant == null
                ? 'Match interrompu'
                : gagnant.estBot
                    ? '${gagnant.nom} remporte la partie !'
                    : 'Tu gagnes la partie ! 🎉',
            style: const TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _reinitialiser();
              },
              child: const Text('Rejouer'),
            ),
          ],
        ),
      );
    }
  }

  bool _dialogAffiche = false;

  void _reinitialiser() {
    setState(() {
      _dialogAffiche = false;
      _pliVisible.clear();
      _volantes.clear();
      _feuDoublon = false;
      _ramassage = null;
      _ctrlRamasse.reset();
    });
    _partie.nouvellePartie();
  }

  // ------------------------------------------------------------------ //
  // Réactions aux événements du moteur                                 //
  // ------------------------------------------------------------------ //
  void _onCartePosee(int indexJoueur, String code, bool venantDHumain) {
    final taille = _tailleEcran();
    if (taille == Size.zero) return;

    final vitesse =
        venantDHumain ? _derniereVitesseHumain : 900 + _rng.nextDouble() * 1400;
    final arrivee = Offset(
      taille.width / 2 + (_rng.nextDouble() - 0.5) * 70,
      taille.height * 0.42 + (_rng.nextDouble() - 0.5) * 40,
    );
    final depart = _origineJoueur(indexJoueur, taille);
    final rotationFinale = (_rng.nextDouble() - 0.5) * 0.6;

    late final Widget volante;
    volante = CarteVolante(
      key: UniqueKey(),
      depart: depart,
      arrivee: arrivee,
      vitessePixelsSeconde: vitesse,
      codeCarte: code,
      rotationFinale: rotationFinale,
      onAtterrissage: () {
        setState(() {
          _volantes.remove(volante);
          _pliVisible.add(
            _CarteCentre(
              code: code,
              position: arrivee,
              rotation: rotationFinale,
            ),
          );
        });
      },
    );
    setState(() => _volantes.add(volante));
  }

  void _onPliRamasse(int indexVainqueur, int nombreCartes) {
    final taille = _tailleEcran();
    if (taille == Size.zero || _pliVisible.isEmpty) {
      setState(() => _feuDoublon = false);
      return;
    }

    setState(() {
      _ramassage = _LotRamasse(
        cartes: List<_CarteCentre>.of(_pliVisible),
        arrivee: _origineJoueur(indexVainqueur, taille),
      );
      _feuDoublon = false;
      _pliVisible.clear();
    });
    _ctrlRamasse.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _ramassage = null);
    });

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            '${_partie.joueurs[indexVainqueur].nom} ramasse $nombreCartes carte(s).',
          ),
        ),
      );
  }

  Size _tailleEcran() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Size.zero;
    return box.size;
  }

  Offset _origineJoueur(int indexJoueur, Size taille) {
    if (indexJoueur == 0) {
      return Offset(taille.width / 2 - 32, taille.height - 34);
    }
    final nAdversaires = _partie.joueurs.length - 1;
    final rang = indexJoueur - 1;
    final angleDeg =
        nAdversaires == 1 ? 0.0 : -90 + (rang / (nAdversaires - 1)) * 180;
    final angleRad = angleDeg * pi / 180;
    final rayon = taille.width * 0.36;
    final hautTapis = taille.height * 0.16;
    return Offset(
      taille.width / 2 + rayon * sin(angleRad) - 24,
      hautTapis + 10 - 10 * cos(angleRad),
    );
  }

  // ------------------------------------------------------------------ //
  // Build                                                              //
  // ------------------------------------------------------------------ //
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B3D2E),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, contraintes) {
            final taille = Size(contraintes.maxWidth, contraintes.maxHeight);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  children: [
                    const Entete(),
                    Expanded(child: _table(taille)),
                  ],
                ),

                // Zone de tap sur doublon : plein écran pendant la course.
                if (_feuDoublon) _zoneTape(),

                // Bandeau d'état / consignes.
                Positioned(left: 12, bottom: 160, child: IgnorePointer(child: _bandeau())),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _table(Size taille) {
    final adversaires = <JoueurUI>[
      for (var i = 1; i < _partie.joueurs.length; i++)
        JoueurUI(
          id: 'p$i',
          pseudo: _partie.joueurs[i].nom,
          nombreCartes: _partie.joueurs[i].nombreCartes,
        ),
    ];

    return Stack(
      clipBehavior: Clip.none,
      children: [
        _tapis(taille),

        // Adversaires en arc 9h -> 3h avec compte de cartes vivant.
        for (var i = 0; i < adversaires.length; i++)
          Builder(builder: (_) {
            final angleDeg = adversaires.length == 1
                ? 0.0
                : -90 + (i / (adversaires.length - 1)) * 180;
            final angleRad = angleDeg * pi / 180;
            final x = taille.width / 2 + taille.width * 0.36 * sin(angleRad);
            final y = taille.height * 0.16 + 10 - 10 * cos(angleRad);
            return Positioned(
              left: x - 24,
              top: y,
              child: FlecheJoueur(joueur: adversaires[i], angleRad: angleRad),
            );
          }),

        // Pli visible au centre.
        for (final c in _pliVisible)
          Positioned(
            left: c.position.dx - 32,
            top: c.position.dy - 45,
            child: Transform.rotate(
              angle: c.rotation,
              child: CarteWidget(code: c.code, largeur: 64, hauteur: 90),
            ),
          ),

        // Vol terminée vers le vainqueur du pli.
        if (_ramassage != null)
          for (final c in _ramassage!.cartes)
            Builder(builder: (_) {
              final t = Curves.easeIn.transform(_ctrlRamasse.value);
              final p = Offset.lerp(c.position, _ramassage!.arrivee, t)!;
              return Positioned(
                left: p.dx - 32,
                top: p.dy - 45,
                child: Opacity(
                  opacity: 1 - 0.7 * t,
                  child: Transform.rotate(
                    angle: c.rotation * (1 - t),
                    child: CarteWidget(code: c.code, largeur: 64, hauteur: 90),
                  ),
                ),
              );
            }),

        // Cartes en vol.
        ..._volantes,

        // Tas du joueur (toujours dos visible jusqu'au lancer).
        Align(
          alignment: Alignment.bottomCenter,
          child: TasJoueur(
            nombreCartes: _partie.humain.nombreCartes,
            onCarteJouee: (vitesse) {
              _derniereVitesseHumain = vitesse;
              _partie.humainPose();
            },
          ),
        ),
      ],
    );
  }

  Widget _tapis(Size taille) {
    return Positioned(
      left: taille.width * 0.1,
      right: taille.width * 0.1,
      top: taille.height * 0.14,
      height: taille.height * 0.55,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0F5C3E),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white24, width: 2),
        ),
      ),
    );
  }

  Widget _zoneTape() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _partie.humainTape,
        child: Container(
          color: Colors.red.withOpacity(0.14),
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 16),
                ],
              ),
              child: const Text(
                'DOUBLON — TAPE !',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bandeau() {
    String texte;
    switch (_partie.phase) {
      case PhasePartie.attenteHumain:
        texte = 'À toi — swipe ta carte !';
        break;
      case PhasePartie.reflexionBot:
        texte = '${_partie.joueurs[_partie.indexCourant].nom} réfléchit…';
        break;
      case PhasePartie.courseTap:
        texte = 'Qui tape le plus vite ?!';
        break;
      case PhasePartie.partieFinie:
        texte = 'Partie terminée.';
    }
    if (_partie.defiActif) {
      texte += '\nDéfi ${_partie.joueurs[_partie.defiPoseur].nom} — '
          '${_partie.defiChancesRestantes} chance(s)';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(12),
      ),
      constraints: const BoxConstraints(maxWidth: 260),
      child: Text(
        texte,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }
}
