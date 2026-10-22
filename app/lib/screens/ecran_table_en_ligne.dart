import 'dart:async';

import 'package:flutter/material.dart';

import '../net/client_jeu.dart';
import '../net/erreur_reseau.dart';
import '../net/modeles_proto.dart';
import '../widgets/carte_widget.dart';
import '../widgets/entete.dart';
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

class _EcranTableEnLigneState extends State<EcranTableEnLigne> {
  /// Instantané courant de la table.
  EtatTable? _etat;

  /// A-t-on déjà déclaré le siège prêt ?
  bool _pretEnvoye = false;

  /// Siège effectif de ce client. Le serveur l'envoie dans `bienvenue`,
  /// puis le rappelle dans chaque `table_etat` (`mon_siege`).
  int _monSiege = -1;

  /// Cartes du pli, dans l'ordre de pose.
  final List<String> _pli = [];

  /// Le pli est-il en train d'être ramassé ?
  bool _feuDoublon = false;

  /// Un message d'erreur technique à montrer (écran hors-jeu).
  String? _erreur;

  /// L'app est-elle reconnectée ? (bandeau discret)
  bool _connecte = true;

  /// Horodatage du début de la fenêtre de doublon (chronomètre local).
  DateTime? _debutFenetre;

  /// Le chronomètre de fin de fenêtre de doublon.
  Timer? _minuteurFenetre;

  final List<StreamSubscription<dynamic>> _abonnements = [];

  @override
  void initState() {
    super.initState();
    _ecouter();
  }

