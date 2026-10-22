import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config_reseau.dart';
import 'erreur_reseau.dart';

/// Session d'authentification : jeton d'accès + jeton de rafraîchissement.
class Session {
  /// JWT d'accès, envoyé en `Authorization: Bearer …`.
  final String jetonAcces;

  /// Jeton de rafraîchissement (opaque, `rt_…`). Permet de renouveler la
  /// session sans ressaisir quoi que ce soit.
  final String jetonRefresh;

  /// Identifiant du joueur (uuid hex).
  final String joueurId;

  /// Pseudo affiché.
  final String pseudo;

  /// Date d'expiration du jeton d'accès, si le serveur l'a communiquée.
  final DateTime? expireLe;

  const Session({
    required this.jetonAcces,
    required this.jetonRefresh,
    required this.joueurId,
    required this.pseudo,
    this.expireLe,
  });
}

/// Client REST de `corsian-auth`.
///
/// N'envoie **jamais** de jeton dans une query string : il finirait dans les
/// journaux du serveur web (`docs/PROTOCOLE.md` §3).
class ClientAuth {
  final ConfigurationReseau _config;
  final http.Client _http;

  ClientAuth({ConfigurationReseau? config, http.Client? httpClient})
      : _config = config ?? ConfigurationReseau.depuisDefines(),
        _http = httpClient ?? http.Client();

  /// Crée (ou retrouve) un compte invité.
  ///
  /// L'appel est **idempotent** par `uuid_appareil` : un même appareil
  /// redemande toujours le même compte, ce qui rend la reconnexion
  /// transparente après redémarrage de l'app (`docs/ENDPOINTS.md` §3.2).
  Future<Session> creerCompteInvite({
    required String uuidAppareil,
    required String pseudo,
    String plateforme = 'android',
    String versionApp = '0.1.0',
  }) async {
    final corps = jsonEncode({
      'uuid_appareil': uuidAppareil,
      'pseudo': pseudo,
      'plateforme': plateforme,
      'version_app': versionApp,
    });
    final reponse = await _envoyer(
      _config.urlAuth('/invite'),
      corps,
      methode: 'POST',
    );
    return _sessionDepuisReponse(reponse);
  }

  /// Renouvelle la session. L'ancien jeton de rafraîchissement est révoqué
  /// (rotation) ; sa réutilisation révoque toute la chaîne de sessions.
  Future<Session> rafraichir(String jetonRefresh) async {
    final reponse = await _envoyer(
      _config.urlAuth('/rafraichir'),
      jsonEncode({'jeton_refresh': jetonRefresh}),
      methode: 'POST',
    );
    return _sessionDepuisReponse(reponse);
  }

  /// Lecture du profil (utile pour vérifier que le jeton est encore valide).
  Future<Map<String, dynamic>> profil(String jetonAcces) async {
    final reponse = await _envoyer(
      _config.urlAuth('/profil'),
      null,
      jeton: jetonAcces,
    );
    return reponse;
  }

  /// Suppression du compte. Immédiate et irréversible.
  Future<void> supprimerCompte(String jetonAcces) async {
    await _envoyer(
      _config.urlAuth('/compte'),
      null,
      jeton: jetonAcces,
      methode: 'DELETE',
    );
  }

  /// Raccorde une adresse email et un mot de passe au compte invité.
  Future<void> attacherEmail(
    String jetonAcces, {
    required String email,
    required String motDePasse,
  }) async {
    await _envoyer(
      _config.urlAuth('/email'),
      jsonEncode({'email': email, 'mot_de_passe': motDePasse}),
      jeton: jetonAcces,
      methode: 'POST',
    );
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
    } catch (e) {
      throw const ErreurReseau(
        'reseau_injoignable',
        'Connexion au serveur impossible. Vérifie ta connexion.',
      );
    }

    Map<String, dynamic> corps_ = const {};
    if (reponse.body.isNotEmpty) {
      try {
        corps_ = jsonDecode(reponse.body) as Map<String, dynamic>;
      } catch (_) {
        corps_ = const {};
      }
    }

    if (reponse.statusCode >= 400) {
      final erreur = corps_['erreur'];
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
    return corps_;
  }

  Session _sessionDepuisReponse(Map<String, dynamic> reponse) {
    final joueur = (reponse['joueur'] as Map<String, dynamic>?) ?? const {};
    final expires = reponse['expire_dans'];
    return Session(
      jetonAcces: '${reponse['jeton_acces'] ?? ''}',
      jetonRefresh: '${reponse['jeton_refresh'] ?? ''}',
      joueurId: '${joueur['id'] ?? ''}',
      pseudo: '${joueur['pseudo'] ?? 'Joueur'}',
      expireLe: expires is int
          ? DateTime.now().add(Duration(seconds: expires))
          : null,
    );
  }

  void close() => _http.close();
}
