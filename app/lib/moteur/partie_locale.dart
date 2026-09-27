import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'rythme.dart';

/// Moteur local : port fidèle des règles canoniques de la Bataille Corse.
///
/// - un joueur pose TOUJOURS sa carte du dessus ;
/// - figure => défi : le joueur suivant (et UNIQUEMENT lui) dispose d'un
///   nombre de cartes-chances selon le barème (As 4, Roi 3, Dame 2, Valet 1)
///   pour sortir une figure ;
/// - si une figure ressort, le défi rebondit sur le joueur suivant avec
///   son barème PLEIN ;
/// - si le joueur répondeur n'a plus assez de cartes ou épuise ses chances
///   sans sortir de figure, le défi échoue au profit du dernier poseur de figure ;
/// - le DOUBLON (deux rangs identiques consécutifs) est prioritaire à
///   tout instant : première personne à TAPER qui gagne le pli, même un
///   joueur à sec ;
/// - le reste non distribué rejoint le vainqueur du premier pli ;
/// - victoire : 52 cartes.
///
/// LES RÈGLES SONT INCHANGÉES par le mode duel. Seule la cadence de
/// l'adversaire-machine devient adaptative (voir [AnalyseurRythme]).
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

/// Nombre de configurations de table proposées.
enum ModePartie {
  /// 1 contre 1 : le joueur humain face à un adversaire-machine qui épouse
  /// son rythme.
  duel,

  /// Table historique : le joueur humain face à Marc, Julie et Théo,
  /// chacun avec son temps de réaction fixe.
  tableQuatre,
}

/// Configuration d'une partie : mode de table et pseudonymes.
///
/// Le moteur ne duplique JAMAIS ses règles selon le mode — il n'y a qu'une
/// seule implémentation, paramétrée. Le projet s'est déjà brûlé une fois sur
/// une divergence entre le moteur Python et le port Dart (commits 9af1ebd /
/// 34e2373) : on ne reproduit pas l'erreur.
class ConfigPartie {
  final ModePartie mode;
  final String nomHumain;

  /// Utilisé uniquement en [ModePartie.duel].
  final String nomAdversaire;

  const ConfigPartie({
    this.mode = ModePartie.tableQuatre,
    this.nomHumain = 'Toi',
    this.nomAdversaire = 'Marc',
  });

  /// Le duel, avec l'adversaire-miroir par défaut.
  const ConfigPartie.duel({String nomAdversaire = 'Marc'})
      : mode = ModePartie.duel,
        nomHumain = 'Toi',
        nomAdversaire = nomAdversaire;

  /// La table historique à 4 joueurs.
  const ConfigPartie.tableQuatre()
      : mode = ModePartie.tableQuatre,
        nomHumain = 'Toi',
        nomAdversaire = 'Marc';

  int get nombreJoueurs => mode == ModePartie.duel ? 2 : 4;

  bool get estDuel => mode == ModePartie.duel;
}

class JoueurPartie {
  final String nom;
  final bool estBot;

  /// Temps de réaction moyen du bot en ms (loi log-normale autour, comme
  /// ProfilReflexe côté Python : asymétrique à droite, plancher 120 ms).
  ///
  /// Ignoré en mode duel : le bot miroir tire alors son réflexe de
  /// [CerveauTempo], donc du rythme réel du joueur.
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

  /// Équité de la course de tap en table à 4 : même si un bot "réagit"
  /// vite, son verdict n'est prononcé qu'à partir de cette fenêtre
  /// minimale, pour laisser LA CARTE atterrir visuellement avant de clore
  /// le doublon. Cohérent avec resolveur_tape.py : le chronomètre part du
  /// début de la dépose (reveal), jamais d'un instant invisible côté table.
  ///
  /// En DUEL cette constante est remplacée par [CerveauTempo.fenetreEquiteMs],
  /// adaptative : figée, elle rendait la course binaire à deux joueurs
  /// (soit toujours gagnée, soit toujours perdue).
  static const int _fenetreEquiteMs = 650;

  /// Cadence historique de la table à 4 (ms). En duel, [CerveauTempo]
  /// prend le relais.
  static const int _poseBotMinMs = 520;
  static const int _poseBotAmplitudeMs = 420;

  /// Configuration courante, figée au moment de [nouvellePartie].
  ConfigPartie config = const ConfigPartie.tableQuatre();

  /// Mesure du rythme du joueur humain. Exposé pour que l'UI affiche
  /// l'indice de maîtrise (entête) et le tempo de l'adversaire (bandeau).
  final AnalyseurRythme analyseur = AnalyseurRythme();

  /// Traduit ce rythme en délais concrets pour le bot.
  late final CerveauTempo cerveau = CerveauTempo(analyseur);

