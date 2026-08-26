import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Moteur local : port fidèle des règles de `bataille_corse/moteur.py`.
///
/// - un joueur pose TOUJOURS sa carte du dessus ;
/// - figure => défi : le(s) suivant(s) ont As=4, Roi=3, Dame=2, Valet=1
///   cartes-chances ; une figure ressortie fait rebondir le défi sans
///   limite ;
/// - le DOUBLON (deux rangs identiques consécutifs) est prioritaire à
///   tout instant : première personne à TAPER qui gagne le pli, même un
///   joueur à sec ;
/// - le reste non distribué rejoint le vainqueur du premier pli ;
/// - victoire : 52 cartes.
class CarteJeu {
  final String rang; // A,2..9,T,J,Q,K
  final String couleur; // S,H,D,C

  const CarteJeu(this.rang, this.couleur);

  factory CarteJeu.deCode(String code) =>
      CarteJeu(code.substring(0, 1), code.substring(1, 2));

  String get code => rang + couleur;

  bool get estFigure => kBaremeFigures.containsKey(rang);
  int get chances => kBaremeFigures[rang] ?? 0;
}

const Map<String, int> kBaremeFigures = {'A': 4, 'K': 3, 'Q': 2, 'J': 1};

class JoueurPartie {
  final String nom;
  final bool estBot;

  /// Temps de réaction moyen du bot en ms (loi log-normale autour, comme
  /// ProfilReflexe côté Python : asymétrique à droite, plancher 120 ms).
  final double reflexeMoyenMs;

  /// Index 0 = dessus du tas (prochaine carte jouée).
  final Queue<String> tas = Queue<String>();

  JoueurPartie(
    this.nom, {
    required this.estBot,
    this.reflexeMoyenMs = 250,
  });

  int get nombreCartes => tas.length;
  bool get aDesCartes => tas.isNotEmpty;
}

enum PhasePartie { attenteHumain, reflexionBot, courseTap, partieFinie }

class _CartePli {
  final String code;
  final int poseur;
  const _CartePli(this.code, this.poseur);
}

class PartieLocale extends ChangeNotifier {
  final Random _rng;
  Timer? _timerCourseTap;
  Timer? _timerBot;
  int _coups = 0;
  static const int _maxCoups = 40000;

  /// Vide avant [nouvellePartie] : l'UI doit tester `.isEmpty`.
  List<JoueurPartie> joueurs = [];
  final List<_CartePli> pli = [];
  final List<String> _resteNeutre = [];

  int indexCourant = 0;
  int defiPoseur = -1; // -1 = pas de défi en cours
  int defiChancesRestantes = 0;
  PhasePartie phase = PhasePartie.partieFinie;

  /// Dernier événement "ramassage" : index du vainqueur + nb cartes.
  int? dernierVainqueurPli;
  int nbCartesDernierPli = 0;

  /// Hook UI : appelé dès qu'une carte quitte un tas (pour le vol).
  void Function(int indexJoueur, String code, bool venantDHumain)? surPose;

  /// Hook UI : pli attribué (vainqueur, nombre de cartes).
  void Function(int indexVainqueur, int nombreCartes)? surPliRamasse;

  /// Hook UI : un doublon vient d'apparaître => fenêtre de tap ouverte.
  VoidCallback? surDoublon;

  PartieLocale({int? seed}) : _rng = Random(seed);

  // ------------------------------------------------------------------ //
  // Démarrage                                                          //
  // ------------------------------------------------------------------ //
  void nouvellePartie() {
    _timerBot?.cancel();
    _timerCourseTap?.cancel();
    _coups = 0;

    joueurs = [
      JoueurPartie('Toi', estBot: false),
      JoueurPartie('Marc', estBot: true, reflexeMoyenMs: 265),
      JoueurPartie('Julie', estBot: true, reflexeMoyenMs: 240),
      JoueurPartie('Théo', estBot: true, reflexeMoyenMs: 225),
    ];

    final paquet = <String>[
      for (final couleur in const ['S', 'H', 'D', 'C'])
        for (final rang in const [
          'A', '2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K',
        ])
          '$rang$couleur',
    ]..shuffle(_rng);

    final part = paquet.length ~/ joueurs.length;
    for (var i = 0; i < joueurs.length; i++) {
      joueurs[i].tas.clear();
      joueurs[i].tas.addAll(paquet.sublist(i * part, (i + 1) * part));
    }
    _resteNeutre
      ..clear()
      ..addAll(paquet.sublist(part * joueurs.length));

    pli.clear();
    defiPoseur = -1;
    defiChancesRestantes = 0;
    dernierVainqueurPli = null;
    indexCourant = 0;

    notifyListeners();
    _programmerTourSuivant();
  }

