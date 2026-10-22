import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config_reseau.dart';
import 'erreur_reseau.dart';

/// Une table créée ou rejointe.
class TableInfo {
  /// Code à 6 caractères, sans caractères ambigus (ni `0/O` ni `1/I`).
  final String code;

  /// `duel` ou `table_quatre`.
  final String type;

  /// Siège attribué au joueur.
  final int siege;

  /// État : `attente`, `en_jeu`…
  final String etat;

  /// Lien de partage (page web qui affiche le code en grand).
  final String urlPartage;

  const TableInfo({
    required this.code,
    required this.type,
    required this.siege,
    required this.etat,
    required this.urlPartage,
  });

  factory TableInfo.fromJson(Map<String, dynamic> json) => TableInfo(
        code: '${json['code'] ?? ''}',
        type: '${json['type'] ?? 'duel'}',
        siege: (json['siege'] as num?)?.toInt() ?? 0,
        etat: '${json['etat'] ?? 'attente'}',
        urlPartage: '${json['url_partage'] ?? ''}',
      );
}

/// Réglages du serveur, lus au démarrage et mis en cache.
///
/// L'app ne code **en dur** aucun de ces réglages : les ajuster (fenêtre
/// de tape, délai de tour) se fait côté serveur, sans republier l'app
/// (`docs/ENDPOINTS.md` §4.2).
class ConfigJeu {
  final int versionProto;
  final int fenetreTapeMs;
  final int plancherTapeMs;
  final int delaiTourMs;
  final int graceDeconnexionS;
  final int compteAReboursS;
  final List<int> taillesTable;

  const ConfigJeu({
    this.versionProto = 1,
    this.fenetreTapeMs = 900,
    this.plancherTapeMs = 120,
    this.delaiTourMs = 12000,
    this.graceDeconnexionS = 30,
    this.compteAReboursS = 3,
    this.taillesTable = const [2, 4],
  });

  factory ConfigJeu.fromJson(Map<String, dynamic> json) => ConfigJeu(
        versionProto: (json['version_proto'] as num?)?.toInt() ?? 1,
        fenetreTapeMs: (json['fenetre_tape_ms'] as num?)?.toInt() ?? 900,
        plancherTapeMs: (json['plancher_tape_ms'] as num?)?.toInt() ?? 120,
        delaiTourMs: (json['delai_tour_ms'] as num?)?.toInt() ?? 12000,
        graceDeconnexionS: (json['grace_deconnexion_s'] as num?)?.toInt() ?? 30,
        compteAReboursS:
            (json['compte_a_rebours_s'] as num?)?.toInt() ?? 3,
        taillesTable: (json['tailles_table'] is List)
            ? (json['tailles_table'] as List)
                .map((e) => (e as num).toInt())
                .toList()
            : const [2, 4],
      );
}

/// Client REST de `corsian-jeu`.
///
/// Le REST ne sert qu'à créer une table, la rejoindre, lire les réglages et
/// les statistiques. **Jouer** passe uniquement par le WebSocket : un
/// `POST /poser_carte` serait rejouable et impossible à synchroniser avec la
/// fenêtre de tape (`docs/ENDPOINTS.md` §7).
class ClientJeuRest {
  final ConfigurationReseau _config;
  final http.Client _http;

  ClientJeuRest({ConfigurationReseau? config, http.Client? httpClient})
      : _config = config ?? ConfigurationReseau.depuisDefines(),
        _http = httpClient ?? http.Client();

  /// Réglages publics du serveur.
  Future<ConfigJeu> config() async {
    final json = await _envoyer(_config.urlJeu('/config'), null);
    return ConfigJeu.fromJson(json);
  }

  /// Crée une table et réserve le siège du créateur.
  Future<TableInfo> creerTable({required String jeton, String type = 'duel'}) async {
    final json = await _envoyer(
      _config.urlJeu('/tables'),
      jsonEncode({'type': type}),
      jeton: jeton,
      methode: 'POST',
    );
    return TableInfo.fromJson(json);
  }

  /// Réserve un siège dans une table existante.
  ///
  /// Le REST ne fait que réserver : le jeu démarre sur le WebSocket. Un
  /// siège réservé non connecté sous 20 s est libéré par le serveur.
  Future<int> rejoindreTable({
    required String jeton,
    required String code,
  }) async {
    final json = await _envoyer(
      _config.urlJeu('/tables/$code/rejoindre'),
      null,
      jeton: jeton,
      methode: 'POST',
    );
    return (json['siege'] as num?)?.toInt() ?? 0;
  }

  /// Description publique d'une table.
  Future<Map<String, dynamic>> voirTable({
    required String jeton,
    required String code,
  }) async {
    return _envoyer(_config.urlJeu('/tables/$code'), null, jeton: jeton);
  }

  /// Statistiques du joueur connecté.
  Future<Map<String, dynamic>> mesStats({required String jeton}) async {
    return _envoyer(_config.urlJeu('/stats/moi'), null, jeton: jeton);
  }

  // ------------------------------------------------------------------ //
  // Interne
  // ------------------------------------------------------------------ //
  Future<Map<String, dynamic>> _envoyer(
    String url,
    String? corps, {
    String? jeton,
    String methode = 'GET',
  }) async {
    final entetes = <String, String>{
      'Accept': 'application/json',
      if (corps != null) 'Content-Type': 'application/json; charset=utf-8',
      if (jeton != null) 'Authorization': 'Bearer $jeton',
    };
    late http.Response reponse;
    try {
      final uri = Uri.parse(url);
      switch (methode) {
        case 'POST':
          reponse = await _http.post(uri, headers: entetes, body: corps);
        case 'DELETE':
          reponse = await _http.delete(uri, headers: entetes, body: corps);
        default:
          reponse = await _http.get(uri, headers: entetes);
      }
    } catch (_) {
      throw const ErreurReseau(
        'reseau_injoignable',
        'Connexion au serveur impossible. Vérifie ta connexion.',
      );
    }

    Map<String, dynamic> json = const {};
    if (reponse.body.isNotEmpty) {
      try {
        json = jsonDecode(reponse.body) as Map<String, dynamic>;
      } catch (_) {
        json = const {};
      }
    }
    if (reponse.statusCode >= 400) {
      final erreur = json['erreur'];
      if (erreur is Map<String, dynamic>) {
        throw ErreurReseau(
          '${erreur['code'] ?? 'erreur'}',
          '${erreur['message'] ?? 'Erreur du serveur.'}',
          statut: reponse.statusCode,
        );
      }
      throw ErreurReseau(
        'http_${reponse.statusCode}',
        'Erreur du serveur (${reponse.statusCode}).',
        statut: reponse.statusCode,
      );
    }
    return json;
  }

  void close() => _http.close();
}