  @override
  void dispose() {
    for (final abonnement in _abonnements) {
      abonnement.cancel();
    }
    _minuteurFenetre?.cancel();
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
        if (etat.etat == 'attente' && !_pretEnvoye) {
          // On se déclare prêt une seule fois, dès qu'on voit la table en
          // attente. Le serveur lance la partie quand tous sont prêts.
          _pretEnvoye = true;
          widget.client.marquerPret();
        }
        if (etat.pli.isNotEmpty) {
          _pli
            ..clear()
            ..addAll(etat.pli);
        }
      });
    });

    ajouter(widget.client.cartes, (CartePosee posee) {
      if (!mounted) return;
      setState(() {
        // La carte annoncée par `doublon_ouvert` a déjà été animée : on ne
        // la remet pas au pli pour éviter un doublon visuel.
        if (!posee.annonce) {
          _pli.add(posee.carte);
        }
        if (posee.suivant == _monSiege) {
          // C'est à nous de jouer : rien à faire ici, l'UI indique « à toi ».
        }
      });
    });

    ajouter(widget.client.doublons, (DoublonOuvert fenetre) {
      if (!mounted) return;
      setState(() {
        _feuDoublon = true;
        // Le chronomètre part AU RENDU de l'animation : c'est la mesure
        // locale qui départage les joueurs, jamais une horloge murale
        // (`docs/PROTOCOLE.md` §9).
        _debutFenetre = DateTime.now();
      });
      _minuteurFenetre?.cancel();
      _minuteurFenetre = Timer(
        Duration(milliseconds: fenetre.fenetreMs),
        () {
          if (!mounted) return;
          setState(() => _feuDoublon = false);
        },
      );
    });

    ajouter(widget.client.verdicts, (DoublonResolu _) {
      if (!mounted) return;
      setState(() => _feuDoublon = false);
      _minuteurFenetre?.cancel();
    });

    ajouter(widget.client.plis, (PliGagne _) {
      if (!mounted) return;
      // Le pli est retiré : le serveur le renvoie dans le prochain
      // `table_etat`.
      setState(() => _pli.clear());
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
  void _poserCarte() {
    widget.client.poserCarte();
  }

  void _taper() {
    final debut = _debutFenetre;
    if (debut == null) return;
    final delai = DateTime.now().difference(debut).inMilliseconds;
    widget.client.taper(delai);
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
    final etat = _etat;
    final monSiegeInfo =
        _monSiege < 0 ? null : etat?.sieges.firstWhere(
              (s) => s.numero == _monSiege,
              orElse: () => const SiegeInfo(
                numero: -1,
                pseudo: '',
                nbCartes: 0,
                present: false,
                estBot: false,
              ),
            );
    final monNbCartes = monSiegeInfo?.nbCartes ?? 0;
    final aMonTour = etat?.suivant == _monSiege;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF12694A), Color(0xFF0B3D2E), Color(0xFF071F18)],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Entete(onRetour: () => Navigator.of(context).pop()),
              if (!_connecte) _bandeauPerdu(),
              Expanded(child: _tapis(etat, aMonTour)),
              _zoneJoueur(monNbCartes, aMonTour),
            ],
          ),
        ),
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

  Widget _tapis(EtatTable? etat, bool aMonTour) {
    final sieges = etat?.sieges ?? const <SiegeInfo>[];
    final adversaires = _monSiege < 0
        ? const <SiegeInfo>[]
        : sieges.where((s) => s.numero != _monSiege).toList();

    return GestureDetector(
      // Le doublon se joue en TAPANT N'IMPORTE OÙ SUR LE TAPIS.
      onTapDown: (_) {
        if (_feuDoublon) _taper();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _feuDoublon
              ? const Color(0xFF7B1F1F)
              : const Color(0xFF0E5A41),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _feuDoublon ? Colors.redAccent : Colors.white12,
            width: _feuDoublon ? 3 : 1,
          ),
        ),
        child: Stack(
          children: [
            // Adversaires, en arc au-dessus.
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final adversaire in adversaires)
                    _bandeauAdversaire(adversaire, etat?.suivant),
                ],
              ),
            ),
            // Pli, au centre.
            Center(
              child: _pliVue(),
            ),
            // Curseur « à toi de jouer ».
            if (aMonTour)
              const Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: _Pulseur(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pliVue() {
    if (_pli.isEmpty) {
      return const SizedBox.shrink();
    }
    // On montre au plus les 5 dernières cartes, en éventail.
    const maximum = 5;
    final visibles = _pli.length > maximum
        ? _pli.sublist(_pli.length - maximum)
        : _pli;
    const largeur = 44.0;
    return SizedBox(
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < visibles.length; i++)
            Positioned(
              left: (visibles.length - 1 - i) * 26.0,
              child: Transform.rotate(
                angle: (i - (visibles.length - 1) / 2) * 0.06,
                child: CarteWidget(
                  code: visibles[i],
                  largeur: largeur,
                  hauteur: largeur * 1.406,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bandeauAdversaire(SiegeInfo adverse, int? suivant) {
    final actif = suivant == adverse.numero;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: actif ? const Color(0xFFFFD54F) : Colors.white12,
          width: actif ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (adverse.estBot)
            const Icon(Icons.smart_toy, color: Colors.white38, size: 14)
          else
            const Icon(Icons.person, color: Colors.white54, size: 14),
          const SizedBox(width: 6),
          Text(
            adverse.pseudo,
            style: TextStyle(
              color: adverse.present ? Colors.white : Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${adverse.nbCartes}',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _zoneJoueur(int nbCartes, bool aMonTour) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TasJoueur(
              nombreCartes: nbCartes,
              onCarteJouee: (_) => _poserCarte(),
            ),
          ),
          const SizedBox(width: 12),
          if (aMonTour)
            Container(
              height: 84,
              width: 84,
              decoration: BoxDecoration(
                color: const Color(0xFFFFD54F),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Color(0xFF071F18),
                size: 44,
              ),
            )
          else
            const SizedBox(width: 84),
        ],
      ),
    );
  }
}

/// Curseur « à toi de jouer » : une pulsation douce, sans mot.
class _Pulseur extends StatefulWidget {
  const _Pulseur();

  @override
  State<_Pulseur> createState() => _PulseurState();
}

class _PulseurState extends State<_Pulseur>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, enfant) => Opacity(
        opacity: 0.45 + 0.45 * _ctrl.value,
        child: const Icon(
          Icons.touch_app,
          color: Color(0xFFFFD54F),
          size: 30,
        ),
      ),
    );
  }
}
