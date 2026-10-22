import 'package:bataille_corse/net/config_reseau.dart';
import 'package:flutter_test/flutter_test.dart';

/// L'app Android n'a pas de page web à qui demander « d'où vient la
/// requête » : une URL **relative** y est inexploitable.
///
/// Ces tests verrouillent le fait que la configuration publiée produit des
/// URL **absolues**, joignables depuis un téléphone, et que le lien
/// d'invitation reste une page web publique même en développement.
void main() {
  group('configuration publiée', () {
    test('les URL d\'API sont absolues', () {
      const config = ConfigurationReseau.production;

      expect(config.urlAuth('/invite'), startsWith('https://'));
      expect(config.urlJeu('/tables'), startsWith('https://'));
      expect(config.urlWebSocket, startsWith('wss://'));
    });

    test('les URL d\'API contiennent le préfixe public', () {
      const config = ConfigurationReseau.production;

      expect(config.urlAuth('/invite'), contains('/corsian-battle/api/auth'));
      expect(config.urlJeu('/tables'), contains('/corsian-battle/api/jeu'));
    });
  });

  group('configuration de développement', () {
    test('les URL d\'API visent le backend local', () {
      const config = ConfigurationReseau.developpement;

      expect(config.urlAuth('/invite'), 'http://127.0.0.1:8111/api/auth/invite');
      expect(config.urlJeu('/tables'), 'http://127.0.0.1:8112/api/jeu/tables');
      expect(config.urlWebSocket, 'ws://127.0.0.1:8112/ws');
    });

    test('le lien d\'invitation reste public', () {
      // Un lien vers `127.0.0.1` ne serait joignable par personne d'autre
      // que la machine qui l'a reçu.
      const config = ConfigurationReseau.developpement;

      final url = config.urlPartage('K7M2QP');

      expect(url, startsWith('https://'));
      expect(url, contains('/corsian-battle/'));
      expect(url, endsWith('#table=K7M2QP'));
      expect(url, isNot(contains('127.0.0.1')));
    });
  });

  group('invitation', () {
    test('le lien porte le code de la table', () {
      const config = ConfigurationReseau.production;

      expect(config.urlPartage('ABC123'), endsWith('#table=ABC123'));
    });
  });
}
