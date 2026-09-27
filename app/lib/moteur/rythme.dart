import 'dart:math';

// ---------------------------------------------------------------------------
// Miroir de rythme — le cœur du mode duel 1 contre 1.
//
// L'adversaire-machine n'a PAS de vitesse propre : il épouse celle du joueur
// humain. Toutes les mesures sont exprimées dans le même référentiel que
// resolveur_tape.py (le chronomètre part du début de la dépose, jamais d'un
// instant invisible côté table), ce qui rendra le futur résolveur réseau
// compatible sans refonte.
//
// Point de conception important : on mesure le délai de DÉCISION du joueur
// (« c'est à toi » -> « carte posée »), et non l'intervalle entre deux
// révélations. Mesurer l'intervalle créerait une boucle de rétroaction
// positive : bot lent -> humain mesuré lent -> bot encore plus lent -> ...
// Ici la mesure est indépendante de la vitesse du bot, donc stable.
// ---------------------------------------------------------------------------

/// Bornage en double, sans passer par [num.clamp] qui perd le type.
double _born(double valeur, double plancher, double plafond) =>
    valeur < plancher ? plancher : (valeur > plafond ? plafond : valeur);

/// Interpolation linéaire de [debut] vers [fin] selon [t] dans [0,1].
double _interpole(double debut, double fin, double t) =>
    debut + (fin - debut) * t;

/// Arrondi + bornage en entier.
int _arrondiBorne(double valeur, int plancher, int plafond) {
  final arrondi = valeur.round();
  if (arrondi < plancher) return plancher;
  if (arrondi > plafond) return plafond;
  return arrondi;
}

/// Mesure le rythme du joueur humain et en déduit son indice de maîtrise.
///
/// Une instance vit le temps d'une partie : [demarrer] la remet à zéro et
/// lance l'horloge interne. L'UI et le moteur l'alimentent via les quatre
/// méthodes `notifier*`.
class AnalyseurRythme {
  final Stopwatch _horloge = Stopwatch();

  // --- Calibrage des moyennes mobiles exponentielles ---------------------
  static const double _alphaDecision = 0.35;
  static const double _alphaTape = 0.45;
  static const double _alphaVariabilite = 0.25;

  /// La maîtrise est lissée lentement : elle ne doit pas sauter d'un cran
  /// sur un seul bon coup.
  static const double _alphaMaitrise = 0.15;

  /// Au-delà, la mesure est ÉCARTÉE : appel téléphonique, pause,
  /// distraction. Sans ce rejet, le bot s'endormirait après chaque
  /// interruption et l'harmonie serait rompue.
  static const int _delaiMaxPrisEnCompteMs = 8000;

  // --- Plages de normalisation de la vitesse de décision (ms) ------------
  static const double _decisionTresRapideMs = 550;
  static const double _decisionLenteMs = 2600;

  // --- Valeurs de repli avant que le joueur soit mesurable ---------------
  static const double _decisionRepliMs = 1400;
  static const double _tapeRepliMs = 420;

  /// Point de départ neutre de la maîtrise, avant toute mesure.
  static const double _maitriseInitiale = 0.35;

  /// Nombre de coups humains nécessaire pour considérer le rythme acquis.
  static const int _coupsAvantChauffe = 3;

  int _instantMainHumaine = 0;
  int _instantDoublon = 0;
  bool _doublonOuvert = false;

  double _decisionEma = _decisionRepliMs;
  double _ecartAbsoluEma = 0;
  double _tapeEma = _tapeRepliMs;
  double _maitriseLissee = _maitriseInitiale;

  int _coupsHumain = 0;
  int _doublonsVus = 0;
  int _doublonsGagnes = 0;
  bool _chauffe = false;

  // ------------------------------------------------------------------ //
  // Cycle de vie                                                       //
  // ------------------------------------------------------------------ //

  /// Remet tout à zéro et lance l'horloge. À appeler à chaque nouvelle
  /// partie.
  void demarrer() {
    _instantMainHumaine = 0;
    _instantDoublon = 0;
    _doublonOuvert = false;
    _decisionEma = _decisionRepliMs;
    _ecartAbsoluEma = 0;
    _tapeEma = _tapeRepliMs;
    _maitriseLissee = _maitriseInitiale;
    _coupsHumain = 0;
    _doublonsVus = 0;
    _doublonsGagnes = 0;
    _chauffe = false;
    _horloge
      ..reset()
      ..start();
  }