  /// Vide avant [nouvellePartie] : l'UI doit tester `.isEmpty`.
  /// (Piège connu du projet : ne PAS déclarer `late`, sinon crash au
  /// premier frame, avant la première distribution.)
  List<JoueurPartie> joueurs = [];
  final List<_CartePli> pli = [];
  final List<String> _resteNeutre = [];

  int indexCourant = 0;
  int defiPoseur = -1; // -1 = pas de défi en cours
  int defiChancesRestantes = 0;
  PhasePartie phase = PhasePartie.attenteHumain;

  /// Dernier événement "ramassage" : index du vainqueur + nb cartes.
  int? dernierVainqueurPli;
  int nbCartesDernierPli = 0;

  /// Règle qui a déclenché le dernier ramassage ('Pli', 'Doublon',
  /// 'Défi manqué') — pour un retour UI explicite.
  String derniereRaisonPli = 'Pli';

  /// Vrai si le vainqueur du dernier pli était À SEC juste avant :
  /// il "revient en jeu" via le tap sur le doublon.
  bool dernierPliRepriseEnJeu = false;

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
  /// Distribue une nouvelle partie selon [configuration].
  ///
  /// Sans argument, on retrouve la table historique à 4 joueurs : le
  /// comportement existant est préservé à l'identique.
  void nouvellePartie({ConfigPartie? configuration}) {
    _timerBot?.cancel();
    _timerCourseTap?.cancel();
    _coups = 0;
    config = configuration ?? config;

    if (config.estDuel) {
      joueurs = [
        JoueurPartie(config.nomHumain, estBot: false),
        JoueurPartie(config.nomAdversaire, estBot: true),
      ];
    } else {
      joueurs = [
        JoueurPartie(config.nomHumain, estBot: false),
        JoueurPartie('Marc', estBot: true, reflexeMoyenMs: 265),
        JoueurPartie('Julie', estBot: true, reflexeMoyenMs: 240),
        JoueurPartie('Théo', estBot: true, reflexeMoyenMs: 225),
      ];
    }

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
    dernierPliRepriseEnJeu = false;
    indexCourant = 0;
    phase = PhasePartie.reflexionBot;

    // Remise à zéro du miroir de rythme : la cadence de l'adversaire se
    // recalcule à chaque partie, jamais d'une partie à l'autre.
    analyseur.demarrer();

    notifyListeners();
    _programmerTourSuivant();
  }

  @override
  void dispose() {
    _timerBot?.cancel();
    _timerCourseTap?.cancel();
    analyseur.arreter();
    super.dispose();
  }

  // ------------------------------------------------------------------ //
  // Règles                                                             //
  // ------------------------------------------------------------------ //
  bool get defiActif => defiPoseur >= 0;

  /// Vraie fin de partie (indépendante des phases de transition).
  bool get estFinie => vainqueurFinal != null || _coups >= _maxCoups;

