import 'dart:async';
import 'dart:convert';

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

  /// Messages « à toi de jouer » : [etat] et [table_etat].
  final StreamController<EtatTable> _etats =
      StreamController<EtatTable>.broadcast();

  /// Cartes posées.
  final StreamController<CartePosee> _cartes =
      StreamController<CartePosee>.broadcast();

  /// La carte du dessus de ce client (message privé).
  final StreamController<String> _maCarte =
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

  /// Dernier instantané reçu, rejoué à l'abonnement.
  EtatTable? get dernierEtat => _dernierEtat;

  /// Siège de ce client, `-1` tant que le serveur ne l'a pas donné.
  int get siege => _siege;

  ClientJeu({ConfigurationReseau? config})
      : _config = config ?? ConfigurationReseau.production;

  /// Flux des instantanés.
  ///
  /// Si un instantané est déjà arrivé, il est rejoué immédiatement à
  /// l'abonnement : l'écran ne rate jamais l'état initial (le `bienvenue`
  /// et le premier `table_etat` arrivent souvent AVANT que l'UI ne s'abonne).
  Stream<EtatTable> get etats async* {
    final deja = _dernierEtat;
    if (deja != null) yield deja;
    yield* _etats.stream;
  }
  Stream<CartePosee> get cartes => _cartes.stream;
  Stream<String> get maCarte => _maCarte.stream;
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

    _envoyer({
      'type': 'bonjour',
      'd': {
        'jeton': jeton,
        'table': codeTable,
        'version_proto': versionProto,
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
    _minuteurPing?.cancel();
    _minuteurPing = null;
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
    await _maCarte.close();
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
        final etat = EtatTable.fromJson(donnees);
        if (etat.monSiege >= 0) _siege = etat.monSiege;
        _dernierEtat = etat;
        _etats.add(etat);
      case 'ta_carte_suivante':
        final carte = donnees['carte'];
        if (carte is String) _maCarte.add(carte);
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
        _mouvements.add(donnees);
    }
  }

  void _surFermeture() {
    codeFermeture = _canal?.closeCode;
    _minuteurPing?.cancel();
    _minuteurPing = null;
    if (codeFermeture != null) _fermetures.add(codeFermeture!);
  }
}