  /// Arrête l'horloge (fin de partie, sortie d'écran).
  void arreter() {
    _horloge.stop();
    _doublonOuvert = false;
  }

  int get _maintenant => _horloge.elapsedMilliseconds;

  // ------------------------------------------------------------------ //
  // Alimentation par le moteur et l'UI                                 //
  // ------------------------------------------------------------------ //

  /// La main vient de revenir au joueur humain : le chrono de décision
  /// démarre ici.
  void notifierMainHumaine() {
    _instantMainHumaine = _maintenant;
  }

  /// Le joueur humain vient de poser sa carte.
  void notifierPoseHumaine() {
    _coupsHumain++;

    final delai = _maintenant - _instantMainHumaine;
    _instantMainHumaine = _maintenant;

    // Mesure invalide ou parasite : on la jette sans polluer la moyenne.
    if (delai <= 0 || delai > _delaiMaxPrisEnCompteMs) {
      _chauffe = _coupsHumain >= _coupsAvantChauffe;
      return;
    }

    _decisionEma += _alphaDecision * (delai - _decisionEma);

    // Dispersion autour de la moyenne : sert la composante « régularité ».
    final ecart = (delai - _decisionEma).abs();
    _ecartAbsoluEma += _alphaVariabilite * (ecart - _ecartAbsoluEma);

    _chauffe = _coupsHumain >= _coupsAvantChauffe;
    _recalculerMaitrise();
  }

  /// Un doublon vient d'apparaître : le chrono de tape démarre.
  void notifierDoublonOuvert() {
    _doublonsVus++;
    _instantDoublon = _maintenant;
    _doublonOuvert = true;
  }

  /// Le joueur humain a tapé. [aGagne] indique s'il a remporté la course.
  void notifierTapeHumaine({required bool aGagne}) {
    if (!_doublonOuvert) return;
    _doublonOuvert = false;
    if (aGagne) _doublonsGagnes++;

    final delai = _maintenant - _instantDoublon;
    if (delai <= 0 || delai > _delaiMaxPrisEnCompteMs) return;

    _tapeEma += _alphaTape * (delai - _tapeEma);
    _recalculerMaitrise();
  }

  // ------------------------------------------------------------------ //
  // Indice de maîtrise                                                 //
  // ------------------------------------------------------------------ //
  void _recalculerMaitrise() {
    final brute = _maitriseBrute();
    _maitriseLissee += _alphaMaitrise * (brute - _maitriseLissee);
  }

  /// M dans [0,1] : vitesse (45 %), précision sur doublons (40 %),
  /// régularité (15 %).
  double _maitriseBrute() {
    // Vitesse de décision : plus le délai est court, plus le joueur est vif.
    final vitesse = _born(
      (_decisionLenteMs - _decisionEma) /
          (_decisionLenteMs - _decisionTresRapideMs),
      0.0,
      1.0,
    );

    // Précision : la seule vraie « adresse » mesurable à ce jeu. Avant le
    // premier doublon, on reste neutre pour ne pas punir un début de partie.
    final precision = _doublonsVus == 0
        ? 0.5
        : _born(_doublonsGagnes / _doublonsVus, 0.0, 1.0);

    // Régularité : un joueur constant est un joueur qui maîtrise son tempo.
    final coeffVariation =
        _decisionEma <= 0 ? 1.0 : _ecartAbsoluEma / _decisionEma;
    final regularite = _born(1.0 - coeffVariation, 0.0, 1.0);

    return _born(
      0.45 * vitesse + 0.40 * precision + 0.15 * regularite,
      0.0,
      1.0,
    );
  }

  // ------------------------------------------------------------------ //
  // Lecture                                                            //
  // ------------------------------------------------------------------ //

  /// Délai de décision lissé du joueur, en ms.
  double get tempsDecisionMs => _decisionEma;

  /// Délai de tape lissé du joueur, en ms.
  double get tempsTapeMs => _tapeEma;

  /// Indice de maîtrise dans [0,1].
  double get maitrise => _maitriseLissee;

  /// Vrai dès que le rythme du joueur est considéré comme acquis.
  bool get estChauffe => _chauffe;

  int get coupsHumain => _coupsHumain;
  int get doublonsVus => _doublonsVus;
  int get doublonsGagnes => _doublonsGagnes;

  /// Libellé lisible de la maîtrise, pour l'entête et le bandeau.
  String get libelleMaitrise {
    final m = _maitriseLissee;
    if (m < 0.25) return 'Débutant';
    if (m < 0.50) return 'Habitué';
    if (m < 0.75) return 'Aguerri';
    return 'Fulgurant';
  }

