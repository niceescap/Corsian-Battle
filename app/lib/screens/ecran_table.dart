import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../modeles.dart';
import '../moteur/partie_locale.dart';
import '../widgets/carte_volante.dart';
import '../widgets/carte_widget.dart';
import '../widgets/effet_pli.dart';
import '../widgets/emplacement_pub.dart';
import '../widgets/entete.dart';
import '../widgets/fleche_joueur.dart';
import '../widgets/tas_joueur.dart';

/// Écran de la table animé par [PartieLocale].
///
/// UX UNIVERSELLE : pendant la partie, il n'y a RIEN À LIRE. Le sens passe
/// uniquement par la couleur (vert = gagné, rouge = perdu/urgence), les
/// pictogrammes, les chiffres et la direction des animations. Seuls les noms
/// propres (joueur, adversaires) subsistent.
///
/// Deux configurations, un seul écran :
/// - [ModePartie.duel] : 1 contre 1, l'adversaire-machine épouse le rythme du
///   joueur en INTERNE (moteur/rythme.dart) — la mécanique reste active mais
///   n'est plus exposée textuellement.
/// - [ModePartie.tableQuatre] : la table historique face à Marc, Julie et Théo.
///
/// Front remanié : tapis au format CARRÉ, ce qui libère une bande au-dessus
/// pour un emplacement publicitaire AdMob rectangulaire ; le paquet du joueur
/// est agrandi (+10 %) et remonté près de la zone de jeu ; la course au
/// doublon se joue en TAPANT N'IMPORTE OÙ SUR LE TAPIS, qui vire au rouge.
class EcranTable extends StatefulWidget {
  final ConfigPartie config;

  const EcranTable({super.key, this.config = const ConfigPartie.tableQuatre()});

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

/// Instantané du pli ramassé, figé au moment où le moteur l'attribue.
///
/// Nécessaire : le balayage peut être différé (la carte déclencheuse est
/// encore en vol), et pendant ce temps le moteur a déjà réinitialisé
/// `derniereRaisonPli` et `dernierPliRepriseEnJeu`. Sans cet instantané, les
/// effets joueraient la mauvaise émotion.
class _EvenementPli {
  final int vainqueur;
  final int nombreCartes;
  final String raison;
  final bool repriseEnJeu;

  const _EvenementPli({
    required this.vainqueur,
    required this.nombreCartes,
    required this.raison,
    required this.repriseEnJeu,
  });

