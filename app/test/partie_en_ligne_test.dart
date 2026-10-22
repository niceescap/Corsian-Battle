import 'dart:async';
import 'dart:math';

import 'package:bataille_corse/net/client_auth.dart';
import 'package:bataille_corse/net/client_jeu.dart';
import 'package:bataille_corse/net/client_jeu_rest.dart';
import 'package:bataille_corse/net/config_reseau.dart';
import 'package:bataille_corse/net/modeles_proto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test d'intégration du client réseau contre un serveur **local**.
///
/// Il ne s'exécute que si un serveur écoute sur 127.0.0.1:8111/8112
/// (`bash serveur/lancer_local.sh`) : c'est une recette, pas un test
/// unitaire. Sans serveur, le test est ignoré — jamais en échec.
const String _hote = String.fromEnvironment('HOTE_TEST', defaultValue: '127.0.0.1');

void main() {
  test('une partie complète se joue en WebSocket', () async {
    final rest = ClientJeuRest(
      config: ConfigurationReseau.developpementHote(_hote),
    );

    // Le serveur est-il là ?
    try {
      await rest.config().timeout(const Duration(seconds: 3));
    } catch (_) {
      markTestSkipped('Serveur local absent : lancer serveur/lancer_local.sh');
      return;
    }

    final compteA = await _compte(rest, 'a');
    final compteB = await _compte(rest, 'b');

    // 1) Un joueur crée la table, l'autre la rejoint.
    final table = await rest.creerTable(jeton: compteA, type: 'duel');
    expect(table.code.length, 6);
    final siege = await rest.rejoindreTable(jeton: compteB, code: table.code);
    expect(siege, 1);

    // 2) Les deux ouvrent leur socket.
    final clientA = ClientJeu(config: ConfigurationReseau.developpementHote(_hote));
    final clientB = ClientJeu(config: ConfigurationReseau.developpementHote(_hote));
    await clientA.ouvrir(jeton: compteA, codeTable: table.code);
    await clientB.ouvrir(jeton: compteB, codeTable: table.code);

    final finA = clientA.fins;
    final finB = clientB.fins;

    // 3) On joue : chaque client pose sa carte quand c'est son tour, et
    //    tape sur le doublon.
    final gagneA = _jouer(clientA, finA);
    final gagneB = _jouer(clientB, finB);

    final resultats = await Future.wait([gagneA, gagneB]).timeout(
      const Duration(minutes: 3),
    );

    // 4) La partie se termine, et les deux clients sont d'accord.
    final bilan = resultats.first;
    expect(bilan, isNotNull);
    expect(bilan!.raison, isNotEmpty);
    expect(bilan.stats, isNotEmpty);

    // 5) Aucun secret n'a fuité : chaque client ne connaît que SA carte.
    expect(bilan.stats.length, 2);

    await clientA.disposing();
    await clientB.disposing();
    rest.close();
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// Crée un compte invité (idempotent par pseudo + UUID).
Future<String> _compte(ClientJeuRest rest, String suffixe) async {
  // L'`uuid_appareil` est FIXE : `POST /api/auth/invite` est idempotent, donc
  // le compte n'est créé qu'une fois. Sans cela, le test buterait sur la
  // limite de création de comptes (5/h/IP) dès la deuxième exécution.
  final auth = ClientAuth(config: ConfigurationReseau.developpementHote(_hote));
  final session = await auth.creerCompteInvite(
    uuidAppareil: 'test-dart-$suffixe',
    pseudo: 'Dart${suffixe.toUpperCase()}',
    plateforme: 'test',
  );
  auth.close();
  return session.jetonAcces;
}

/// Boucle de jeu : pose la carte quand c'est le tour, tape sur le doublon.
Future<PartieFinie?> _jouer(ClientJeu client, Stream<PartieFinie> fin) async {
  final alea = Random();
  int monSiege = -1;
  int dernierSeq = -1;

  final termine = Completer<PartieFinie?>();
  final souscriptions = <StreamSubscription<dynamic>>[];

  var pretEnvoye = false;
  souscriptions.add(client.etats.listen((EtatTable etat) {
    if (etat.monSiege >= 0) monSiege = etat.monSiege;
    // On se déclare prêt une seule fois, comme l'app.
    if (etat.etat == 'attente' && !pretEnvoye) {
      pretEnvoye = true;
      client.marquerPret();
      return;
    }
    if (etat.suivant == monSiege && etat.nbCoups > dernierSeq) {
      dernierSeq = etat.nbCoups;
      // Petit délai : on n'envoie pas plus de 20 messages / 2 s.
      Future<void>.delayed(Duration(milliseconds: 120 + alea.nextInt(200)))
          .then((_) => client.poserCarte());
    }
  }));

  souscriptions.add(client.cartes.listen((CartePosee posee) {
    if (posee.suivant == monSiege) {
      dernierSeq++;
      Future<void>.delayed(Duration(milliseconds: 120 + alea.nextInt(200)))
          .then((_) => client.poserCarte());
    }
  }));

  souscriptions.add(client.doublons.listen((DoublonOuvert fenetre) async {
    final delai = 150 + alea.nextInt(300);
    await Future<void>.delayed(Duration(milliseconds: delai));
    client.taper(delai);
  }));

  souscriptions.add(fin.listen((PartieFinie f) {
    if (!termine.isCompleted) termine.complete(f);
  }));

  try {
    return await termine.future;
  } finally {
    for (final s in souscriptions) {
      s.cancel();
    }
  }
}
