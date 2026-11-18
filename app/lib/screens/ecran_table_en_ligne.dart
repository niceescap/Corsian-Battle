import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../diagnostic.dart';
import '../geometry/geometrie_table_adaptative.dart';
import '../modeles.dart';
import '../net/client_jeu.dart';
import '../net/erreur_reseau.dart';
import '../net/modeles_proto.dart';
import '../widgets/carte_volante.dart';
import '../widgets/carte_widget.dart';
import '../widgets/effet_pli.dart';
import '../widgets/entete.dart';
import '../widgets/fleche_joueur.dart';
import '../widgets/tas_joueur.dart';

/// Écran de la partie **en ligne**.
///
/// Le serveur est l'unique autorité : cet écran n'invente rien. Il
/// affiche ce que le serveur raconte, envoie des intentions (« je pose »,
/// « je tape ») et ne décide d'aucun résultat.
///
/// UX UNIVERSELLE : pendant la partie, aucun mot. Le sens passe par la
/// couleur (vert = gagné, rouge = perdu), les pictogrammes, les chiffres et
/// la direction des animations. Les seuls mots autorisés sont les pseudos
/// (noms propres) et le code de table.
class EcranTableEnLigne extends StatefulWidget {
  /// Client WebSocket déjà ouvert sur la table.
  final ClientJeu client;

  /// Code de la table (affiché à l'invitation).
  final String codeTable;

  /// Siège de ce client, s'il est déjà connu à la construction de l'écran.
  /// `-1` si le serveur ne l'a pas encore communiqué : l'écran lit alors le
  /// siège dans l'instantané `bienvenue` / `table_etat`.
  final int monSiege;

  const EcranTableEnLigne({
    super.key,
    required this.client,
    required this.codeTable,
    this.monSiege = -1,
  });

  @override
  State<EcranTableEnLigne> createState() => _EcranTableEnLigneState();
}

class _CarteCentre {
  final String code;
  final Offset position;
  final double rotation;

  const _CarteCentre({
    required this.code,
    required this.position,
    required this.rotation,
  });
}

class _LotRamasse {
  final List<_CarteCentre> cartes;
  final Offset arrivee;

  const _LotRamasse({required this.cartes, required this.arrivee});
}

class _EvenementPli {
  final int? vainqueur;
  final int nombreCartes;
  final String raison;

  const _EvenementPli({
    required this.vainqueur,
    required this.nombreCartes,
    required this.raison,
  });
}

class _AnnonceCarte {
  final int siege;
  final String code;

  const _AnnonceCarte({required this.siege, required this.code});
}

