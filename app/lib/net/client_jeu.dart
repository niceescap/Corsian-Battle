import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config_reseau.dart';
import 'erreur_reseau.dart';
import 'modeles_proto.dart';

/// Client WebSocket de `corsian-jeu`.
///
/// Le client n'envoie que des **intentions** : `poser_carte`, `tape`, `pret`.
/// Il ne décide d'aucun résultat, ne choisit jamais sa carte et ne envoie
/// jamais d'horodatage mural (`docs/PROTOCOLE.md` §2).
class ClientJeu {
  final ConfigurationReseau _config;

  WebSocketChannel? _canal;
  StreamSubscription<dynamic>? _abonnement;
  Timer? _minuteurPing;

  /// Dernier `seq` serveur reçu : c'est la valeur renvoyée dans `seq_attendu`.
  int _seq = 0;

  /// Code de fermeture reçu, s'il y en a eu un.
  int? codeFermeture;

  /// Le socket est-il ouvert ?
  bool get connecte => _canal != null;

  /// Le socket est-il actuellement établi (et non en cours de reconnexion) ?
  bool get ouvert => _ouvert;

  /// Messages « à toi de jouer » : [etat] et [table_etat].
  final StreamController<EtatTable> _etats =
      StreamController<EtatTable>.broadcast();

  /// Cartes posées.
  final StreamController<CartePosee> _cartes =
      StreamController<CartePosee>.broadcast();

  /// La carte du dessus de ce client (message privé).
  final StreamController<String> _carteController =
      StreamController<String>.broadcast();

  /// Ouverture d'une fenêtre de doublon.
  final StreamController<DoublonOuvert> _doublons =
      StreamController<DoublonOuvert>.broadcast();

  /// Verdict d'un doublon.
  final StreamController<DoublonResolu> _verdicts =
      StreamController<DoublonResolu>.broadcast();

  /// Pli attribué.
  final StreamController<PliGagne> _plis =
      StreamController<PliGagne>.broadcast();

  /// Fin de partie.
  final StreamController<PartieFinie> _fins =
      StreamController<PartieFinie>.broadcast();

  /// Erreur protocole ou technique.
  final StreamController<ErreurReseau> _erreurs =
      StreamController<ErreurReseau>.broadcast();

  /// Un joueur a rejoint ou quitté la table.
  final StreamController<Map<String, dynamic>> _mouvements =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Compte à rebours avant lancement.
  final StreamController<int> _rebours =
      StreamController<int>.broadcast();

  /// La socket s'est fermée.
  final StreamController<int> _fermetures =
      StreamController<int>.broadcast();

  /// Dernier instantané reçu.
  ///
  /// Il est mémorisé parce que le client s'abonne souvent APRÈS l'ouverture
  /// de la socket : `bienvenue` et le premier `table_etat` arriveraient
  /// sinon dans le vide, et l'app ne saurait ni son siège ni l'état de la
  /// table.
  EtatTable? _dernierEtat;

  /// Siège attribué par le serveur (`bienvenue`).
  int _siege = -1;

  /// La carte du dessus de CE client.
  ///
  /// Elle arrive par deux canaux : le message privé `ta_carte_suivante`, et
  /// l'instantané `table_etat` (où le serveur la place dans l'objet du
  /// siège). On la mémorise pour la restituer à l'écran : c'est elle que le
  /// joueur doit voir avant de lancer sa carte, et c'est elle que le
  /// doublon animationne.
  String? _carte;

  // --- Reconnexion ------------------------------------------------------
  /// Jeton et table, mémorisés pour pouvoir rouvrir la socket.
  String? _jeton;
  String? _codeTable;

  /// Numéro de tentative de reconnexion (0 = première ouverture).
  int _tentatives = 0;

  /// Minuteur de reconnexion en cours.
  Timer? _minuteurReconnexion;

  /// La reconnexion automatique est-elle active ?
  ///
  /// Elle l'est, sauf si la fermeture est « définitive » : table introuvable
  /// ou complète, version de protocole incompatible.
  bool _reconnexionAutorisee = true;

  /// Le socket est-il actuellement ouvert ?
  bool _ouvert = false;

  /// Fermeures qui interdisent toute reconnexion.
  static const Set<int> _fermeturesDefinitives = {4404, 4409, 4413};

  /// Dernier instantané reçu, rejoué à l'abonnement.
  EtatTable? get dernierEtat => _dernierEtat;

  /// Siège de ce client, `-1` tant que le serveur ne l'a pas donné.
  int get siege => _siege;

  /// La carte du dessus de ce client, si elle est connue.
  String? get maCarteConnue => _carte;

  ClientJeu({ConfigurationReseau? config})
      : _config = config ?? ConfigurationReseau.depuisDefines();

