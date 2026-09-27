import 'dart:math';

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Emplacements publicitaires AdMob — PRÉ-RÉSERVATION DE LAYOUT.
//
// Pourquoi pas le SDK tout de suite ?
// -----------------------------------
// Le pipeline CI régénère le scaffold Android à chaque build
// (`flutter create --platforms=android`), et le dossier `android/` n'est pas
// versionné. Or `google_mobile_ads` exige l'AdMob Application ID dans
// `AndroidManifest.xml` : sans lui, `MobileAds.initialize()` fait planter
// l'app AU LANCEMENT. Ajouter le plugin maintenant casserait donc l'APK de
// test tant que le manifest n'est pas maîtrisé (commit du dossier android/
// ou patch dans le workflow).
//
// Ce fichier réserve donc l'ESPACE aux dimensions standard AdMob, sans
// dépendance. Le branchement réel est un remplacement local : substituer le
// conteneur ci-dessous par un `BannerAdWidget` / `AnchoredAdaptiveBannerAd`
// de même format. Les tailles et ratios sont déjà les bons.
// ---------------------------------------------------------------------------

/// Formats standard AdMob, en dp (density-independent pixels).
enum FormatPub {
  /// 320 x 50 — bas d'écran classique.
  banniere,

  /// 320 x 100 — rectangle large, idéal au-dessus du tapis.
  grandBanniere,

  /// 300 x 250 — « Medium Rectangle » (MREC), le rectangle de référence.
  rectangleMoyen,

  /// 728 x 90 — tablette / paysage.
  leaderboard,
}

extension _FormatPubTaille on FormatPub {
  Size get tailleStandard => switch (this) {
        FormatPub.banniere => const Size(320, 50),
        FormatPub.grandBanniere => const Size(320, 100),
        FormatPub.rectangleMoyen => const Size(300, 250),
        FormatPub.leaderboard => const Size(728, 90),
      };
}

/// Conteneur qui réserve proprement l'espace d'une publicité AdMob.
///
/// S'adapte à la largeur disponible en conservant le ratio du [format] :
/// - [FormatPub.grandBanniere] et [FormatPub.banniere] s'étirent sur toute la
///   largeur (comportement « responsive/adaptive banner ») ;
/// - [FormatPub.rectangleMoyen] reste centré à sa largeur standard.
///
/// [afficherCadre] matérialise l'emplacement pendant les builds de test
/// (liseré discret + pictogramme). À passer à `false` en production, ou à
/// remplacer par le vrai widget publicitaire une fois le SDK branché.
class EmplacementPub extends StatelessWidget {
  final FormatPub format;

  /// Largeur maximale disponible (généralement la largeur d'écran moins les
  /// marges). Fournie par le parent via [LayoutBuilder] ou contrainte.
  final double largeurDisponible;

  final bool afficherCadre;

  const EmplacementPub({
    super.key,
    this.format = FormatPub.grandBanniere,
    this.largeurDisponible = double.infinity,
    this.afficherCadre = true,
  });

  /// Hauteur effectivement réservée, pour que le parent puisse budgéter son
  /// layout (ex. soustraire cette hauteur avant de dimensionner le tapis).
  static double hauteurPour(FormatPub format, double largeurDisponible) {
    final standard = format.tailleStandard;
    final largeur = _largeur(format, largeurDisponible, standard);
    return largeur * (standard.height / standard.width);
  }

  static double _largeur(
    FormatPub format,
    double largeurDisponible,
    Size standard,
  ) {
    final borne = largeurDisponible.isFinite
        ? largeurDisponible
        : standard.width;
    if (format == FormatPub.rectangleMoyen) {
      return min(standard.width, borne);
    }
    return borne;
  }

  @override
  Widget build(BuildContext context) {
    final standard = format.tailleStandard;
    final largeur = _largeur(format, largeurDisponible, standard);
    final hauteur = largeur * (standard.height / standard.width);

    if (!afficherCadre) {
      // Emplacement réservé mais invisible : le jour où le SDK est branché,
      // c'est ici que la bannière réelle s'insère, à taille identique.
      return SizedBox(width: largeur, height: hauteur);
    }

    return SizedBox(
      width: largeur,
      height: hauteur,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.28),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.14)),
        ),
        child: Center(
          child: Icon(
            Icons.campaign_outlined,
            size: min(hauteur * 0.34, 26),
            color: Colors.white.withOpacity(0.30),
          ),
        ),
      ),
    );
  }
}