class _EcranTableEnLigneState extends State<EcranTableEnLigne>
    with TickerProviderStateMixin {
  final _rng = Random();

  /// Instantané courant de la table.
  EtatTable? _etat;

  /// Siège effectif de ce client. Le serveur l'envoie dans `bienvenue`,
  /// puis le rappelle dans chaque `table_etat` (`mon_siege`).
  int _monSiege = -1;

  /// Cartes posées au centre, figées à leur point d'arrivée.
  ///
  /// C'est la source unique du rendu central et du ramassage. Toutes les
  /// cartes reçues depuis le dernier pli attribué y restent jusqu'au
  /// balayage, afin qu'aucune ne disparaisse avant le vainqueur.
  final List<_CarteCentre> _centreVisible = [];

  /// Cartes en vol entre un tas et le centre du tapis.
  final List<Widget> _volantes = [];

  /// Pose en attente d'une taille de table mesurée.
  ///
  /// Un `carte_posee` peut arriver avant le premier `LayoutBuilder` du
  /// `Stack`. Sans ce report, le vol serait perdu et la carte n'apparaîtrait
  /// qu'au prochain instantané serveur.
  _AnnonceCarte? _annonceEnAttente;

  /// Le pli est-il en train d'être ramassé ?
  bool _feuDoublon = false;

  /// Un message d'erreur technique à montrer (écran hors-jeu).
  String? _erreur;

  /// L'app est-elle reconnectée ? (bandeau discret)
  bool _connecte = true;

  /// Horodatage du début de la fenêtre de doublon (mesure locale du délai).
  DateTime? _debutFenetre;

  /// Compte à rebours avant le lancement, en secondes.
  int? _rebours;

  /// Message bref d'un mouvement de table (joueur parti, bot.take la main).
  String? _mouvement;

  /// Animation du balayage du pli vers son vainqueur.
  late final AnimationController _ctrlRamasse;
  _LotRamasse? _ramassage;

  /// Pulsation du geste « tape » pendant un doublon.
  late final AnimationController _ctrlIndice;

  /// Si le ramassage arrive avant la fin du vol de la carte déclencheuse.
  bool _ramassageEnAttente = false;
  _EvenementPli? _evenementEnAttente;

  /// Effets de gain et de perte, identiques à la table 1v1.
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

  /// Toute perte déclenche une secousse du tapis.
  int _compteurSecousses = 0;

  /// Zone de jeu mesurée à chaque build : source de vérité du tapis et du vol.
  Size _tailleTable = Size.zero;

  /// Géométrie adaptative courante, reconstruite quand la surface ou les
  /// sièges occupés changent. Un cache évite de recalculer les ancres à
  /// chaque image d'animation.
  AdaptiveTableGeometry? _geometrie;
  Size _surfaceGeometrie = Size.zero;
  List<int> _siegesGeometrie = const <int>[];
  int _siegeLocalGeometrie = -1;

  final List<StreamSubscription<dynamic>> _abonnements = [];

  @override
  void initState() {
    super.initState();

    _ctrlRamasse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(() {
      if (mounted) setState(() {});
    });

    _ctrlIndice = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _ecouter();
  }

  @override
  void dispose() {
    tracer('dispose EcranTableEnLigne');
    _timerFlash?.cancel();
    _timerPopup?.cancel();
    _timerBanniere?.cancel();
    for (final abonnement in _abonnements) {
      abonnement.cancel();
    }
    _ctrlRamasse.dispose();
    _ctrlIndice.dispose();
    unawaited(
      widget.client.disposing().onError<Object>((erreur, pile) {
        tracer(
          'Erreur fermeture client depuis EcranTableEnLigne : $erreur | $pile',
        );
      }),
    );
    super.dispose();
  }

  void _ecouter() {
    void ajouter<T>(Stream<T> flux, void Function(T) traiter) {
      _abonnements.add(flux.listen(traiter));
    }

    ajouter(widget.client.etats, (EtatTable etat) {
      if (!mounted) return;
      setState(() {
        _etat = etat;
        if (etat.monSiege >= 0) _monSiege = etat.monSiege;
        _erreur = null;
      });
      _repererDepuisEtat(etat);
    });

    ajouter(widget.client.cartes, (CartePosee posee) {
      if (!mounted) return;
      if (posee.annonce) return;
      final annonce = _AnnonceCarte(
        siege: posee.siege,
        code: posee.carte,
      );
      if (_tailleTable == Size.zero) {
        _annonceEnAttente = annonce;
      } else {
        _animerAnnonce(annonce);
      }
    });

    ajouter(widget.client.rebours, (int secondes) {
      if (!mounted) return;
      setState(() => _rebours = secondes);
      // Le compte à rebours est court : on l'efface au bout du temps.
      Future<void>.delayed(Duration(seconds: secondes + 1)).then((_) {
        if (!mounted) return;
        setState(() => _rebours = null);
      });
    });

    ajouter(widget.client.mouvements, (Map<String, dynamic> evenement) {
      if (!mounted) return;
      final type = '${evenement['type'] ?? ''}';
      String? texte;
      if (type == 'bot_prend_la_main') {
        texte = 'UN JOUEUR PART';
      } else if (type == 'joueur_parti') {
        texte = 'DÉPART';
      } else if (type == 'partie_lancee') {
        texte = null;
      }
      if (texte == null) return;
      setState(() => _mouvement = texte);
      Future<void>.delayed(const Duration(seconds: 3)).then((_) {
        if (!mounted) return;
        setState(() => _mouvement = null);
      });
    });

    ajouter(widget.client.doublons, (DoublonOuvert fenetre) {
      if (!mounted) return;
      // Une fenêtre précédente peut encore exister si son verdict a été
      // perdu. Le serveur ne garde qu'un état de tape courant : on repart
      // donc d'une fenêtre propre pour le nouveau coup.
      _tapeEnvoyee = false;
      setState(() {
        _feuDoublon = true;
        // Le chronomètre part à l'annonce, comme à la table 1v1.
        _debutFenetre = DateTime.now();
        final etat = _etat;
        final siege = etat?.suivant;
        final carte = fenetre.cartes.length > 1 ? fenetre.cartes[1] : null;
        if (siege != null && carte != null && carte.isNotEmpty) {
          final annonce = _AnnonceCarte(siege: siege, code: carte);
          if (_tailleTable == Size.zero) {
            _annonceEnAttente = annonce;
          } else {
            _animerAnnonce(annonce);
          }
        }
      });
      RetourTactile.doublon();
    });

    ajouter(widget.client.verdicts, (DoublonResolu _) {
      if (!mounted) return;
      setState(() {
        _feuDoublon = false;
        _debutFenetre = null;
        _tapeEnvoyee = false;
      });
    });

    ajouter(widget.client.plis, (PliGagne pli) {
      if (!mounted) return;
      _onPliRamasse(pli.gagnant, pli.nbCartes, pli.raison);
    });

    ajouter(widget.client.fins, (PartieFinie fin) {
      if (!mounted) return;
      _afficherBilan(fin);
    });

    ajouter(widget.client.erreurs, (ErreurReseau erreur) {
      if (!mounted) return;
      // Une erreur « pas ton tour » est un raté normal : pas d'écran d'erreur.
      if (erreur.code == 'pas_ton_tour') return;
      setState(() => _erreur = erreur.message);
    });

    ajouter(widget.client.reconnexions, (_) {
      if (!mounted) return;
      // La socket est revenue : l'alerte de coupure n'a plus lieu d'être.
      setState(() {
        _connecte = true;
        _erreur = null;
      });
    });

    ajouter(widget.client.fermetures, (int code) {
      if (!mounted) return;
      setState(() => _connecte = false);
      // 4401 : jeton expiré → il faut se reconnecter et renouveler.
      if (code == 4401) {
        _erreur = 'Session expirée. Reconnecte-toi.';
      } else if (code == 4404) {
        _erreur = 'Table introuvable.';
      } else if (code == 4409) {
        _erreur = 'Table complète.';
      } else {
        _erreur = 'Connexion perdue.';
      }
    });
  }

  // ------------------------------------------------------------------ //
  // Actions du joueur                                                  //
  // ------------------------------------------------------------------ //
  /// Nombre de coups pour lesquels on a déjà envoyé une pose.
  ///
  /// Le compteur suit les tours, pas le `seq` global : les trames privées
  /// d'un autre siège font avancer ce dernier sans changer le tour.
  int _coupsJeus = -1;

  bool _poserCarte() {
    final etat = _etat;
    // Ce n'est pas le tour du joueur : la pose n'est pas permise.
    if (etat == null || etat.suivant != _monSiege || _monSiege < 0) {
      return false;
    }
    // Le tour a déjà été joué : on ignore (double-tap).
    if (etat.nbCoups <= _coupsJeus) return false;
    _coupsJeus = etat.nbCoups;
    widget.client.poserCarte();
    return true;
  }

  /// A-t-on déjà tapé pendant la fenêtre courante ?
  ///
  /// Le serveur ne retient que le PREMIER envoi d'un siège : en renvoyer
  /// plusieurs serait compté comme une anomalie (et consigné en suspicion).
  bool _tapeEnvoyee = false;

  void _taper() {
    final debut = _debutFenetre;
    if (debut == null || _tapeEnvoyee || !_feuDoublon) {
      return;
    }
    _tapeEnvoyee = true;
    final delai = DateTime.now().difference(debut).inMilliseconds;
    widget.client.taper(delai);
  }

  // ------------------------------------------------------------------ //
  // Animations, alignées sur la table 1v1                              //
  // ------------------------------------------------------------------ //
  void _animerAnnonce(_AnnonceCarte annonce) {
    final siege = annonce.siege;
    if (!_numerosJoueurs().contains(siege)) return;
    _animerCartePosee(siege, annonce.code, siege == _monSiege);
  }

  void _animerCartePosee(
    int siege,
    String code,
    bool venantDeMoi,
  ) {
    final taille = _tailleTable;
    if (taille == Size.zero) return;

    final vitesse = venantDeMoi ? 1200.0 : 900 + _rng.nextDouble() * 1400;
    // Départ : ancre du joueur. Arrivée : zone COMMUNE au centre du tapis,
    // indépendante du siège, comme avant le template adaptatif.
    final arrivee = _positionArrivee(taille);
    final depart = _origineJoueur(siege, taille);
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
        if (!mounted) return;
        setState(() {
          _volantes.remove(volante);
          final arrive = _CarteCentre(
            code: code,
            position: arrivee,
            rotation: rotationFinale,
          );
          _centreVisible.add(arrive);
        });
        _declencherRamassageEnAttente();
      },
    );
    setState(() => _volantes.add(volante));
  }

  void _onPliRamasse(int? gagnant, int nombreCartes, String raison) {
    final evenement = _EvenementPli(
      vainqueur: gagnant,
      nombreCartes: nombreCartes,
      raison: raison,
    );

    if (_volantes.isNotEmpty) {
      _ramassageEnAttente = true;
      _evenementEnAttente = evenement;
      _fermerDoublon();
      return;
    }
    _executerRamassage(evenement);
  }

  void _executerRamassage(_EvenementPli evenement) {
    final taille = _tailleTable;

    if (taille == Size.zero ||
        _centreVisible.isEmpty ||
        evenement.vainqueur == null) {
      _jouerEffetPli(evenement);
      setState(() {
        _feuDoublon = false;
        _debutFenetre = null;
        _tapeEnvoyee = false;
      });
      return;
    }

    _jouerEffetPli(evenement);
    setState(() {
      _ramassage = _LotRamasse(
        cartes: List<_CarteCentre>.of(_centreVisible),
        arrivee: _origineJoueur(evenement.vainqueur!, taille),
      );
      _feuDoublon = false;
      _debutFenetre = null;
      _tapeEnvoyee = false;
      _centreVisible.clear();
    });
    _ctrlRamasse.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _ramassage = null);
    });
  }

  void _fermerDoublon() {
    if (!mounted) return;
    setState(() {
      _feuDoublon = false;
    });
  }

  void _declencherRamassageEnAttente() {
    if (!_ramassageEnAttente || _volantes.isNotEmpty) return;
    _ramassageEnAttente = false;
    final evenement = _evenementEnAttente;
    _evenementEnAttente = null;
    if (evenement != null) _executerRamassage(evenement);
  }

  void _repererDepuisEtat(EtatTable etat) {
    final taille = _tailleTable;
    if (taille == Size.zero || _volantes.isNotEmpty) return;
    if (_ramassageEnAttente) return;
    // Les annonces de pose sont la source normale du rendu. L'instantané ne
    // sert qu'à repeupler un tapis vide (page initiale ou reconnexion), pas
    // à réécrire un pli déjà animé.
    if (_annonceEnAttente != null || _centreVisible.isNotEmpty) return;
    final cartes = etat.pli;
    if (cartes.isEmpty) {
      _centreVisible.clear();
      if (mounted) setState(() {});
      return;
    }

    _centreVisible.addAll([
        for (var i = 0; i < cartes.length; i++)
          _CarteCentre(
            code: cartes[i],
            position: _positionArrivee(taille),
            rotation: (_rng.nextDouble() - 0.5) * 0.6,
          ),
      ]);
    if (mounted) setState(() {});
  }

  void _jouerEffetPli(_EvenementPli evenement) {
    if (evenement.vainqueur == _monSiege) {
      RetourTactile.gain();
      final doublon = evenement.raison.toLowerCase() == 'doublon';
      _lancerFlash(
        doublon ? Colors.white : const Color(0xFF43A047),
        doublon ? 0.55 : 0.40,
        doublon ? 420 : 340,
      );
      _lancerPopup(evenement.nombreCartes, true, _iconeGain(evenement));
      if (doublon) {
        _lancerBanniere(Icons.back_hand, Colors.amberAccent, 700);
      }
      return;
    }

    RetourTactile.perte();
    setState(() => _compteurSecousses++);
    _lancerFlash(const Color(0xFFB71C1C), 0.38, 400);
    _lancerPopup(evenement.nombreCartes, false, _iconePerte(evenement));
    if (evenement.raison.toLowerCase() == 'doublon') {
      _lancerBanniere(Icons.back_hand, Colors.redAccent, 680);
    }
  }

  IconData? _iconeGain(_EvenementPli evenement) {
    if (evenement.raison.toLowerCase() == 'doublon') return Icons.back_hand;
    if (evenement.raison.toLowerCase() == 'defi_manque') {
      return Icons.card_giftcard;
    }
    return null;
  }

  IconData? _iconePerte(_EvenementPli evenement) {
    if (evenement.raison.toLowerCase() == 'doublon') return Icons.back_hand;
    if (evenement.raison.toLowerCase() == 'defi_manque') return Icons.close;
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
      if (mounted) setState(() => _flashCouleur = null);
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
      if (mounted) setState(() => _popupNombre = null);
    });
  }

  void _lancerBanniere(IconData icone, Color couleur, int dureeMs) {
    _timerBanniere?.cancel();
    setState(() {
      _cleBanniere++;
      _banniereIcone = icone;
      _banniereCouleur = couleur;
    });
    _timerBanniere = Timer(
      Duration(milliseconds: min(dureeMs, kDureeMaxEffetMs)),
      () {
        if (mounted) setState(() => _banniereIcone = null);
      },
    );
  }

  Rect _rectTapis(Size z) {
    final geometrie = _construireGeometrie(z);
    if (geometrie != null) {
      final tapis = geometrie.tapis;
      return Rect.fromLTWH(
        tapis.left,
        tapis.top,
        tapis.width,
        tapis.height,
      );
    }

    final margeX = z.width * 0.07;
    final cote = min(z.width - 2 * margeX, z.height * 0.56);
    final left = (z.width - cote) / 2;
    final top = z.height * 0.13;
    return Rect.fromLTWH(left, top, cote, cote);
  }

  Offset _origineJoueur(int siege, Size z) {
    final geometrie = _construireGeometrie(z);
    final point = geometrie?.siegeParIdentifiant(siege)?.positionTas;
    if (point != null) return Offset(point.x, point.y);
    return Offset(z.width / 2, z.height - 40);
  }

  /// Zone d'atterrissage commune à tous les joueurs.
  ///
  /// Toutes les cartes jouées convergent vers le centre du tapis, avec de
  /// petites variations aléatoires (position et rotation) dans un repère
  /// commun : le siège du joueur n'intervient pas. La destination est ainsi
  /// indépendante du nombre de joueurs et du gabarit du tapis, tout en
  /// produisant une superposition cyclique naturelle d'une carte à l'autre.
  Offset _positionArrivee(Size z) {
    final centre = _rectTapis(z).center;
    return Offset(
      centre.dx + (_rng.nextDouble() - 0.5) * 70,
      centre.dy + (_rng.nextDouble() - 0.5) * 44,
    );
  }

  List<int> _numerosJoueurs() {
    final sieges = _etat?.sieges ?? const <SiegeInfo>[];
    // Un siège participe s'il est occupé : joueur connecté (`present`) ou bot
    // de remplacement. Les sièges vides d'une table à 4 arrivent avec un
    // pseudo replié sur « Joueur » et aucun de ces marqueurs, donc ils ne
    // s'ajoutent jamais à la géométrie.
    final occupes = sieges
        .where((siege) => siege.present || siege.estBot)
        .map((siege) => siege.numero)
        .toSet()
        .toList();
    if (occupes.isEmpty) return const <int>[];

    final moi = _monSiege >= 0 ? _monSiege : occupes.first;
    occupes.add(moi);
    occupes.sort();
    return <int>[moi, ...occupes.where((numero) => numero != moi)];
  }

  /// Géométrie adaptative construite à partir des sièges réellement occupés.
  ///
  /// L'identité des joueurs reste portée par le serveur : seul le numéro de
  /// siège est utilisé ici, et le siège local est toujours à 6h.
  AdaptiveTableGeometry? _construireGeometrie(Size taille) {
    if (taille == Size.zero ||
        !taille.width.isFinite ||
        !taille.height.isFinite) {
      return null;
    }

    final numeros = _numerosJoueurs();
    if (numeros.length < 2 || numeros.length > 4) return null;

    if (_geometrie != null &&
        taille == _surfaceGeometrie &&
        numeros.length == _siegesGeometrie.length &&
        (_monSiege >= 0 ? _monSiege : numeros.first) ==
            _siegeLocalGeometrie) {
      var identiques = true;
      for (var i = 0; i < numeros.length; i++) {
        if (numeros[i] != _siegesGeometrie[i]) {
          identiques = false;
          break;
        }
      }
      if (identiques) return _geometrie;
    }

    try {
      _geometrie = AdaptiveTableGeometry(
        surface: TableSurface(width: taille.width, height: taille.height),
        siegesOccupes: numeros,
        siegeLocal: _monSiege >= 0 ? _monSiege : numeros.first,
      );
      _surfaceGeometrie = taille;
      _siegesGeometrie = List<int>.unmodifiable(numeros);
      _siegeLocalGeometrie = _monSiege >= 0 ? _monSiege : numeros.first;
      return _geometrie;
    } catch (_) {
      _geometrie = null;
      return null;
    }
  }

  void _afficherBilan(PartieFinie fin) {
    final gagne = fin.gagnant == _monSiege;
    final icone = fin.gagnant == null
        ? Icons.handshake
        : (gagne ? Icons.emoji_events : Icons.heart_broken);
    final mot = fin.gagnant == null ? 'DRAW' : (gagne ? 'WIN' : 'DEFEAT');
    final fond = fin.gagnant == null
        ? const Color(0xFF37474F)
        : (gagne ? const Color(0xFF0F5C3E) : const Color(0xFF7B2C2C));

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: fond,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
            for (final ligne in fin.stats)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        if (ligne.gagnant)
                          const Icon(
                            Icons.emoji_events,
                            color: Colors.amberAccent,
                            size: 16,
                          )
                        else
                          const SizedBox(width: 16),
                        const SizedBox(width: 8),
                        Text(
                          ligne.pseudo,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ],
                    ),
                    Text(
                      '${ligne.nbCartes}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.home_outlined, size: 18),
            label: const Text('MENU'),
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ //
  // Rendu                                                              //
  // ------------------------------------------------------------------ //
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B3D2E),
      body: SafeArea(
        child: Column(
          children: [
            Entete(onRetour: () => Navigator.of(context).pop()),
            if (!_connecte) _bandeauPerdu(),
            if (_rebours != null) _bandeauRebours(_rebours!),
            if (_mouvement != null) _bandeauMouvement(_mouvement!),
            Expanded(
              child: LayoutBuilder(
                builder: (context, contraintes) {
                  _tailleTable = Size(contraintes.maxWidth, contraintes.maxHeight);
                  final annonce = _annonceEnAttente;
                  if (annonce != null && _tailleTable != Size.zero) {
                    _annonceEnAttente = null;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _animerAnnonce(annonce);
                    });
                  }
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: SecousseTapis(
                          declencheur: _compteurSecousses,
                          enfant: _table(_tailleTable),
                        ),
                      ),
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
        ),
      ),
    );
  }

  /// Compte à rebours avant le lancement de la partie.
  Widget _bandeauRebours(int secondes) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFD54F),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.play_circle_outline, color: Color(0xFF071F18)),
          const SizedBox(width: 10),
          Text(
            '$secondes',
            style: const TextStyle(
              color: Color(0xFF071F18),
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  /// Message bref : un joueur est parti, un bot prend la main.
  Widget _bandeauMouvement(String texte) {
    return Container(
      width: double.infinity,
      color: Colors.black.withValues(alpha: 0.55),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.info_outline, color: Colors.white70, size: 16),
          const SizedBox(width: 8),
          Text(
            texte,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bandeauPerdu() {
    return Container(
      width: double.infinity,
      color: Colors.redAccent.withValues(alpha: 0.2),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off, color: Colors.redAccent, size: 16),
          const SizedBox(width: 8),
          Text(
            _erreur ?? 'Connexion perdue.',
            style: const TextStyle(
              color: Colors.redAccent,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(Size z) {
    final etat = _etat;
    if (etat == null) {
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

    final sieges = etat.sieges;
    final numerosOccupes = _numerosJoueurs();
    final adversaires = sieges
        .where((siege) =>
            siege.numero != _monSiege &&
            numerosOccupes.contains(siege.numero))
        .toList()
      ..sort((a, b) => a.numero.compareTo(b.numero));
    SiegeInfo? monSiegeInfo;
    if (_monSiege >= 0) {
      for (final siege in sieges) {
        if (siege.numero == _monSiege) {
          monSiegeInfo = siege;
          break;
        }
      }
    }
    final aMonTour = etat.suivant == _monSiege;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        _tapis(z),
        ..._zoneAdversaires(z, adversaires),
        for (final carte in _centreVisible)
          Positioned(
            left: carte.position.dx - kLargeurCarteTapis / 2,
            top: carte.position.dy - kHauteurCarteTapis / 2,
            child: Transform.rotate(
              angle: carte.rotation,
              child: CarteWidget(
                code: carte.code,
                largeur: kLargeurCarteTapis,
                hauteur: kHauteurCarteTapis,
              ),
            ),
          ),
        if (_ramassage != null)
          for (final carte in _ramassage!.cartes)
            Builder(
              builder: (_) {
                final t = Curves.easeIn.transform(_ctrlRamasse.value);
                final position = Offset.lerp(
                  carte.position,
                  _ramassage!.arrivee,
                  t,
                )!;
                return Positioned(
                  left: position.dx - kLargeurCarteTapis / 2,
                  top: position.dy - kHauteurCarteTapis / 2,
                  child: Opacity(
                    opacity: 1 - 0.7 * t,
                    child: Transform.rotate(
                      angle: carte.rotation * (1 - t),
                      child: CarteWidget(
                        code: carte.code,
                        largeur: kLargeurCarteTapis,
                        hauteur: kHauteurCarteTapis,
                      ),
                    ),
                  ),
                );
              },
            ),
        ..._volantes,
        if (etat.defi != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(child: _bandeauDefi(etat.defi!)),
          ),
        if (aMonTour && (monSiegeInfo?.nbCartes ?? 0) > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 116,
            child: Center(child: _indiceSwipe()),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: TasJoueur(
            nombreCartes: monSiegeInfo?.nbCartes ?? 0,
            onCarteJouee: (_) {
              if (!_poserCarte()) RetourTactile.refus();
            },
          ),
        ),
        if (_feuDoublon) _overlayTape(z),
      ],
    );
  }

  List<Widget> _zoneAdversaires(Size z, List<SiegeInfo> adversaires) {
    return [
      for (final adverse in adversaires)
        Builder(
          builder: (_) {
            final siege = _construireGeometrie(z)
                ?.siegeParIdentifiant(adverse.numero);
            if (siege == null) {
              return const SizedBox.shrink();
            }

            // La flèche pointe du joueur vers le centre du tapis.
            final angleRad = siege.angleRadians - pi / 2;
            // La pastille est centrée sur l'ancre du siège.
            final position = siege.positionTas;
            return Positioned(
              left: (position.x - 55)
                  .clamp(0.0, z.width - 110)
                  .toDouble(),
              top: (position.y - 32)
                  .clamp(0.0, z.height - 64)
                  .toDouble(),
              child: FlecheJoueur(
                joueur: JoueurUI(
                  id: '${adverse.numero}',
                  pseudo: adverse.pseudo,
                  nombreCartes: adverse.nbCartes,
                ),
                angleRad: angleRad,
              ),
            );
          },
        ),
    ];
  }

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

  Widget _tapis(Size z) {
    final rect = _rectTapis(z);
    return Positioned.fromRect(
      rect: rect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.1),
            radius: 1.15,
            colors: _feuDoublon
                ? const [Color(0xFF7A2B2B), Color(0xFF5E1F1F), Color(0xFF3E1414)]
                : const [Color(0xFF1A8159), Color(0xFF0F5C3E), Color(0xFF0A4630)],
            stops: const [0.0, 0.62, 1.0],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: _feuDoublon ? Colors.redAccent : Colors.white24,
            width: _feuDoublon ? 3 : 2,
          ),
          boxShadow: [
            BoxShadow(
              color: _feuDoublon ? Colors.red.withValues(alpha: 0.5) : Colors.black45,
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
                color: Colors.white.withValues(alpha: 0.10),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.style_outlined,
              size: 34,
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overlayTape(Size z) {
    final rect = _rectTapis(z);
    return Positioned.fromRect(
      rect: rect,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _taper(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            color: Colors.red.withValues(alpha: 0.22),
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

  /// Bandeau du défi en cours.
  ///
  /// Un pictogramme par chance restante, et le组团 du siège qui doit
  /// répondre mis en avant. Aucun mot : la règle est « la figure demandée
  /// est en jeu, réponds ».
  Widget _bandeauDefi(DefiInfo defi) {
    final jeReponds = defi.repondeur == _monSiege;
    final jePose = defi.poseur == _monSiege;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (jeReponds ? const Color(0xFFFFD54F) : Colors.black)
            .withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: jeReponds ? const Color(0xFFFFD54F) : Colors.white24,
          width: 2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            jeReponds ? Icons.reply : Icons.auto_awesome,
            color: jeReponds ? const Color(0xFF071F18) : Colors.amberAccent,
            size: 18,
          ),
          const SizedBox(width: 8),
          // Les chances restantes : un point par chance.
          for (var i = 0; i < defi.chancesRestantes; i++)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(
                Icons.circle,
                size: 8,
                color: jeReponds
                    ? const Color(0xFF071F18)
                    : Colors.amberAccent,
              ),
            ),
          if (jePose) ...[
            const SizedBox(width: 6),
            const Icon(Icons.pan_tool_alt_outlined,
                color: Colors.white54, size: 16),
          ],
        ],
      ),
    );
  }

}