  @override
  void dispose() {
    _timerBot?.cancel();
    _timerCourseTap?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ //
  // Règles                                                             //
  // ------------------------------------------------------------------ //
  bool get defiActif => defiPoseur >= 0;

  bool get auTourDeLHumain =>
      phase == PhasePartie.attenteHumain &&
      joueurs.isNotEmpty &&
      !joueurs[indexCourant].estBot;

  int? _prochainIndexAvecCartes(int depuis) {
    for (var pas = 1; pas <= joueurs.length; pas++) {
      final i = (depuis + pas) % joueurs.length;
      if (joueurs[i].aDesCartes) return i;
    }
    return null;
  }

  bool _estDoublon() =>
      pli.length >= 2 &&
      CarteJeu.deCode(pli[pli.length - 2].code).rang ==
          CarteJeu.deCode(pli.last.code).rang;

  /// L'humain (index 0) pose sa carte du dessus — déclenché par le swipe.
  bool humainPose() {
    if (!auTourDeLHumain || !joueurs[0].aDesCartes) return false;
    _poserCarte(0);
    return true;
  }

  /// L'humain tape sur un doublon (course de réflexes contre les bots).
  bool humainTape() {
    if (phase != PhasePartie.courseTap) return false;
    _timerCourseTap?.cancel();
    _attribuerPli(0);
    return true;
  }

  void _poserCarte(int idx) {
    if (phase == PhasePartie.partieFinie) return;

    final j = joueurs[idx];
    final code = j.tas.removeFirst();
    pli.add(_CartePli(code, idx));
    _coups++;
    surPose?.call(idx, code, idx == 0);

    final carte = CarteJeu.deCode(code);

    // 1) Doublon : priorité absolue, fenêtre de tap immédiate.
    if (_estDoublon()) {
      _ouvrirCourseTap();
      return;
    }

    // 2) Figure : (re)lance ou fait rebondir le défi.
    if (carte.estFigure) {
      defiPoseur = idx;
      defiChancesRestantes = carte.chances;
      _avancerOuCloturer(idx);
    } else if (defiActif) {
      // 3) Carte normale pendant un défi : consomme une chance.
      defiChancesRestantes--;
      if (defiChancesRestantes <= 0) {
        _attribuerPli(defiPoseur);
        return;
      }
      _avancerOuCloturer(idx);
    } else {
      // 4) Jeu normal : passage au suivant ayant des cartes.
      final suivant = _prochainIndexAvecCartes(idx);
      if (suivant != null) indexCourant = suivant;
    }

    notifyListeners();
    _programmerTourSuivant();
  }

  void _avancerOuCloturer(int dernierPoseur) {
    final suivant = _prochainIndexAvecCartes(dernierPoseur);
    if (suivant == null) {
      if (defiActif) _attribuerPli(defiPoseur);
      return;
    }
    indexCourant = suivant;
  }

  void _ouvrirCourseTap() {
    phase = PhasePartie.courseTap;
    notifyListeners();
    surDoublon?.call();

    // Chaque bot "réagit" : temps log-normal (mu = ln(moyenne), sigma .25),
    // plancher physiologique 120 ms — cf. ProfilReflexe côté Python.
    final tempsParBot = <int, double>{
      for (var i = 0; i < joueurs.length; i++)
        if (joueurs[i].estBot)
          i: _tirerTempsReaction(joueurs[i].reflexeMoyenMs),
    };
    if (tempsParBot.isEmpty) return; // impossible en pratique (>=1 bot)

    var meilleur = tempsParBot.entries.first;
    for (final e in tempsParBot.entries) {
      if (e.value < meilleur.value) meilleur = e;
    }

    _timerCourseTap = Timer(
      Duration(milliseconds: meilleur.value.round()),
      () {
        if (phase == PhasePartie.courseTap) _attribuerPli(meilleur.key);
      },
    );
  }

  double _gaussienne() {
    final u1 = max(_rng.nextDouble(), 1e-9);
    final u2 = _rng.nextDouble();
    return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
  }

  double _tirerTempsReaction(double moyenneMs) {
    final t = exp(log(moyenneMs) + 0.25 * _gaussienne());
    return max(t, 120.0);
  }

  void _attribuerPli(int gagnant) {
    nbCartesDernierPli = pli.length + _resteNeutre.length;
    for (final c in pli) {
      joueurs[gagnant].tas.addLast(c.code);
    }
    joueurs[gagnant].tas.addAll(_resteNeutre);
    _resteNeutre.clear();
    pli.clear();
    defiPoseur = -1;
    defiChancesRestantes = 0;
    dernierVainqueurPli = gagnant;
    indexCourant = gagnant;

    final fini =
        joueurs.any((j) => j.nombreCartes == 52) ||
        _coups >= _maxCoups; // garde-fou anti-boucle infinie
    phase = fini ? PhasePartie.partieFinie : PhasePartie.reflexionBot;

    notifyListeners();
    surPliRamasse?.call(gagnant, nbCartesDernierPli);
    if (!fini) _programmerTourSuivant();
  }

  /// Programme le coup du bot courant, ou repasse en attente de l'humain.
  void _programmerTourSuivant() {
    if (phase == PhasePartie.partieFinie || phase == PhasePartie.courseTap) {
      return;
    }
    _timerBot?.cancel();

    final courant = joueurs[indexCourant];
    if (!courant.estBot) {
      phase = PhasePartie.attenteHumain;
      notifyListeners();
      return;
    }

    phase = PhasePartie.reflexionBot;
    final delai = 520 + _rng.nextInt(420); // rythme de table crédible
    _timerBot = Timer(Duration(milliseconds: delai), () {
      if (phase != PhasePartie.reflexionBot) return;
      if (joueurs[indexCourant].estBot) _poserCarte(indexCourant);
    });
    notifyListeners();
  }

  // Confort UI -------------------------------------------------------
  JoueurPartie get humain => joueurs.first;

  JoueurPartie? get vainqueurFinal {
    for (final j in joueurs) {
      if (j.nombreCartes == 52) return j;
    }
    return null;
  }
}
