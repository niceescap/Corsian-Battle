/// Configuration réseau de l'application.
///
/// Deux services derrière nginx : `corsian-auth` (8111) et `corsian-jeu`
/// (8112). En **production**, nginx les expose tous les deux sous le même
/// préfixe public (`/corsian-battle`), et toutes les URL de l'app sont
/// **relatives** : c'est ce qui évite tout blocage *mixed content* et rend un
/// changement de domaine une simple variable d'environnement côté serveur,
/// jamais une republication de l'app (`docs/ARCHITECTURE.md` §8.2).
///
/// En **développement**, on parle directement aux deux backends, sur deux
/// ports distincts et sans préfixe. L'hôte est configurable à la
/// compilation : un émulateur Android voit la machine hôte sur `10.0.2.2`,
/// un téléphone physique sur l'IP du LAN.
library;

/// Origines et préfixe public des API.
class ConfigurationReseau {
  /// Préfixe public appliqué par nginx devant les API et le WebSocket.
  /// Vide en développement : on joint le backend directement.
  final String prefixePublic;

  /// Origine du service d'authentification. Vide = origine de la page.
  final String origineAuth;

  /// Origine du service de jeu. Vide = origine de la page.
  final String origineJeu;

  const ConfigurationReseau({
    this.prefixePublic = '/corsian-battle',
    this.origineAuth = '',
    this.origineJeu = '',
  });

  /// Configuration publiée.
  ///
  /// **L'app native n'a pas d'origine implicite** : une URL relative
  /// (`/corsian-battle/api/auth/invite`) n'a aucun sens pour une application
  /// Android, qui n'a pas de page web à qui demander « d'où vient la
  /// requête ». L'origine est donc **explicite** ici.
  ///
  /// Les URL *relatives* restent le bon choix pour la **web app** (la page
  /// servie par nginx) : c'est ce qui permet de changer de domaine sans
  /// republier. L'app, elle, a besoin de l'adresse absolue — et le
  /// préfixe public reste le seul élément à changer côté serveur
  /// (`docs/ARCHITECTURE.md` §8.2).
  static const ConfigurationReseau production = ConfigurationReseau(
    prefixePublic: '/corsian-battle',
    origineAuth: 'https://soft.opik.net',
    origineJeu: 'https://soft.opik.net',
  );

  /// Configuration de développement : les deux backends en local.
  static const ConfigurationReseau developpement = ConfigurationReseau(
    prefixePublic: '',
    origineAuth: 'http://127.0.0.1:8111',
    origineJeu: 'http://127.0.0.1:8112',
  );

  /// Configuration de développement pointant un hôte précis.
  ///
  /// [hote] peut être `127.0.0.1`, `10.0.2.2` (émulateur Android) ou
  /// l'IP d'un téléphone sur le réseau local.
  factory ConfigurationReseau.developpementHote(String hote) => ConfigurationReseau(
        prefixePublic: '',
        origineAuth: 'http://$hote:8111',
        origineJeu: 'http://$hote:8112',
      );

  /// Configuration de compilation, surchargeable par `--dart-define` :
  ///
  /// ```
  /// flutter build apk --dart-define=HOST_IP=192.168.1.20
  /// ```
  ///
  /// `HOST_IP` sert aux deux services ; `PREFIXE_PUBLIC` permet de pointer
  /// un backendQuaternion exposé derrière un préfixe (recette nginx).
  static ConfigurationReseau depuisDefines() {
    const hote = String.fromEnvironment('HOST_IP', defaultValue: '');
    const prefixe = String.fromEnvironment('PREFIXE_PUBLIC', defaultValue: '');
    if (hote.isEmpty) {
      // Pas de surcharge : on garde la configuration de production ou de
      // développement selon le mode compilé.
      return const bool.fromEnvironment('MODE_DEV', defaultValue: false)
          ? developpement
          : production;
    }
    return const ConfigurationReseau(
      prefixePublic: prefixe,
      origineAuth: 'http://$hote:8111',
      origineJeu: 'http://$hote:8112',
    );
  }

  /// URL d'un endpoint d'authentification.
  String urlAuth(String chemin) => '$origineAuth$prefixePublic/api/auth$chemin';

  /// URL d'un endpoint de jeu.
  String urlJeu(String chemin) => '$origineJeu$prefixePublic/api/jeu$chemin';

  /// URL du WebSocket de jeu.
  ///
  /// En production, même origine que la page, en `wss://` : le préfixe
  /// public précède le chemin `/ws` que le backend déclare
  /// (`@app.websocket("/ws")`).
  String get urlWebSocket {
    if (origineJeu.isEmpty) {
      return '$prefixePublic/ws';
    }
    return '${_versWs(origineJeu)}$prefixePublic/ws';
  }

  /// Origine **publique** de l'invitation.
  ///
  /// Le lien partagé est une **page web**, servie par nginx, qui affiche le
  /// code en grand : il ne s'agit jamais d'un lien vers l'API. En
  /// développement, cette origine reste donc celle du domaine public — pas
  /// `127.0.0.1`, que le destinataire ne pourrait pas joindre.
  static const String origineInvitation = 'https://soft.opik.net';

  /// Préfixe public de l'invitation.
  String get prefixeInvitation => prefixePublic.isEmpty
      ? '/corsian-battle'
      : prefixePublic;

  /// URL de partage d'une table.
  ///
  /// Invitation **sans deep link** : la page web affiche le code en très
  /// grand et la consigne d'ouvrir l'app. Cela fonctionne dès maintenant,
  /// sans App Links natifs (`docs/PROTOCOLE.md` §4).
  String urlPartage(String code) =>
      '$origineInvitation$prefixeInvitation/#table=$code';

  /// `http://` → `ws://`, `https://` → `wss://`.
  static String _versWs(String origine) {
    if (origine.startsWith('https://')) return 'wss://${origine.substring(8)}';
    if (origine.startsWith('http://')) return 'ws://${origine.substring(7)}';
    return origine;
  }
}