  /// Flux des instantanés, **multi-abonnement**, avec rejeu de l'état courant.
  ///
  /// Chaque appel rend un flux NEUF : l'abonné reçoit l'état en cours
  /// (s'il existe) puis les suivants. La salle d'attente et l'écran de jeu
  /// s'abonnent successivement au MÊME client : un flux à abonnement unique
  /// planterait au second `listen`, et un flux muet perdrait l'état initial.
  Stream<EtatTable> get etats {
    final deja = _dernierEtat;
    late final StreamController<EtatTable> controleur;
    StreamSubscription<EtatTable>? abonnement;
    controleur = StreamController<EtatTable>(
      onListen: () {
        if (deja != null) controleur.add(deja);
        abonnement = _etats.stream.listen(controleur.add);
      },
      onCancel: () => abonnement?.cancel(),
    );
    return controleur.stream;
  }
  Stream<CartePosee> get cartes => _cartes.stream;
  /// Flux de la carte du dessus de ce client, **multi-abonnement**.
  ///
  /// Comme `etats`, chaque appel rend un flux neuf qui rejoue la carte
  /// connue : l'écran de jeu s'abonne souvent après le premier message
  /// `ta_carte_suivante`, et l'ignorer laisserait le joueur sans sa carte.
  Stream<String> get maCarte {
    final deja = _carte;
    late final StreamController<String> controleur;
    StreamSubscription<String>? abonnement;
    controleur = StreamController<String>(
      onListen: () {
        if (deja != null) controleur.add(deja);
        abonnement = _carteController.stream.listen(controleur.add);
      },
      onCancel: () => abonnement?.cancel(),
    );
    return controleur.stream;
  }
  Stream<DoublonOuvert> get doublons => _doublons.stream;
  Stream<DoublonResolu> get verdicts => _verdicts.stream;
  Stream<PliGagne> get plis => _plis.stream;
  Stream<PartieFinie> get fins => _fins.stream;
  Stream<ErreurReseau> get erreurs => _erreurs.stream;
  Stream<Map<String, dynamic>> get mouvements => _mouvements.stream;
  Stream<int> get rebours => _rebours.stream;
  Stream<int> get fermetures => _fermetures.stream;

  /// Ouvre la socket et envoie le `bonjour`.
  ///
  /// Le jeton n'est **jamais** mis dans la query string : il finirait dans
  /// les journaux du serveur web (`docs/PROTOCOLE.md` §3).
  Future<void> ouvrir({
    required String jeton,
    required String codeTable,
    int versionProto = 1,
  }) async {
    _jeton = jeton;
    _codeTable = codeTable;
    _versionProto = versionProto;
    await _ouvrirSocket();
  }

  int _versionProto = 1;

  Future<void> _ouvrirSocket() async {
    final jeton = _jeton;
    final codeTable = _codeTable;
    if (jeton == null || codeTable == null) return;
    final uri = Uri.parse(_config.urlWebSocket);
    final canal = WebSocketChannel.connect(uri);
    _canal = canal;

    // `ready` n'existe qu'en WebSocket natif : on attend l'ouverture
    // effective avant d'envoyer le `bonjour` (le serveur le réclame sous
    // 5 s, sinon fermeture 4408).
    await canal.ready;

    _abonnement = canal.stream.listen(
      _surMessage,
      onDone: _surFermeture,
      onError: (Object e) {
        _erreurs.add(const ErreurReseau(
          'socket_erreur',
          'Connexion interrompue.',
        ));
      },
    );

    _minuteurPing = Timer.periodic(const Duration(seconds: 25), (_) {
      _envoyer({'type': 'ping'});
    });
    _ouvert = true;
    _tentatives = 0;

    _envoyer({
      'type': 'bonjour',
      'd': {
        'jeton': jeton,
        'table': codeTable,
        'version_proto': _versionProto,
      },
    });
  }

  /// Envoie `pret` (marque le siège prêt en `attente`).
  void marquerPret() => _envoyer({'type': 'pret'});

  /// Pose **la carte du dessus** du siège : le client ne choisit jamais
  /// de carte, c'est le serveur qui sait laquelle c'est.
  void poserCarte() {
    _envoyer({'type': 'poser_carte', 'seq_attendu': _seq});
  }

  /// Déclare un appui sur le tapis pendant une fenêtre de doublon.
  ///
  /// [delaiMs] est le délai mesuré **localement** par le client entre le
  /// rendu de l'animation et l'appui. Aucune horloge murale n'est comparée
  /// entre joueurs (`docs/PROTOCOLE.md` §9).
  void taper(int delaiMs) {
    _envoyer({
      'type': 'tape',
      'seq_attendu': _seq,
      'd': {'delai_ms': delaiMs},
    });
  }

  /// Force un nouvel instantané (après un trou de `seq`).
  void resynchroniser() => _envoyer({'type': 'resynchroniser'});

  /// Libère le siège.
  void quitter() => _envoyer({'type': 'quitter'});