  /// Le garde-fou anti-boucle a tranché sans vainqueur. En duel c'est un
  /// cas réel et fréquent (deux tas qui se renvoient indéfiniment les
  /// cartes) : l'UI doit l'annoncer comme une partie nulle, pas comme un
  /// « match interrompu » qui se lirait comme un bug.
  bool get estPartieNulle => vainqueurFinal == null && _coups >= _maxCoups;

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
    analyseur.notifierTapeHumaine(aGagne: true);
    derniereRaisonPli = 'Doublon';
    _attribuerPli(0);
    return true;
  }

  void _poserCarte(int idx) {
    if (phase == PhasePartie.partieFinie) return;

    derniereRaisonPli = 'Pli';
    final j = joueurs[idx];
    final code = j.tas.removeFirst();
    pli.add(_CartePli(code, idx));
    _coups++;

    // La mesure du rythme humain se fait AVANT la notification UI : le
    // chronomètre de décision s'arrête ici, au moment du geste.
    if (idx == 0) analyseur.notifierPoseHumaine();

    surPose?.call(idx, code, idx == 0);

    final carte = CarteJeu.deCode(code);

    // 1) Doublon : priorité absolue, fenêtre de tap immédiate.
    if (_estDoublon()) {
      derniereRaisonPli = 'Doublon';
      _ouvrirCourseTap();
      return;
    }

    // 2) Figure : met le pli en jeu ou fait rebondir le défi (barème PLEIN).
    if (carte.estFigure) {
      defiPoseur = idx;
      defiChancesRestantes = carte.chances;
      final suivant = _prochainIndexAvecCartes(idx);
      if (suivant == null) {
        // Plus aucun autre joueur n'a de cartes
        derniereRaisonPli = 'Défi manqué';
        _attribuerPli(defiPoseur);
        return;
      }
      indexCourant = suivant;
    } else if (defiActif) {
      // 3) Carte normale pendant un défi : consomme une chance du répondeur courant.
      defiChancesRestantes--;
      if (defiChancesRestantes <= 0 || !joueurs[idx].aDesCartes) {
        // Toutes les chances sont épuisées ou le répondeur n'a plus de cartes :
        // le défi échoue au profit du dernier poseur de figure.
        derniereRaisonPli = 'Défi manqué';
        _attribuerPli(defiPoseur);
        return;
      }
      // Il reste des chances ET des cartes : le même répondeur DOIT continuer à jouer !
      indexCourant = idx;
    } else {
      // 4) Jeu normal hors défi : passage au suivant ayant des cartes.
      final suivant = _prochainIndexAvecCartes(idx);
      if (suivant != null) indexCourant = suivant;
    }

    notifyListeners();
    _programmerTourSuivant();
  }

  void _ouvrirCourseTap() {
    phase = PhasePartie.courseTap;
    analyseur.notifierDoublonOuvert();
    notifyListeners();
    surDoublon?.call();

    // Chaque bot "réagit" : temps log-normal (mu = ln(moyenne), sigma .25),
    // plancher physiologique 120 ms — cf. ProfilReflexe côté Python.
    final tempsParBot = <int, double>{
      for (var i = 0; i < joueurs.length; i++)
        if (joueurs[i].estBot) i: _tirerTempsReaction(_reflexeBot(i)),
    };
    if (tempsParBot.isEmpty) return;

    var meilleur = tempsParBot.entries.first;
    for (final e in tempsParBot.entries) {
      if (e.value < meilleur.value) meilleur = e;
    }

    // Fenêtre d'équité : on ne clôt jamais la course avant que la carte
    // déposable ait pu être VUE à l'écran. En duel elle suit le tempo du
    // joueur au lieu d'être figée à 650 ms.
    final fenetre = config.estDuel ? cerveau.fenetreEquiteMs : _fenetreEquiteMs;
    final delai = max(meilleur.value.round(), fenetre);

    _timerCourseTap = Timer(Duration(milliseconds: delai), () {
      if (phase == PhasePartie.courseTap) {
        // Le joueur a vu le doublon sans réussir à taper en premier :
        // l'échec compte dans son indice de maîtrise.
        analyseur.notifierTapeHumaine(aGagne: false);
        _attribuerPli(meilleur.key);
      }
    });
  }

  /// Réflexe de tap du bot. En duel il est dérivé du rythme réel du
  /// joueur (miroir) ; en table à 4, on conserve les profils fixes
  /// historiques Marc 265 / Julie 240 / Théo 225.
  double _reflexeBot(int index) =>
      config.estDuel ? cerveau.reflexeBotMs : joueurs[index].reflexeMoyenMs;

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
    final gagnantEtaitASec = !joueurs[gagnant].aDesCartes;
    for (final c in pli) {
      joueurs[gagnant].tas.addLast(c.code);
    }
    joueurs[gagnant].tas.addAll(_resteNeutre);
    _resteNeutre.clear();
    pli.clear();
    defiPoseur = -1;
    defiChancesRestantes = 0;
    dernierVainqueurPli = gagnant;
    dernierPliRepriseEnJeu = gagnantEtaitASec && nbCartesDernierPli > 0;
    indexCourant = gagnant;

    final fini =
        joueurs.any((j) => j.nombreCartes == 52) ||
        _coups >= _maxCoups; // garde-fou anti-boucle infinie
    phase = fini ? PhasePartie.partieFinie : PhasePartie.reflexionBot;
    if (fini) analyseur.arreter();

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
      // Le chrono de décision du joueur démarre ICI : c'est la seule mesure
      // propre du rythme humain, indépendante de la vitesse du bot.
      analyseur.notifierMainHumaine();
      notifyListeners();
      return;
    }

    phase = PhasePartie.reflexionBot;

    // En duel, le bot n'a pas de cadence propre : il épouse celle du joueur
    // (voir CerveauTempo). En table à 4, rythme historique inchangé.
    final delai = config.estDuel
        ? cerveau.delaiPoseMs
        : _poseBotMinMs + _rng.nextInt(_poseBotAmplitudeMs);

    _timerBot = Timer(Duration(milliseconds: delai), () {
      if (phase != PhasePartie.reflexionBot) return;
      if (joueurs[indexCourant].estBot) _poserCarte(indexCourant);
    });
    notifyListeners();
  }

  // Confort UI -------------------------------------------------------
  JoueurPartie get humain => joueurs.first;

  /// L'adversaire-machine. En duel c'est `joueurs[1]` ; en table à 4, le
  /// premier bot (Marc) — utilisé pour l'affichage de l'harmonie.
  JoueurPartie get adversaire =>
      joueurs.firstWhere((j) => j.estBot, orElse: () => joueurs.last);

  JoueurPartie? get vainqueurFinal {
    for (final j in joueurs) {
      if (j.nombreCartes == 52) return j;
    }
    return null;
  }
}
