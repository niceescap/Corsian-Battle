import 'package:bataille_corse/screens/fenetre_tap.dart';
import 'package:flutter_test/flutter_test.dart';

/// Garde-fous de la fenêtre de tap d'un doublon.
///
/// Ces tests verrouillent le défaut corrigé par
/// `bilan_correction_tap_invite.md` : un rouge encore visible ne doit jamais
/// rendre un tap inopérant, et un tap après verdict doit rester impossible.
void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

  group('ouverture', () {
    test('la fenêtre est rouge, montée et recevable', () {
      final fenetre = FenetreTap()..ouvrir(t0);

      expect(fenetre.rouge, isTrue);
      expect(fenetre.montee, isTrue);
      expect(fenetre.autorisee, isTrue);
      expect(fenetre.debut, t0);
    });

    test('un tap mesure le délai depuis l\'ouverture', () {
      final fenetre = FenetreTap()..ouvrir(t0);

      expect(fenetre.enregistrerTap(t0.add(const Duration(milliseconds: 250))),
          250);
    });

    test('un second tap est ignoré', () {
      final fenetre = FenetreTap()..ouvrir(t0);
      fenetre.enregistrerTap(t0.add(const Duration(milliseconds: 250)));

      expect(fenetre.autorisee, isFalse);
      expect(fenetre.enregistrerTap(t0.add(const Duration(milliseconds: 300))),
          isNull);
    });
  });

  group('fermeture visuelle anticipée', () {
    test('le tap reste recevable quand le rouge disparaît', () {
      // Cas de la partie réelle : le ramassage ferme la zone rouge avant
      // l'arrivée de `doublon_resolu`. L'invité doit pouvoir taper.
      final fenetre = FenetreTap()
        ..ouvrir(t0)
        ..fermerVisuel();

      expect(fenetre.rouge, isFalse);
      expect(fenetre.montee, isTrue);
      expect(fenetre.autorisee, isTrue);
      expect(fenetre.enregistrerTap(t0.add(const Duration(milliseconds: 400))),
          400);
    });

    test('un tap reste possible pour n\'importe quel siège', () {
      // La fenêtre ne connaît pas le siège : créateur et invité sont égaux.
      final fenetre = FenetreTap()
        ..ouvrir(t0)
        ..fermerVisuel();

      expect(fenetre.enregistrerTap(t0.add(const Duration(milliseconds: 180))),
          180);
    });
  });

  group('verdict', () {
    test('le tap est interdit après résolution', () {
      final fenetre = FenetreTap()
        ..ouvrir(t0)
        ..resoudre();

      expect(fenetre.rouge, isFalse);
      expect(fenetre.montee, isFalse);
      expect(fenetre.autorisee, isFalse);
      expect(fenetre.debut, isNull);
      expect(fenetre.enregistrerTap(t0.add(const Duration(milliseconds: 10))),
          isNull);
    });

    test('une nouvelle fenêtre réarme le tap', () {
      final fenetre = FenetreTap()
        ..ouvrir(t0)
        ..resoudre()
        ..ouvrir(t0.add(const Duration(seconds: 30)));

      expect(fenetre.autorisee, isTrue);
      expect(fenetre.enregistrerTap(t0.add(const Duration(seconds: 30))), 0);
    });
  });

  test('un tap sans début de fenêtre est ignoré', () {
    expect(FenetreTap().enregistrerTap(t0), isNull);
  });

  group('séquence complète', () {
    test('ouverture, tap, verdict, puis nouvelle fenêtre', () {
      final fenetre = FenetreTap();

      fenetre.ouvrir(t0);
      expect(fenetre.enregistrerTap(t0.add(const Duration(milliseconds: 220))),
          220);

      // Verdict reçu avant même le ramassage.
      fenetre.resoudre();
      expect(fenetre.autorisee, isFalse);
      expect(fenetre.montee, isFalse);

      // Nouveau coup : la fenêtre se réarme.
      final t1 = t0.add(const Duration(seconds: 20));
      fenetre.ouvrir(t1);
      expect(fenetre.autorisee, isTrue);
      expect(fenetre.enregistrerTap(t1.add(const Duration(milliseconds: 150))),
          150);
    });
  });
}
