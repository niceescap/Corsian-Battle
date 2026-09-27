import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../modeles.dart';
import '../moteur/partie_locale.dart';
import '../widgets/carte_volante.dart';
import '../widgets/carte_widget.dart';
import '../widgets/effet_pli.dart';
import '../widgets/entete.dart';
import '../widgets/fleche_joueur.dart';
import '../widgets/tas_joueur.dart';

/// Écran de la table animé par [PartieLocale].
///
/// Deux configurations, un seul écran :
/// - [ModePartie.duel] : 1 contre 1, l'adversaire-machine épouse le rythme
///   du joueur (voir moteur/rythme.dart). Disposition en vis-à-vis.
/// - [ModePartie.tableQuatre] : la table historique face à Marc, Julie et
///   Théo, chacun avec son temps de réaction fixe. Disposition en arc.
///
/// Les phases de gain et de perte d'un pli sont désormais incarnées
/// (flash, score flottant, secousse de table, bannière, retour haptique),
/// mais plafonnées à 700 ms : la demande centrale du duel est la VITESSE,
/// aucun effet ne doit la trahir ni avaler un geste.
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
/// `derniereRaisonPli` et `dernierPliRepriseEnJeu`. Sans cet instantané,
/// les effets joueraient la mauvaise émotion.
class _EvenementPli {
  final int vainqueur;
  final int nombreCartes;
  final String message;
  final String raison;
  final bool repriseEnJeu;

  const _EvenementPli({
    required this.vainqueur,
    required this.nombreCartes,
    required this.message,
    required this.raison,
    required this.repriseEnJeu,
  });

  bool get estDoublon => raison == 'Doublon';
  bool get estDefiManque => raison == 'Défi manqué';
}

