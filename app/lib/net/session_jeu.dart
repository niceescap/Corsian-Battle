import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'client_auth.dart';
import 'config_reseau.dart';
import 'erreur_reseau.dart';

/// Gestion de la session : création du compte invité, persistance, renouvellement.
///
/// Le compte invité est **idempotent par identifiant d'appareil** : un même
/// appareil retrouve toujours le même compte, sans aucune saisie
/// (`docs/ENDPOINTS.md` §3.2). C'est ce qui rend la reconnexion transparente
/// après un redémarrage de l'app.
class SessionJeu {
  final ClientAuth _auth;
  final ConfigurationReseau _config;

  Session? _session;
  SharedPreferences? _prefs;

  SessionJeu({ClientAuth? auth, ConfigurationReseau? config})
      : _auth = auth ?? ClientAuth(),
        _config = config ?? ConfigurationReseau.depuisDefines();

  /// Session courante, si le joueur est identifié.
  Session? get session => _session;

  /// Le joueur a-t-il un jeton valide ?
  bool get connecte => _session != null;

  /// Identifiant technique de l'appareil, stable entre deux lancements.
  ///
  /// Généré une fois puis conservé : il ne provient d'aucun système
  /// d'exploitation et ne permet pas d'identifier la personne
  /// (`docs/CONFORMITE.md` §2).
  String _uuidAppareil(SharedPreferences prefs) {
    const cle = 'corsian.uuid_appareil';
    final existant = prefs.getString(cle);
    if (existant != null && existant.isNotEmpty) return existant;
    final genere = _genererUuid();
    prefs.setString(cle, genere);
    return genere;
  }

  /// UUID v4 en hexadécimal (32 caractères), comme attendu par le serveur.
  String _genererUuid() {
    final alea = Random.secure();
    final octets = List<int>.generate(16, (_) => alea.nextInt(256));
    octets[6] = (octets[6] & 0x0f) | 0x40;   // version 4
    octets[8] = (octets[8] & 0x3f) | 0x80;   // variante
    final hex = octets.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return hex;
  }

  /// Récupère la session persistée, ou en crée une.
  ///
  /// [pseudo] n'est utilisé qu'à la **première** création : ensuite, le
  /// compte existe et le pseudo fourni par le serveur fait foi.
  Future<Session> ouvrirSession({required String pseudo}) async {
    _prefs ??= await SharedPreferences.getInstance();
    final prefs = _prefs!;

    final refresh = prefs.getString('corsian.jeton_refresh');
    if (refresh != null && refresh.isNotEmpty) {
      try {
        final nouvelle = await _auth.rafraichir(refresh);
        await _sauvegarder(nouvelle);
        return _session = nouvelle;
      } on ErreurReseau catch (e) {
        // Jeton de rafraîchissement périmé ou révoqué : on repart d'un
        // compte invité neuf. Le compte reste accessible par son pseudo.
        if (!e.debitAtteint) {
          await prefs.remove('corsian.jeton_refresh');
          await prefs.remove('corsian.jeton_acces');
        } else {
          rethrow;
        }
      }
    }

    final session = await _auth.creerCompteInvite(
      uuidAppareil: _uuidAppareil(prefs),
      pseudo: pseudo,
      versionApp: '0.1.0',
    );
    await _sauvegarder(session);
    return _session = session;
  }

