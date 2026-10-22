import 'package:bataille_corse/net/client_jeu.dart';
import 'package:bataille_corse/net/modeles_proto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('le flux des états accepte plusieurs abonnements successifs', () {
    final client = ClientJeu();

    // La salle d'attente s'abonne…
    final premier = <EtatTable>[];
    final souscription1 = client.etats.listen(premier.add);

    // …puis l'écran de jeu s'abonne au MÊME client. Avec un flux à
    // abonnement unique (`async*`), ce second `listen` lève
    // « Stream has already been listened to » et l'app plante au passage
    // de la salle au tapis.
    final second = <EtatTable>[];
    final souscription2 = client.etats.listen(second.add);

    expect(premier, isEmpty);
    expect(second, isEmpty);

    souscription1.cancel();
    souscription2.cancel();
  });

  test('un état déjà reçu est rejoué au nouvel abonné', () async {
    final client = ClientJeu();

    // L'état courant est simulé par un appel direct au client : c'est le
    // `bienvenue` qui arrive avant que l'écran ne s'abonne.
    client.simulerEtat(_etat(siege: 2));

    final recus = <EtatTable>[];
    final abonnement = client.etats.listen(recus.add);
    await Future<void>.delayed(Duration.zero);

    expect(recus, hasLength(1));
    expect(recus.first.monSiege, 2);

    await abonnement.cancel();
  });
}

/// Construit un instantané minimal.
EtatTable _etat({required int siege}) => EtatTable(
      etat: 'attente',
      type: 'duel',
      sieges: const [],
      monSiege: siege,
      pli: const [],
      resteNeutre: 0,
      suivant: null,
      defi: null,
      nbCoups: 0,
    );