  /// Score dérivé de la maîtrise. Remplace le `1420` codé en dur de
  /// l'entête ; la plage est calée dessus pour rester crédible.
  int get scoreAffiche => (1200 + _maitriseLissee * 600).round();
}

/// Traduit le rythme mesuré du joueur en délais concrets pour le bot.
///
/// Deux sorties : [delaiPoseMs] (tempo de pose de sa carte) et
/// [reflexeBotMs] (moyenne de sa log-normale sur un doublon). La fenêtre
/// d'équité devient elle aussi adaptative via [fenetreEquiteMs] : figée à
/// 650 ms elle rendait la course au doublon binaire en tête-à-tête.
class CerveauTempo {
  CerveauTempo(this.analyseur);

  final AnalyseurRythme analyseur;
  final Random _rng = Random();

  /// Plancher absolu de pose : en dessous, la carte n'a plus le temps
  /// d'atterrir à l'écran et l'harmonie serait trahie par l'illisibilité.
  static const int plancherPoseMs = 220;

  /// Plafond de pose : au-delà, la table s'éteint.
  static const int plafondPoseMs = 1600;

  // --- Fenêtre d'équité de la course au tap --------------------------
  static const int plancherEquiteMs = 480;
  static const int plafondEquiteMs = 850;
  static const double _penteEquite = 0.72;
  static const double _ordonneeEquite = 250;

  // --- Réflexe du bot sur doublon ------------------------------------
  /// Joueur novice : le bot tape tard, la course est gagnable.
  static const double reflexeBotLentMs = 430;

  /// Joueur expert : le bot serre, la course devient tendue.
  static const double reflexeBotVifMs = 245;

  /// Amplitude du jitter : jamais d'horloge mécanique.
  static const double amplitudeJitter = 0.12;

  /// Repli tant que le rythme du joueur n'est pas acquis : exactement le
  /// comportement historique (520 à 940 ms), pour ne rien changer au
  /// ressenti des tout premiers coups.
  int _repliPoseMs() => 520 + _rng.nextInt(420);

  /// Rapport appliqué au tempo du joueur.
  /// > 1 : le bot temporise (joueur novice, on lui laisse respirer).
  /// = 1 : miroir parfait.
  /// < 1 : le bot presse (joueur expert, la tension monte).
  double get ratioTempo => _interpole(1.05, 0.82, analyseur.maitrise);

  double _ciblePoseMs() {
    final jitter = 1.0 + (_rng.nextDouble() * 2 - 1) * amplitudeJitter;
    return analyseur.tempsDecisionMs * ratioTempo * jitter;
  }

  /// Délai avant que le bot pose sa carte, en ms.
  int get delaiPoseMs {
    if (!analyseur.estChauffe) return _repliPoseMs();

    // Bascule progressive sur 4 coups : pas d'à-coup au démarrage.
    final progression = _born(
      (analyseur.coupsHumain - AnalyseurRythme._coupsAvantChauffe) / 4,
      0.0,
      1.0,
    );
    final brut =
        _repliPoseMs() * (1 - progression) + _ciblePoseMs() * progression;
    return _arrondiBorne(brut, plancherPoseMs, plafondPoseMs);
  }

  /// Fenêtre d'équité adaptative : le verdict du bot n'est jamais prononcé
  /// avant que la carte ait pu être VUE, et cette fenêtre suit le tempo du
  /// joueur au lieu d'être figée.
  int get fenetreEquiteMs => _arrondiBorne(
        _penteEquite * analyseur.tempsDecisionMs + _ordonneeEquite,
        plancherEquiteMs,
        plafondEquiteMs,
      );

  /// Moyenne de la log-normale du bot sur un doublon. La dispersion
  /// (sigma 0.25) et le plancher physiologique (120 ms) restent appliqués
  /// côté moteur, conformément à ProfilReflexe du résolveur Python.
  double get reflexeBotMs =>
      _interpole(reflexeBotLentMs, reflexeBotVifMs, analyseur.maitrise);

  /// Rend l'harmonie LISIBLE : dit au joueur si le bot le suit, le presse
  /// ou temporise. Affiché dans le bandeau de la table.
  String get libelleRythme {
    if (!analyseur.estChauffe) return 'Il t’observe…';
    final r = ratioTempo;
    if (r > 1.02) return 'Il temporise';
    if (r < 0.98) return 'Il accélère';
    return 'En phase avec toi';
  }
}