  /// Ferme proprement la socket.
  Future<void> fermer() async {
    _reconnexionAutorisee = false;
    _minuteurReconnexion?.cancel();
    _minuteurReconnexion = null;
    _minuteurPing?.cancel();
    _minuteurPing = null;
    _ouvert = false;
    try {
      quitter();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (_) {
      // Le socket est déjà mort : rien à signaler.
    }
    await _abonnement?.cancel();
    _abonnement = null;
    await _canal?.sink.close();
    _canal = null;
  }

  /// Ferme tous les flux (à appeler quand l'écran disparaît).
  Future<void> disposing() async {
    await fermer();
    await _etats.close();
    await _cartes.close();
    await _carteController.close();
    await _doublons.close();
    await _verdicts.close();
    await _plis.close();
    await _fins.close();
    await _erreurs.close();
    await _mouvements.close();
    await _rebours.close();
    await _fermetures.close();
  }

  // ------------------------------------------------------------------ //
  // Test
  // ------------------------------------------------------------------ //

  /// Simule la réception d'un instantané, sans socket.
  ///
  /// Réservé aux tests : permet de vérifier le rejeu d'état et le
  /// multi-abonnement sans dépendre d'un serveur.
  @visibleForTesting
  void simulerEtat(EtatTable etat) {
    _dernierEtat = etat;
    if (etat.monSiege >= 0) _siege = etat.monSiege;
    _etats.add(etat);
  }

  // ------------------------------------------------------------------ //
  // Interne
  // ------------------------------------------------------------------ //
  void _envoyer(Map<String, dynamic> message) {
    final canal = _canal;
    if (canal == null) return;
    try {
      canal.sink.add(jsonEncode(message));
    } catch (_) {
      // Socket morte : la fermeture sera signalée par `onDone`.
    }
  }

  void _surMessage(dynamic brut) {
    Map<String, dynamic> message;
    try {
      message = jsonDecode('$brut') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = '${message['type'] ?? ''}';
    final seq = (message['seq'] as num?)?.toInt() ?? 0;
    if (seq > _seq) _seq = seq;
    final donnees = (message['d'] is Map<String, dynamic>)
        ? message['d'] as Map<String, dynamic>
        : <String, dynamic>{};

    switch (type) {
      case 'bienvenue':
      case 'table_etat':
        var etat = EtatTable.fromJson(donnees);
        if (etat.monSiege >= 0) _siege = etat.monSiege;
        // L'instantané peut porter la carte du dessus (dans l'objet du
        // siège) : on la mémorise, pour que le flux `maCarte` la restitue
        // même si le message privé est arrivé avant l'abonnement.
        if (etat.maCarte != null) {
          _carte = etat.maCarte;
        } else if (_carte != null) {
          // Le canal privé est arrivé avant l'instantané : on complète
          // l'état plutôt que de l'écraser.
          etat = etat.avecMaCarte(_carte!);
        }
        _dernierEtat = etat;
        _etats.add(etat);
      case 'ta_carte_suivante':
        final carte = donnees['carte'];
        if (carte is String) {
          _carte = carte;
          _carteController.add(carte);
        }
      case 'carte_posee':
        _cartes.add(CartePosee.fromJson(donnees));
      case 'doublon_ouvert':
        _doublons.add(DoublonOuvert.fromJson(donnees));
      case 'doublon_resolu':
        _verdicts.add(DoublonResolu.fromJson(donnees));
      case 'pli_gagne':
        _plis.add(PliGagne.fromJson(donnees));
      case 'partie_finie':
        _fins.add(PartieFinie.fromJson(donnees));
      case 'compte_a_rebours':
        _rebours.add((donnees['secondes'] as num?)?.toInt() ?? 0);
      case 'erreur':
        _erreurs.add(ErreurReseau(
          '${donnees['code'] ?? 'erreur'}',
          '${donnees['message'] ?? 'Erreur du serveur.'}',
        ));
      case 'joueur_rejoint':
      case 'joueur_pret':
      case 'joueur_parti':
      case 'bot_prend_la_main':
      case 'partie_lancee':
        // Le type est recopié dans les données : l'écran a besoin de
        // savoir QUEL mouvement il reçoit, pas seulement qu'il y en a eu un.
        _mouvements.add({'type': type, ...donnees});
    }
  }

  void _surFermeture() {
    final code = _canal?.closeCode;
    codeFermeture = code;
    _ouvert = false;
    _minuteurPing?.cancel();
    _minuteurPing = null;
    if (code != null) {
      _fermetures.add(code);
      if (_fermeturesDefinitives.contains(code)) {
        // Table introuvable, complète ou protocole incompatible : inutile
        // d'insister, l'app doit demander une action au joueur.
        _reconnexionAutorisee = false;
      }
    }
    _planifierReconnexion();
  }

  /// Reconnexion avec recul exponentiel (1 s, 2 s, 4 s … 30 s).
  ///
  /// `docs/PROTOCOLE.md` §12 : une coupure ne doit jamais faire perdre la
  /// partie. Le serveur renvoie un instantané complet à la reconnexion.
  void _planifierReconnexion() {
    _minuteurReconnexion?.cancel();
    if (!_reconnexionAutorisee || _jeton == null) return;
    if (_fermeturesDefinitives.contains(codeFermeture)) return;
    _tentatives++;
    final secondes = (1 << (_tentatives - 1).clamp(0, 5)).clamp(1, 30);
    _minuteurReconnexion = Timer(Duration(seconds: secondes), () async {
      try {
        await _ouvrirSocket();
      } catch (_) {
        // L'ouverture a échoué : on retentera à la prochaine tentative.
        _planifierReconnexion();
      }
    });
  }
}