  bool get estDoublon => raison == 'Doublon';
  bool get estDefiManque => raison == 'Défi manqué';
}

class _EcranTableState extends State<EcranTable>
    with TickerProviderStateMixin {
  final _rng = Random();
  late final PartieLocale _partie;

  final List<_CarteCentre> _pliVisible = [];
  final List<Widget> _volantes = [];

  double _derniereVitesseHumain = 1200;
  bool _feuDoublon = false;
  bool _dialogAffiche = false;

  late final AnimationController _ctrlRamasse;
  _LotRamasse? _ramassage;

  /// Pulsation douce de l'indice « à toi de jouer » et de la main du doublon.
  late final AnimationController _ctrlIndice;

  // --- Balayage différé (attend la fin du vol de la carte déclencheuse) --
  bool _ramassageEnAttente = false;
  _EvenementPli? _evenementEnAttente;

  // --- Effets ------------------------------------------------------------
  Color? _flashCouleur;
  double _flashOpacite = 0.4;
  int _flashDuree = 360;
  int _cleFlash = 0;
  Timer? _timerFlash;

  int? _popupNombre;
  bool _popupGain = true;
  IconData? _popupIcone;
  int _clePopup = 0;
  Timer? _timerPopup;

  IconData? _banniereIcone;
  Color _banniereCouleur = Colors.redAccent;
  int _cleBanniere = 0;
  Timer? _timerBanniere;

  /// Toute variation déclenche une secousse de table (perte d'un pli).
  int _compteurSecousses = 0;

  /// Taille de la zone de jeu (sous entête + pub), mise à jour à chaque
  /// build. Source de vérité géométrique pour le vol des cartes et le tapis.
  Size _tailleTable = Size.zero;

  @override
  void initState() {
    super.initState();

    _ctrlRamasse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(() => setState(() {}));

    _ctrlIndice = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _partie = PartieLocale();
    _partie.surPose = _onCartePosee;
    _partie.surPliRamasse = _onPliRamasse;
    _partie.surDoublon = _onDoublonOuvert;
    _partie.addListener(_surNotifMoteur);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _partie.nouvellePartie(configuration: widget.config);
    });
  }

  @override
  void dispose() {
    _timerFlash?.cancel();
    _timerPopup?.cancel();
    _timerBanniere?.cancel();
    _partie.removeListener(_surNotifMoteur);
    _partie.dispose();
    _ctrlRamasse.dispose();
    _ctrlIndice.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ //
  // Fin de partie                                                      //
  // ------------------------------------------------------------------ //
  void _surNotifMoteur() {
    if (!mounted) return;
    setState(() {});
    if (_partie.estFinie && !_dialogAffiche) {
      _dialogAffiche = true;
      _afficherDialogFin();
    }
  }

  void _afficherDialogFin() {
    final gagnant = _partie.vainqueurFinal;

    final IconData icone;
    final String mot; // terme anglais minimal, le picto porte l'essentiel
    final Color fond;

    if (_partie.estPartieNulle || gagnant == null) {
      icone = Icons.handshake;
      mot = 'DRAW';
      fond = const Color(0xFF37474F);
    } else if (gagnant.estBot) {
      icone = Icons.heart_broken;
      mot = 'DEFEAT';
      fond = const Color(0xFF7B2C2C);
    } else {
      icone = Icons.emoji_events;
      mot = 'WIN';
      fond = const Color(0xFF0F5C3E);
    }

    final a = _partie.analyseur;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: fond,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icone, size: 56, color: Colors.white),
            const SizedBox(height: 6),
            Text(
              mot,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 22,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Maîtrise : jauge seule, aucun mot.
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: a.maitrise,
                minHeight: 6,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Color(0xFFFFD54F)),
              ),
            ),
            const SizedBox(height: 14),
            _ligneStat(Icons.emoji_events, '${a.scoreAffiche}'),
            if (a.doublonsVus > 0)
              _ligneStat(Icons.back_hand, '${a.doublonsGagnes}/${a.doublonsVus}'),
            _ligneStat(Icons.timer_outlined, '${a.tempsDecisionMs.round()} ms'),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _quitterTable();
            },
            icon: const Icon(Icons.home_outlined, size: 18),
            label: const Text('MENU'),
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _reinitialiser();
            },
            icon: const Icon(Icons.replay, size: 18),
            label: const Text(
              'AGAIN',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  /// Ligne de bilan : picto + valeur (chiffre universel), aucun mot descriptif.
  Widget _ligneStat(IconData icone, String valeur) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icone, color: Colors.white54, size: 18),
          Text(
            valeur,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  void _quitterTable() {
    Navigator.of(context).maybePop();
  }

  void _reinitialiser() {
    setState(() {
      _dialogAffiche = false;
      _pliVisible.clear();
      _volantes.clear();
      _feuDoublon = false;
      _ramassage = null;
      _ramassageEnAttente = false;
      _evenementEnAttente = null;
      _flashCouleur = null;
      _popupNombre = null;
      _banniereIcone = null;
      _ctrlRamasse.reset();
    });
    _partie.nouvellePartie(configuration: widget.config);
  }

  // ------------------------------------------------------------------ //
  // Réactions aux événements du moteur                                 //
  // ------------------------------------------------------------------ //
  void _onDoublonOuvert() {
    setState(() => _feuDoublon = true);
    RetourTactile.doublon();
    // Signal 100 % visuel : le tapis vire au rouge (voir _overlayTape).
  }

  void _onCartePosee(int indexJoueur, String code, bool venantDHumain) {
    final taille = _tailleTable;
    if (taille == Size.zero) return;

    final vitesse =
        venantDHumain ? _derniereVitesseHumain : 900 + _rng.nextDouble() * 1400;
    final centre = _rectTapis(taille).center;
    final arrivee = Offset(
      centre.dx + (_rng.nextDouble() - 0.5) * 70,
      centre.dy + (_rng.nextDouble() - 0.5) * 44,
    );
    final depart = _origineJoueur(indexJoueur, taille);
    final rotationFinale = (_rng.nextDouble() - 0.5) * 0.6;

    if (venantDHumain) RetourTactile.pose();

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
        _declencherRamassageEnAttente();
      },
    );
    setState(() => _volantes.add(volante));
  }

  void _onPliRamasse(int indexVainqueur, int nombreCartes) {
    final evenement = _EvenementPli(
      vainqueur: indexVainqueur,
      nombreCartes: nombreCartes,
      raison: _partie.derniereRaisonPli,
      repriseEnJeu: _partie.dernierPliRepriseEnJeu && indexVainqueur == 0,
    );

    // La carte qui vient de déclencher le ramassage est encore EN VOL : on
    // diffère le balayage jusqu'à son atterrissage pour ne pas la laisser
    // orpheline sur le tapis.
    if (_volantes.isNotEmpty) {
      _ramassageEnAttente = true;
      _evenementEnAttente = evenement;
      setState(() => _feuDoublon = false);
      return;
    }
    _executerRamassage(evenement);
  }

  void _executerRamassage(_EvenementPli evenement) {
    final taille = _tailleTable;

    // Les effets émotionnels partent dans TOUS les cas, même si le balayage
    // visuel n'a rien à montrer : le gain/la perte doit toujours se lire.
    _jouerEffetPli(evenement);

    if (taille == Size.zero || _pliVisible.isEmpty) {
      setState(() => _feuDoublon = false);
      return;
    }

    setState(() {
      _ramassage = _LotRamasse(
        cartes: List<_CarteCentre>.of(_pliVisible),
        arrivee: _origineJoueur(evenement.vainqueur, taille),
      );
      _feuDoublon = false;
      _pliVisible.clear();
    });
    _ctrlRamasse.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _ramassage = null);
    });
  }

  void _declencherRamassageEnAttente() {
    if (!_ramassageEnAttente) return;
    if (_volantes.isNotEmpty) return;
    _ramassageEnAttente = false;
    final evenement = _evenementEnAttente;
    _evenementEnAttente = null;
    if (evenement == null) return;
    _executerRamassage(evenement);
  }

  // ------------------------------------------------------------------ //
  // Effets de gain / perte — pictogrammes, aucun mot                   //
  // ------------------------------------------------------------------ //
  void _jouerEffetPli(_EvenementPli evenement) {
    final estGain = evenement.vainqueur == 0;

    if (estGain) {
      RetourTactile.gain();
      _lancerFlash(
        evenement.estDoublon ? Colors.white : const Color(0xFF43A047),
        evenement.estDoublon ? 0.55 : 0.40,
        evenement.estDoublon ? 420 : 340,
      );
      _lancerPopup(evenement.nombreCartes, true, _iconeGain(evenement));
      if (evenement.estDoublon) {
        _lancerBanniere(Icons.back_hand, Colors.amberAccent, 700);
      }
      return;
    }

    RetourTactile.perte();
    // La secousse accompagne le balayage : la table « encaisse » la perte.
    setState(() => _compteurSecousses++);
    _lancerFlash(const Color(0xFFB71C1C), 0.38, 400);
    _lancerPopup(evenement.nombreCartes, false, _iconePerte(evenement));
    if (evenement.estDoublon) {
      _lancerBanniere(Icons.back_hand, Colors.redAccent, 680);
    }
  }

  IconData? _iconeGain(_EvenementPli e) {
    if (e.repriseEnJeu) return Icons.replay; // tu reviens en jeu
    if (e.estDoublon) return Icons.back_hand; // gagné au tap
    if (e.estDefiManque) return Icons.card_giftcard; // défi remporté
    return null;
  }

  IconData? _iconePerte(_EvenementPli e) {
    if (e.estDoublon) return Icons.back_hand; // l'autre a tapé
    if (e.estDefiManque) return Icons.close; // défi craqué
    return null;
  }

  void _lancerFlash(Color couleur, double opacite, int dureeMs) {
    _timerFlash?.cancel();
    setState(() {
      _cleFlash++;
      _flashCouleur = couleur;
      _flashOpacite = opacite;
      _flashDuree = min(dureeMs, kDureeMaxEffetMs);
    });
    _timerFlash = Timer(Duration(milliseconds: _flashDuree + 80), () {
      if (!mounted) return;
      setState(() => _flashCouleur = null);
    });
  }

  void _lancerPopup(int nombre, bool estGain, IconData? icone) {
    _timerPopup?.cancel();
    setState(() {
      _clePopup++;
      _popupNombre = nombre;
      _popupGain = estGain;
      _popupIcone = icone;
    });
    _timerPopup = Timer(const Duration(milliseconds: kDureeMaxEffetMs + 80), () {
      if (!mounted) return;
      setState(() => _popupNombre = null);
    });
  }

  void _lancerBanniere(IconData icone, Color couleur, int dureeMs) {
    _timerBanniere?.cancel();
    final duree = min(dureeMs, kDureeMaxEffetMs);
    setState(() {
      _cleBanniere++;
      _banniereIcone = icone;
      _banniereCouleur = couleur;
    });
    _timerBanniere = Timer(Duration(milliseconds: duree), () {
      if (!mounted) return;
      setState(() => _banniereIcone = null);
    });
  }

  // ------------------------------------------------------------------ //
  // Géométrie — tapis CARRÉ centré dans la zone de jeu                 //
  // ------------------------------------------------------------------ //

  /// Le tapis : un carré centré horizontalement, placé dans la partie haute
  /// de la zone de jeu pour laisser de l'air au paquet du joueur en bas.
  Rect _rectTapis(Size z) {
    final margeX = z.width * 0.07;
    final cote = min(z.width - 2 * margeX, z.height * 0.56);
    final left = (z.width - cote) / 2;
    final top = z.height * 0.13;
    return Rect.fromLTWH(left, top, cote, cote);
  }

  Offset _origineJoueur(int indexJoueur, Size z) {
    if (indexJoueur == 0) {
      // Centre du paquet du joueur, en bas de la zone.
      return Offset(z.width / 2 - 32, z.height - 40);
    }
    final nAdversaires = _partie.joueurs.length - 1;
    final rang = indexJoueur - 1;
    return _origineAdversaire(rang, nAdversaires, z);
  }

  /// Position d'un adversaire : en duel pile au sommet (vis-à-vis) ; en table
  /// à 4, répartis en arc au-dessus du tapis.
  Offset _origineAdversaire(int rang, int nAdversaires, Size z) {
    final angleDeg =
        nAdversaires == 1 ? 0.0 : -90 + (rang / (nAdversaires - 1)) * 180;
    final rad = angleDeg * pi / 180;
    final x = z.width / 2 + z.width * 0.30 * sin(rad);
    final y = z.height * 0.035 + 8 - 8 * cos(rad);
    return Offset(x - 24, y);
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
            final largeur = contraintes.maxWidth;
            return Column(
              children: [
                Entete(
                  score: _partie.joueurs.isEmpty
                      ? null
                      : _partie.analyseur.scoreAffiche,
                  onRetour: _quitterTable,
                ),
                // Emplacement AdMob rectangulaire, libéré par le tapis carré.
                EmplacementPub(
                  format: FormatPub.grandBanniere,
                  largeurDisponible: largeur,
                ),
                // Zone de jeu : tout le reste, mesuré précisément.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c2) {
                      _tailleTable = Size(c2.maxWidth, c2.maxHeight);
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: SecousseTapis(
                              declencheur: _compteurSecousses,
                              enfant: _table(_tailleTable),
                            ),
                          ),
                          // --- Effets plein écran, toujours IgnorePointer ---
                          if (_flashCouleur != null)
                            Positioned.fill(
                              child: FlashPli(
                                key: ValueKey(_cleFlash),
                                couleur: _flashCouleur!,
                                opaciteDepart: _flashOpacite,
                                dureeMs: _flashDuree,
                              ),
                            ),
                          if (_popupNombre != null)
                            Positioned.fill(
                              child: Center(
                                child: PopupScore(
                                  key: ValueKey(_clePopup),
                                  nombre: _popupNombre!,
                                  estGain: _popupGain,
                                  icone: _popupIcone,
                                ),
                              ),
                            ),
                          if (_banniereIcone != null)
                            Positioned.fill(
                              child: Align(
                                alignment: const Alignment(0, -0.45),
                                child: BanniereIcone(
                                  key: ValueKey(_cleBanniere),
                                  icone: _banniereIcone!,
                                  couleur: _banniereCouleur,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _table(Size z) {
    if (_partie.joueurs.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation(Colors.white38),
          ),
        ),
      );
    }

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
        _tapis(z),

        // Adversaires : vis-à-vis en duel, arc en table à 4.
        ..._zoneAdversaires(z, adversaires),

        // Pli visible au centre du tapis.
        for (final c in _pliVisible)
          Positioned(
            left: c.position.dx - kLargeurCarteTapis / 2,
            top: c.position.dy - kHauteurCarteTapis / 2,
            child: Transform.rotate(
              angle: c.rotation,
              child: CarteWidget(code: c.code, largeur: 64, hauteur: 90),
            ),
          ),

        // Balayage du pli vers le vainqueur.
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

        // Indice « à toi de jouer » : chevron qui pulse, aucun mot.
        if (_partie.auTourDeLHumain && _partie.humain.aDesCartes)
          Positioned(
            left: 0,
            right: 0,
            bottom: 116,
            child: Center(child: _indiceSwipe()),
          ),

        // Paquet du joueur : dos visible jusqu'au lancer, agrandi et remonté.
        Align(
          alignment: Alignment.bottomCenter,
          child: TasJoueur(
            nombreCartes: _partie.humain.nombreCartes,
            onCarteJouee: (vitesse) {
              if (!_partie.humainPose()) {
                // Refus sans texte : double tic haptique.
                RetourTactile.refus();
                return;
              }
              _derniereVitesseHumain = vitesse;
            },
          ),
        ),

        // Zone de tap sur doublon : TOUT le carré du tapis, qui vire au rouge.
        if (_feuDoublon) _overlayTape(z),
      ],
    );
  }

  /// Chevron pulsant au-dessus du paquet : « swipe vers le haut », universel.
  Widget _indiceSwipe() {
    return AnimatedBuilder(
      animation: _ctrlIndice,
      builder: (context, _) {
        final t = _ctrlIndice.value;
        return Opacity(
          opacity: 0.35 + 0.45 * t,
          child: Transform.translate(
            offset: Offset(0, -4 * t),
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Color(0x33FFD54F),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.keyboard_double_arrow_up,
                color: Color(0xFFFFD54F),
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Adversaires selon le mode : panneau unique en duel, arc en table à 4.
  List<Widget> _zoneAdversaires(Size z, List<JoueurUI> adversaires) {
    if (_partie.config.estDuel) {
      return [
        Positioned(
          left: 0,
          right: 0,
          top: z.height * 0.02,
          child: _panneauAdversaire(z),
        ),
      ];
    }

    return [
      for (var i = 0; i < adversaires.length; i++)
        Builder(builder: (_) {
          final n = adversaires.length;
          final angleDeg = n == 1 ? 0.0 : -90 + (i / (n - 1)) * 180;
          final rad = angleDeg * pi / 180;
          final x = z.width / 2 + z.width * 0.30 * sin(rad);
          final y = z.height * 0.035 + 8 - 8 * cos(rad);
          return Positioned(
            left: x - 55,
            top: y,
            child: FlecheJoueur(joueur: adversaires[i], angleRad: rad),
          );
        }),
    ];
  }

  /// Panneau adversaire MINIMALISTE : avatar, nom, dos du paquet, nombre de
  /// cartes. Toute la mécanique d'harmonisation du tempo reste active en
  /// interne (moteur/rythme.dart) mais n'est plus exposée au joueur.
  Widget _panneauAdversaire(Size z) {
    final bot = _partie.adversaire;
    final estActif = _partie.phase == PhasePartie.reflexionBot &&
        _partie.joueurs[_partie.indexCourant].estBot;

    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: z.width * 0.72),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: estActif
              ? const Color(0xFFFFD54F).withOpacity(0.16)
              : Colors.black.withOpacity(0.34),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: estActif ? const Color(0xFFFFD54F) : Colors.white24,
            width: estActif ? 2 : 1,
          ),
          boxShadow: estActif
              ? [
                  BoxShadow(
                    color: const Color(0xFFFFD54F).withOpacity(0.28),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Avatar (bot) + halo d'activité, sans texte.
            Stack(
              alignment: Alignment.center,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.white12,
                  child: const Icon(
                    Icons.smart_toy,
                    color: Color(0xFFFFD54F),
                    size: 21,
                  ),
                ),
                if (estActif)
                  const SizedBox(
                    width: 42,
                    height: 42,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Color(0xFFFFD54F)),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            // Dos du paquet de l'adversaire.
            Transform.scale(scale: 0.95, child: CarteWidget(largeur: 22, hauteur: 31)),
            const SizedBox(width: 10),
            // Nom (nom propre) + nombre de cartes (chiffre universel).
            Text(
              bot.nom,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '${bot.nombreCartes}',
                style: const TextStyle(
                  color: Color(0xFFFFD54F),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tapis(Size z) {
    final r = _rectTapis(z);
    return Positioned.fromRect(
      rect: r,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          // Arrêts OPAQUES : avec un gradient, la couleur de base serait
          // écrasée par le shader, le tapis ne doit jamais devenir
          // transparent sur sa périphérie.
          gradient: RadialGradient(
            center: const Alignment(0, -0.1),
            radius: 1.15,
            colors: _feuDoublon
                ? const [
                    Color(0xFF7A2B2B), // centre rougeâtre (urgence)
                    Color(0xFF5E1F1F),
                    Color(0xFF3E1414),
                  ]
                : const [
                    Color(0xFF1A8159),
                    Color(0xFF0F5C3E),
                    Color(0xFF0A4630),
                  ],
            stops: const [0.0, 0.62, 1.0],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: _feuDoublon ? Colors.redAccent : Colors.white24,
            width: _feuDoublon ? 3 : 2,
          ),
          boxShadow: [
            BoxShadow(
              color: _feuDoublon ? Colors.red.withOpacity(0.5) : Colors.black45,
              blurRadius: _feuDoublon ? 30 : 24,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.10),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.style_outlined,
              size: 34,
              color: Colors.white.withOpacity(0.10),
            ),
          ),
        ),
      ),
    );
  }

  /// Le carré du tapis ENTIER devient la zone de tap pendant un doublon.
  /// Voile rougeâtre + main pulsante (aucun mot) ; `opaque` pour capter le
  /// tap même au-dessus des cartes posées.
  Widget _overlayTape(Size z) {
    final r = _rectTapis(z);
    return Positioned.fromRect(
      rect: r,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _partie.humainTape,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            color: Colors.red.withOpacity(0.22),
            alignment: Alignment.center,
            child: AnimatedBuilder(
              animation: _ctrlIndice,
              builder: (context, _) {
                final t = _ctrlIndice.value;
                return Opacity(
                  opacity: 0.55 + 0.45 * t,
                  child: Transform.scale(
                    scale: 0.9 + 0.18 * t,
                    child: const Icon(
                      Icons.back_hand,
                      size: 62,
                      color: Colors.white,
                      shadows: [Shadow(color: Colors.black87, blurRadius: 16)],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