  /// Session déjà persistée, sans créer de compte ni d'appel réseau.
  ///
  /// Sert au démarrage : l'app affiche immédiatement « connecté » si un jeton
  /// existe, et le renouvelle en tâche de fond si besoin.
  Future<Session?> sessionPersistee() async {
    _prefs ??= await SharedPreferences.getInstance();
    final prefs = _prefs!;
    final acces = prefs.getString('corsian.jeton_acces');
    final refresh = prefs.getString('corsian.jeton_refresh');
    if (acces == null || refresh == null) return null;
    final expire = prefs.getInt('corsian.expire_le_ms');
    return _session = Session(
      jetonAcces: acces,
      jetonRefresh: refresh,
      joueurId: prefs.getString('corsian.id') ?? '',
      pseudo: prefs.getString('corsian.pseudo') ?? 'Joueur',
      expireLe: expire == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expire),
    );
  }

  /// Renouvelle le jeton d'accès si besoin (appel silencieux, tolère l'échec).
  Future<Session?> renouvelerSiNecessaire() async {
    final courante = _session;
    if (courante == null) return null;
    final expiration = courante.expireLe;
    if (expiration == null ||
        expiration.difference(DateTime.now()).inSeconds > 60) {
      return courante;
    }
    try {
      final nouvelle = await _auth.rafraichir(courante.jetonRefresh);
      await _sauvegarder(nouvelle);
      return _session = nouvelle;
    } on ErreurReseau {
      return courante;
    }
  }

  Future<void> _sauvegarder(Session session) async {
    _prefs ??= await SharedPreferences.getInstance();
    final prefs = _prefs!;
    await prefs.setString('corsian.jeton_acces', session.jetonAcces);
    await prefs.setString('corsian.jeton_refresh', session.jetonRefresh);
    await prefs.setString('corsian.id', session.joueurId);
    await prefs.setString('corsian.pseudo', session.pseudo);
    final expiration = session.expireLe;
    if (expiration != null) {
      await prefs.setInt(
        'corsian.expire_le_ms',
        expiration.millisecondsSinceEpoch,
      );
    }
  }

  /// Jeton d'accès valide, renouvelé si besoin.
  ///
  /// C'est ce que la socket de jeu consomme **à chaque ouverture** — donc
  /// aussi à chaque reconnexion. Le jeton d'accès expire au bout de 15
  /// minutes : sans ce renouvellement, une reconnexion en cours de partie
  /// échoue en `4401` et le joueur est déconnecté pour de bon.
  Future<String?> jetonValide() async {
    final session = await renouvelerSiNecessaire();
    return session?.jetonAcces;
  }

  /// Change le pseudo du joueur.
  ///
  /// Le pseudo est ce qui distingue les joueurs **sur le tapis** : deux
  /// joueurs de même pseudo sont refusés par le moteur, qui exige des
  /// pseudos uniques au sein d'une table. Le changer est donc nécessaire
  /// dès que deux joueurs ont installé l'app avec le même pseudo par
  /// défaut.
  ///
  /// Renvoie le pseudo **réellement enregistré** : le serveur peut proposer
  /// une variante si le pseudo demandé est déjà pris.
  Future<String> changerPseudo(String nouveau) async {
    final session = _session;
    if (session == null) {
      throw const ErreurReseau(
        'session_absente',
        'Aucune session : reconnecte-toi d\'abord.',
      );
    }
    final reponse = await _auth.changerPseudo(session.jetonAcces, nouveau);
    final joueur = reponse['joueur'];
    final pseudo = joueur is Map<String, dynamic>
        ? '${joueur['pseudo'] ?? session.pseudo}'
        : session.pseudo;

    // Le jeton d'accès porte l'ancien pseudo : on le renouvelle pour que
    // le serveur et l'app affichent la même chose.
    await _sauvegarder(Session(
      jetonAcces: session.jetonAcces,
      jetonRefresh: session.jetonRefresh,
      joueurId: session.joueurId,
      pseudo: pseudo,
      expireLe: session.expireLe,
    ));
    return pseudo;
  }

  /// Supprime le compte côté serveur, puis oublie la session locale.
  ///
  /// L'ordre compte : on supprime d'abord chez le serveur, pour qu'un échec
  /// réseau ne laisse pas l'app dans un état où elle croit avoir supprimé
  /// un compte qui existe encore.
  ///
  /// L'exigence vient de `docs/CONFORMITE.md` §5 : la suppression doit être
  /// possible **depuis l'application** (RGPD, politique Google Play).
  Future<void> supprimerCompte() async {
    final session = _session;
    if (session == null) {
      // Rien à supprimer : on forget quand même la session locale.
      await oublier();
      return;
    }
    await _auth.supprimerCompte(session.jetonAcces);
    await oublier();
  }

  /// Oublie la session locale (déconnexion). Ne supprime PAS le compte.
  Future<void> oublier() async {
    _prefs ??= await SharedPreferences.getInstance();
    final prefs = _prefs!;
    await prefs.remove('corsian.jeton_acces');
    await prefs.remove('corsian.jeton_refresh');
    _session = null;
  }

  /// Configuration réseau effective.
  ConfigurationReseau get config => _config;
}