class _EcranTableState extends State<EcranTable>
    with SingleTickerProviderStateMixin {
  final _rng = Random();
  late final PartieLocale _partie;

  final List<_CarteCentre> _pliVisible = [];
  final List<Widget> _volantes = [];

  double _derniereVitesseHumain = 1200;
  bool _feuDoublon = false;
  bool _dialogAffiche = false;

  late final AnimationController _ctrlRamasse;
  _LotRamasse? _ramassage;

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
  String? _popupCommentaire;
  int _clePopup = 0;
  Timer? _timerPopup;

  String? _banniereTexte;
  Color _banniereCouleur = Colors.redAccent;
  int _cleBanniere = 0;
  Timer? _timerBanniere;

  /// Toute variation déclenche une secousse de table (perte d'un pli).
  int _compteurSecousses = 0;

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

    final String titre;
    final String detail;
    final Color fond;

    if (_partie.estPartieNulle) {
      // Cas réel et fréquent en duel : les deux tas se renvoient les cartes
      // sans jamais produire de vainqueur. Annoncer une partie nulle, pas un
      // « match interrompu » qui se lirait comme un bug.
      titre = 'Partie nulle';
      detail = widget.config.estDuel
          ? 'Les deux tas se renvoient les cartes indéfiniment.\nAucun vainqueur : on redistribue.'
          : 'La table boucle sans vainqueur.\nOn redistribue les cartes.';
      fond = const Color(0xFF37474F);
    } else if (gagnant == null) {
      titre = 'Match interrompu';
      detail = '';
      fond = const Color(0xFF37474F);
    } else if (gagnant.estBot) {
      titre = '${gagnant.nom} remporte la partie';
      detail = _defaiteDetail();
      fond = const Color(0xFF7B2C2C);
    } else {
      titre = 'Tu gagnes la partie ! 🎉';
      detail = _victoireDetail();
      fond = const Color(0xFF0F5C3E);
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: fond,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          titre,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 21,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (detail.isNotEmpty)
              Text(
                detail,
                style: const TextStyle(color: Colors.white70, fontSize: 13.5),
              ),
            const SizedBox(height: 14),
            _ligneBilan(
              'Niveau détecté',
              _partie.analyseur.libelleMaitrise,
            ),
            if (_partie.analyseur.doublonsVus > 0)
              _ligneBilan(
                'Doublons tapés',
                '${_partie.analyseur.doublonsGagnes}'
                ' / ${_partie.analyseur.doublonsVus}',
              ),
            _ligneBilan(
              'Ton tempo moyen',
              '${_partie.analyseur.tempsDecisionMs.round()} ms',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _quitterTable();
            },
            child: const Text('Menu'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _reinitialiser();
            },
            child: const Text(
              'Rejouer',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ligneBilan(String etiquette, String valeur) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            etiquette,
            style: const TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
          Text(
            valeur,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  String _victoireDetail() {
    final a = _partie.analyseur;
    if (a.maitrise > 0.70) {
      return 'Tu joues à pleine vitesse et il suivait à peine.\n'
          'Le miroir a craqué : tu es au-dessus.';
    }
    if (a.doublonsVus > 0 && a.doublonsGagnes > a.doublonsVus / 2) {
      return 'Tes tapes sur doublon ont fait la différence.';
    }
    return 'Les 52 cartes sont dans ton tas.';
  }

  String _defaiteDetail() {
    final a = _partie.analyseur;
    if (a.maitrise < 0.30) {
      return 'Il jouait à ton rythme, doucement. Prends ta revanche plus vif.';
    }
    if (a.doublonsVus > 0 && a.doublonsGagnes == 0) {
      return 'Aucun doublon tapé sur ${a.doublonsVus} : c’est là que ça se joue.';
    }
    return 'Il a tenu ta cadence jusqu’au bout.';
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
      _banniereTexte = null;
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
    // Annonce immédiate : le joueur doit savoir qu'une course s'ouvre.
    _lancerBanniere('DOUBLON !', Colors.redAccent, 620);
  }

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

  /// Annonce LA règle qui a donné le pli, et signale la reprise-en-jeu.
  String _messageRamasse(int vainqueur, int nb) {
    final nom = _partie.joueurs[vainqueur].nom;
    String base;
    if (_partie.derniereRaisonPli == 'Doublon') {
      base = '$nom a tapé sur le doublon : $nb carte(s) !';
    } else if (_partie.derniereRaisonPli == 'Défi manqué') {
      base = 'Défi manqué : $nom remporte $nb carte(s).';
    } else {
      base = '$nom ramasse $nb carte(s).';
    }
    if (_partie.dernierPliRepriseEnJeu && vainqueur == 0) {
      return '$base\n💥 Tu reviens en jeu !';
    }
    return base;
  }

  void _onPliRamasse(int indexVainqueur, int nombreCartes) {
    // L'instantané est figé ICI : le balayage peut être différé, et pendant
    // ce temps le moteur réinitialise déjà `derniereRaisonPli`. Sans ça, les
    // effets joueraient la mauvaise émotion.
    final evenement = _EvenementPli(
      vainqueur: indexVainqueur,
      nombreCartes: nombreCartes,
      message: _messageRamasse(indexVainqueur, nombreCartes),
      raison: _partie.derniereRaisonPli,
      repriseEnJeu: _partie.dernierPliRepriseEnJeu && indexVainqueur == 0,
    );

    // La carte qui vient de déclencher le ramassage (carte perdante d'un
    // défi manqué, ou seconde carte d'un doublon) est encore EN VOL. On
    // diffère le balayage jusqu'à son atterrissage : sinon elle resterait
    // orpheline sur le tapis et donnerait la suite.
    if (_volantes.isNotEmpty) {
      _ramassageEnAttente = true;
      _evenementEnAttente = evenement;
      setState(() => _feuDoublon = false);
      return;
    }
    _executerRamassage(evenement);
  }

  void _executerRamassage(_EvenementPli evenement) {
    final taille = _tailleEcran();

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

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(evenement.message),
        ),
      );
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
  // Effets de gain / perte                                             //
  // ------------------------------------------------------------------ //
  static const List<String> _crisVictoire = [
    'FULGURANT !',
    'DANS TA MAIN !',
    'IMPARABLE !',
    'LE PLI EXPLOSE !',
    'TAPÉ !',
  ];

  static const List<String> _crisDefaite = [
    'IL A EU LE GESTE',
    'TROP JUSTE…',
    'IL SUIVAIT TON RYTHME',
  ];

  String _cri(bool estGain) {
    final source = estGain ? _crisVictoire : _crisDefaite;
    return source[_rng.nextInt(source.length)];
  }

  void _jouerEffetPli(_EvenementPli evenement) {
    final estGain = evenement.vainqueur == 0;

    if (estGain) {
      RetourTactile.gain();
      _lancerFlash(
        evenement.estDoublon ? Colors.white : const Color(0xFF43A047),
        evenement.estDoublon ? 0.55 : 0.40,
        evenement.estDoublon ? 420 : 340,
      );
      _lancerPopup(
        evenement.nombreCartes,
        true,
        evenement.repriseEnJeu
            ? 'TU REVIENS EN JEU !'
            : (evenement.estDoublon ? _cri(true) : null),
      );
      if (evenement.estDoublon) {
        _lancerBanniere('À TOI !', Colors.amberAccent, 700);
      } else if (evenement.estDefiManque) {
        _lancerBanniere('DÉFI MANQUÉ !', Colors.amber, 660);
      }
      return;
    }

    RetourTactile.perte();
    // La secousse accompagne le balayage : la table « encaisse » la perte.
    setState(() => _compteurSecousses++);
    _lancerFlash(const Color(0xFFB71C1C), 0.38, 400);
    _lancerPopup(
      evenement.nombreCartes,
      false,
      evenement.estDoublon ? _cri(false) : null,
    );
    if (evenement.estDoublon) {
      _lancerBanniere('IL A TAPÉ !', Colors.redAccent, 680);
    } else if (evenement.estDefiManque) {
      _lancerBanniere('TU AS CRAQUÉ', Colors.deepOrange, 660);
    }
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

  void _lancerPopup(int nombre, bool estGain, String? commentaire) {
    _timerPopup?.cancel();
    setState(() {
      _clePopup++;
      _popupNombre = nombre;
      _popupGain = estGain;
      _popupCommentaire = commentaire;
    });
    _timerPopup = Timer(const Duration(milliseconds: kDureeMaxEffetMs + 80), () {
      if (!mounted) return;
      setState(() => _popupNombre = null);
    });
  }

  void _lancerBanniere(String texte, Color couleur, int dureeMs) {
    _timerBanniere?.cancel();
    final duree = min(dureeMs, kDureeMaxEffetMs);
    setState(() {
      _cleBanniere++;
      _banniereTexte = texte;
      _banniereCouleur = couleur;
    });
    _timerBanniere = Timer(Duration(milliseconds: duree), () {
      if (!mounted) return;
      setState(() => _banniereTexte = null);
    });
  }

  // ------------------------------------------------------------------ //
  // Géométrie                                                          //
  // ------------------------------------------------------------------ //
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
    // En duel (nAdversaires == 1) l'angle vaut 0 : l'adversaire est pile
    // au sommet, en vis-à-vis. En table à 4, l'arc 9h -> 3h est conservé.
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
                    Entete(
                      score: _partie.joueurs.isEmpty
                          ? null
                          : _partie.analyseur.scoreAffiche,
                      libelle: _partie.joueurs.isEmpty
                          ? null
                          : _partie.analyseur.libelleMaitrise,
                      onRetour: _quitterTable,
                    ),
                    // La secousse englobe TOUTE la table : tapis, cartes et
                    // joueurs tremblent ensemble sur une perte.
                    Expanded(
                      child: SecousseTapis(
                        declencheur: _compteurSecousses,
                        enfant: _table(taille),
                      ),
                    ),
                  ],
                ),

                // Zone de tap sur doublon : plein écran pendant la course.
                if (_feuDoublon) _zoneTape(taille),

                // Bandeau d'état / consignes.
                Positioned(
                  left: 12,
                  bottom: 160,
                  child: IgnorePointer(child: _bandeau()),
                ),

                // --- Effets : toujours au-dessus, toujours IgnorePointer ---
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
                        commentaire: _popupCommentaire,
                      ),
                    ),
                  ),

                if (_banniereTexte != null)
                  Positioned.fill(
                    child: Align(
                      alignment: const Alignment(0, -0.42),
                      child: BanniereEvenement(
                        key: ValueKey(_cleBanniere),
                        texte: _banniereTexte!,
                        couleur: _banniereCouleur,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _table(Size taille) {
    if (_partie.joueurs.isEmpty) {
      return const Center(
        child: Text(
          'Distribution des cartes…',
          style: TextStyle(color: Colors.white70),
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
        _tapis(taille),

        // En duel : l'adversaire en vis-à-vis, avec son indicateur
        // d'harmonie. En table à 4 : l'arc historique 9h -> 3h.
        ..._zoneAdversaires(taille, adversaires),

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
              if (!_partie.humainPose()) {
                // Refus limpide plutôt qu'un geste avalé sans réponse.
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(const SnackBar(
                    duration: Duration(milliseconds: 700),
                    content: Text('Pas ton tour !'),
                  ));
                return;
              }
              _derniereVitesseHumain = vitesse;
            },
          ),
        ),
      ],
    );
  }

  /// Zone des adversaires selon le mode de table.
  ///
  /// Duel : un seul panneau en vis-à-vis, au sommet.
  /// Table à 4 : l'arc historique 9h -> 3h, inchangé.
  List<Widget> _zoneAdversaires(Size taille, List<JoueurUI> adversaires) {
    if (_partie.config.estDuel) {
      return [
        Positioned(
          left: 0,
          right: 0,
          top: taille.height * 0.035,
          child: _panneauAdversaire(taille),
        ),
      ];
    }

    return [
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
    ];
  }

  /// Panneau de l'adversaire-machine en duel : identité, tas, et surtout
  /// l'indicateur d'HARMONIE — le joueur doit voir que sa cadence est suivie.
  Widget _panneauAdversaire(Size taille) {
    final bot = _partie.adversaire;
    final estActif = _partie.phase == PhasePartie.reflexionBot &&
        _partie.joueurs[_partie.indexCourant].estBot;
    final maitrise = _partie.analyseur.maitrise;

    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: taille.width * 0.72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
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
            Stack(
              alignment: Alignment.center,
              children: [
                CircleAvatar(
                  radius: 19,
                  backgroundColor: Colors.white12,
                  child: const Icon(
                    Icons.smart_toy,
                    color: Color(0xFFFFD54F),
                    size: 22,
                  ),
                ),
                if (estActif)
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          const AlwaysStoppedAnimation(Color(0xFFFFD54F)),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 11),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bot.nom,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${bot.nombreCartes}',
                        style: const TextStyle(
                          color: Color(0xFFFFD54F),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _iconeHarmonie(),
                      size: 12,
                      color: Colors.white54,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _libelleHarmonie(),
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Jauge de maîtrise : rend l'adaptation LISIBLE. Le joueur voit
            // le bot se caler sur lui.
            SizedBox(
              width: 46,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: maitrise),
                      duration: const Duration(milliseconds: 400),
                      builder: (context, valeur, _) => LinearProgressIndicator(
                        value: valeur,
                        minHeight: 5,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation(
                          Color(0xFFFFD54F),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'RYTHME',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconeHarmonie() {
    if (!_partie.analyseur.estChauffe) return Icons.visibility;
    final r = _partie.cerveau.ratioTempo;
    if (r > 1.02) return Icons.hourglass_bottom;
    if (r < 0.98) return Icons.bolt;
    return Icons.sync_alt;
  }

  /// Délègue au cerveau tempo : source de vérité unique du vocabulaire.
  String _libelleHarmonie() => _partie.cerveau.libelleRythme;

  Widget _tapis(Size taille) {
    return Positioned(
      left: taille.width * 0.1,
      right: taille.width * 0.1,
      top: taille.height * 0.14,
      height: taille.height * 0.55,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0F5C3E),
          gradient: RadialGradient(
            center: const Alignment(0, -0.1),
            radius: 1.1,
            colors: [
              const Color(0xFF1B8A5C).withOpacity(0.85),
              const Color(0xFF0F5C3E).withOpacity(0.0),
            ],
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white24, width: 2),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 24, spreadRadius: 2),
          ],
        ),
        child: Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.10), width: 2),
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

  Widget _zoneTape(Size taille) {
    // Bande basse uniquement : ne recouvre PAS le centre du tapis —
    // la lecture du pli reste dégagée pendant toute la course au tap.
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: taille.height * 0.26,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _partie.humainTape,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.red.withOpacity(0.0),
                Colors.red.withOpacity(0.55),
                Colors.red,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
          alignment: Alignment.center,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
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
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bandeau() {
    if (_partie.joueurs.isEmpty) return const SizedBox.shrink();
    String texte;
    switch (_partie.phase) {
      case PhasePartie.attenteHumain:
        texte = 'À toi — swipe ta carte !';
        break;
      case PhasePartie.reflexionBot:
        texte = widget.config.estDuel
            ? '${_partie.joueurs[_partie.indexCourant].nom} suit ton rythme…'
            : '${_partie.joueurs[_partie.indexCourant].nom} réfléchit…';
        break;
      case PhasePartie.courseTap:
        texte = 'Qui tape le plus vite ?!';
        break;
      case PhasePartie.partieFinie:
        texte = 'Partie terminée.';
    }
    if (_partie.defiActif) {
      texte += '\nDéfi : ${_partie.joueurs[_partie.indexCourant].nom} doit '
          'sortir une figure (${_partie.defiChancesRestantes} restantes)';
    }
    // En duel, on rend l'harmonie explicite : c'est le cœur de la demande.
    if (widget.config.estDuel && _partie.phase != PhasePartie.partieFinie) {
      texte += '\n${_libelleHarmonie()}';
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
