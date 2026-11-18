import 'dart:math' as math;

/// Surface logique disponible pour dessiner la table.
///
/// Les valeurs sont exprimées en pixels logiques et doivent correspondre à la
/// zone réellement mesurée par un `LayoutBuilder`, après l'en-tête, la bannière
/// publicitaire et les éventuels bandeaux d'état.
class TableSurface {
  final double width;
  final double height;

  const TableSurface({required this.width, required this.height});

  const TableSurface.zero() : width = 0, height = 0;

  bool get estValide =>
      width.isFinite &&
      height.isFinite &&
      width > 0 &&
      height > 0;

  @override
  bool operator ==(Object other) =>
      other is TableSurface && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'TableSurface($width, $height)';
}

/// Point exprimé dans le repère local de la surface mesurée.
class TablePoint {
  final double x;
  final double y;

  const TablePoint(this.x, this.y);

  const TablePoint.zero() : x = 0, y = 0;

  double get distance => math.sqrt(x * x + y * y);

  TablePoint plus(TablePoint other) => TablePoint(x + other.x, y + other.y);

  TablePoint translate(double dx, double dy) =>
      TablePoint(x + dx, y + dy);

  TablePoint lerp(TablePoint destination, double progression) {
    final valeur = progression.clamp(0.0, 1.0);
    return TablePoint(
      x + (destination.x - x) * valeur,
      y + (destination.y - y) * valeur,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TablePoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'TablePoint($x, $y)';
}

/// Dimensions logiques d'une carte, d'une zone ou d'un composant.
class TableSize {
  final double width;
  final double height;

  const TableSize({required this.width, required this.height});

  bool get estValide => width > 0 && height > 0;

  TableSize scale(double facteur) =>
      TableSize(width: width * facteur, height: height * facteur);

  @override
  bool operator ==(Object other) =>
      other is TableSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'TableSize($width, $height)';
}

/// Rectangle axis-aligned dans le repère de la surface mesurée.
class TableRect {
  final double left;
  final double top;
  final double width;
  final double height;

  const TableRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  double get right => left + width;

  double get bottom => top + height;

  TablePoint get center =>
      TablePoint(left + width / 2, top + height / 2);

  bool containsPoint(TablePoint point) =>
      point.x >= left &&
      point.x <= right &&
      point.y >= top &&
      point.y <= bottom;

  bool overlaps(TableRect other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;

  static TableRect fromCenter({
    required TablePoint center,
    required TableSize size,
  }) {
    return TableRect(
      left: center.x - size.width / 2,
      top: center.y - size.height / 2,
      width: size.width,
      height: size.height,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TableRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() =>
      'TableRect(left: $left, top: $top, width: $width, height: $height)';
}

/// Zone orientée, utile pour les dépôts qui suivent l'angle d'un siège.
class TableZone {
  final TablePoint center;
  final TableSize size;
  final double rotationDegres;

  const TableZone({
    required this.center,
    required this.size,
    this.rotationDegres = 0,
  });

  double get rotationRadians => rotationDegres * math.pi / 180;

  /// Rectangle englobant, pratique pour un premier test de collision.
  TableRect get boundingBox {
    final cosinus = math.cos(rotationRadians).abs();
    final sinus = math.sin(rotationRadians).abs();
    final largeur = size.width * cosinus + size.height * sinus;
    final hauteur = size.width * sinus + size.height * cosinus;
    return TableRect.fromCenter(
      center: center,
      size: TableSize(width: largeur, height: hauteur),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TableZone &&
      other.center == center &&
      other.size == size &&
      other.rotationDegres == rotationDegres;

  @override
  int get hashCode => Object.hash(center, size, rotationDegres);

  @override
  String toString() =>
      'TableZone(center: $center, size: $size, rotation: $rotationDegres)';
}

/// Géométrie d'un siège occupé.
class TableSeatGeometry {
  /// Identifiant logique du siège, indépendant du joueur qui l'occupe.
  final int siege;

  /// Rang du siège dans la liste des sièges occupés.
  final int rang;

  /// Angle du siège autour du centre, en degrés.
  ///
  /// Convention : 0° = droite, 90° = bas, 180° = gauche, 270° = haut.
  final double angleDegres;

  /// Ancrage du tas ou du panneau du joueur.
  final TablePoint positionTas;

  /// Ancrage du dépôt de carte côté table.
  final TablePoint positionDepot;

  /// Zone de dépôt orientée selon l'angle du siège.
  final TableZone zoneDepot;

  /// Rotation à appliquer à une carte pour qu'elle fasse face au centre.
  final double rotationCarteDegres;

  /// Échelle relative des composants d'interface du siège.
  final double echelle;

  const TableSeatGeometry({
    required this.siege,
    required this.rang,
    required this.angleDegres,
    required this.positionTas,
    required this.positionDepot,
    required this.zoneDepot,
    required this.rotationCarteDegres,
    required this.echelle,
  });

  double get angleRadians => angleDegres * math.pi / 180;

  double get rotationCarteRadians =>
      rotationCarteDegres * math.pi / 180;

  @override
  bool operator ==(Object other) =>
      other is TableSeatGeometry &&
      other.siege == siege &&
      other.rang == rang &&
      other.angleDegres == angleDegres &&
      other.positionTas == positionTas &&
      other.positionDepot == positionDepot &&
      other.zoneDepot == zoneDepot &&
      other.rotationCarteDegres == rotationCarteDegres &&
      other.echelle == echelle;

  @override
  int get hashCode => Object.hash(
        siege,
        rang,
        angleDegres,
        positionTas,
        positionDepot,
        zoneDepot,
        rotationCarteDegres,
        echelle,
      );

  @override
  String toString() =>
      'TableSeatGeometry(siege: $siege, angle: $angleDegres°)';
}

/// Géométrie adaptative d'une table de Bataille Corse.
///
/// Le module ne connaît ni joueur, ni réseau, ni widget Flutter. Il produit
/// uniquement des ancres, des zones et des angles calculés à partir d'une
/// surface mesurée. L'écran reste responsable du rendu et des animations.
///
/// Positions impératives (repère écran : 0° = droite, 90° = bas) :
/// - 2 joueurs : local à 90°, adversaire à 270° (12h) ;
/// - 3 joueurs : local à 90°, adversaires à 240° (11h) et 300° (1h) ;
/// - 4 joueurs : local à 90°, adversaires à 210° (10h), 270° (12h) et 330° (2h).
///
/// Exemple :
/// ```dart
/// final geometrie = AdaptiveTableGeometry.pourNombreJoueurs(
///   surface: const TableSurface(width: 390, height: 620),
///   nombreJoueurs: 3,
///   siegeLocal: 0,
/// );
/// ```
class AdaptiveTableGeometry {
  static const Set<int> nombresJoueursSupportes = {2, 3, 4};

  /// Angle du siège local, toujours en bas de l'écran (6h).
  static const double angleSiegeLocal = 90;

  /// Angles impératifs des adversaires, concentrés dans le demi-espace supérieur.
  static const List<double> anglesAdversaires2Joueurs = [270];
  static const List<double> anglesAdversaires3Joueurs = [240, 300];
  static const List<double> anglesAdversaires4Joueurs = [210, 270, 330];

  static const double largeurCarteReference = 80;
  static const double hauteurCarteReference = 112.5;

  static const double _margeHorizontaleTapis = 0.03;

  final TableSurface surface;
  final List<int> siegesOccupes;
  final int siegeLocal;
  final double echelleCarte;
  final double echelleInterface;

  AdaptiveTableGeometry({
    required this.surface,
    required Iterable<int> siegesOccupes,
    this.siegeLocal = 0,
    this.echelleCarte = 1,
    this.echelleInterface = 1,
  }) : siegesOccupes = List<int>.unmodifiable(siegesOccupes) {
    if (!surface.estValide) {
      throw ArgumentError.value(
        surface,
        'surface',
        'La surface mesurée doit être finie et strictement positive.',
      );
    }
    if (!nombresJoueursSupportes.contains(this.siegesOccupes.length)) {
      throw ArgumentError.value(
        this.siegesOccupes.length,
        'siegesOccupes.length',
        'Seuls 2, 3 et 4 joueurs sont pris en charge pour le moment.',
      );
    }
    if (this.siegesOccupes.length !=
        this.siegesOccupes.toSet().length) {
      throw ArgumentError.value(
        this.siegesOccupes,
        'siegesOccupes',
        'Les sièges occupés ne doivent pas contenir de doublon.',
      );
    }
    if (this.siegesOccupes.any((siege) => siege < 0)) {
      throw ArgumentError.value(
        this.siegesOccupes,
        'siegesOccupes',
        'Les identifiants de sièges doivent être positifs ou nuls.',
      );
    }
    if (!this.siegesOccupes.contains(siegeLocal)) {
      throw ArgumentError.value(
        siegeLocal,
        'siegeLocal',
        'Le siège local doit faire partie des sièges occupés.',
      );
    }
    if (echelleCarte <= 0 || echelleInterface <= 0) {
      throw ArgumentError(
        'Les échelles de carte et d\'interface doivent être strictement positives.',
      );
    }
  }

  factory AdaptiveTableGeometry.pourNombreJoueurs({
    required TableSurface surface,
    required int nombreJoueurs,
    int siegeLocal = 0,
    double echelleCarte = 1,
    double echelleInterface = 1,
  }) {
    return AdaptiveTableGeometry(
      surface: surface,
      siegesOccupes: List<int>.generate(nombreJoueurs, (index) => index),
      siegeLocal: siegeLocal,
      echelleCarte: echelleCarte,
      echelleInterface: echelleInterface,
    );
  }

  int get nombreJoueurs => siegesOccupes.length;

  late final TableRect tapis = _calculerTapis();

  late final TablePoint centre = tapis.center;

  late final TableSize tailleCarte = _calculerTailleCarte();

  late final TableSize tailleZoneCentrale = TableSize(
    width: tailleCarte.width * 1.6,
    height: tailleCarte.height * 0.85,
  );

  late final TableZone zoneCentrale = TableZone(
    center: centre,
    size: tailleZoneCentrale,
  );

  late final List<TableSeatGeometry> sieges = _calculerSieges();

  TableSeatGeometry? siegeParIdentifiant(int siege) {
    for (final candidat in sieges) {
      if (candidat.siege == siege) {
        return candidat;
      }
    }
    return null;
  }

  AdaptiveTableGeometry copierAvec({
    TableSurface? surface,
    List<int>? siegesOccupes,
    int? siegeLocal,
    double? echelleCarte,
    double? echelleInterface,
  }) {
    return AdaptiveTableGeometry(
      surface: surface ?? this.surface,
      siegesOccupes: siegesOccupes ?? this.siegesOccupes,
      siegeLocal: siegeLocal ?? this.siegeLocal,
      echelleCarte: echelleCarte ?? this.echelleCarte,
      echelleInterface: echelleInterface ?? this.echelleInterface,
    );
  }

  AdaptiveTableGeometry avecSurface(TableSurface nouvelleSurface) =>
      copierAvec(surface: nouvelleSurface);

  AdaptiveTableGeometry avecSiegesOccupes(List<int> nouveauxSieges) =>
      copierAvec(siegesOccupes: nouveauxSieges);

  AdaptiveTableGeometry avecSiegeLocal(int nouveauSiegeLocal) =>
      copierAvec(siegeLocal: nouveauSiegeLocal);

  TableRect _calculerTapis() {
    final largeurDisponible =
        surface.width * (1 - 2 * _margeHorizontaleTapis);

    // Réserve pour la pastille la plus basse de l'arc supérieur (à 10h/2h).
    final hauteurBande = _hauteurBandeAdversaires();
    final profondeurArc = hauteurBande;
    final margeSuperieure = math.max(
      surface.height * 0.16,
      hauteurBande + profondeurArc + tailleCarte.height / 2 + 6,
    );

    // Réserve pour le paquet du joueur local, toujours à 6h.
    final reserveInferieure = math.max(36, tailleCarte.height * 0.38) +
        tailleCarte.height / 2 +
        6;

    final hauteurDisponible =
        surface.height - margeSuperieure - reserveInferieure;
    final cote = math.min(
      largeurDisponible,
      math.max(hauteurDisponible, 0),
    );

    if (cote <= 0) {
      throw StateError('La surface disponible est trop petite pour le tapis.');
    }

    return TableRect(
      left: (surface.width - cote) / 2,
      top: margeSuperieure,
      width: cote.toDouble(),
      height: cote.toDouble(),
    );
  }

  TableSize _calculerTailleCarte() {
    final largeurBrute = largeurCarteReference * echelleCarte;
    // Indépendant du tapis : le calcul du tapis a besoin de la taille de
    // carte pour réserver la place du paquet local et de l'arc supérieur.
    final largeurMaximale = surface.width * 0.21;
    // Borne basse calibrée pour qu'une carte volante de 80 px de large
    // (constante du rendu du pli) tienne toujours dans une zone de dépôt.
    final largeur = (math.min(largeurBrute, largeurMaximale))
        .clamp(68.0, 120.0);
    const ratio = hauteurCarteReference / largeurCarteReference;
    return TableSize(width: largeur, height: largeur * ratio);
  }

  List<TableSeatGeometry> _calculerSieges() {
    final adverses = siegesOccupes.where((siege) => siege != siegeLocal).toList()
      ..sort();
    final anglesAdverses = _anglesAdversaires(adverses.length);
    final resultat = <TableSeatGeometry>[];

    for (var rang = 0; rang < siegesOccupes.length; rang++) {
      final siege = siegesOccupes[rang];
      final angle = siege == siegeLocal
          ? angleSiegeLocal
          : anglesAdverses[adverses.indexOf(siege)];
      final direction = _directionDepuisCentre(angle);
      final rotationCarte = (angle + 270) % 360;
      final positionDepot = _calculerPositionDepot(angle, direction);
      final positionTas = siege == siegeLocal
          ? _calculerPositionTasLocal()
          : _calculerPositionTasAdverse(angle);

      resultat.add(
        TableSeatGeometry(
          siege: siege,
          rang: rang,
          angleDegres: angle,
          positionTas: positionTas,
          positionDepot: positionDepot,
          zoneDepot: TableZone(
            center: positionDepot,
            size: tailleCarte.scale(1.18),
            rotationDegres: rotationCarte,
          ),
          rotationCarteDegres: rotationCarte,
          echelle: _calculerEchelleSiege(),
        ),
      );
    }

    return List.unmodifiable(resultat);
  }

  static List<double> _anglesAdversaires(int nombreAdversaires) {
    switch (nombreAdversaires) {
      case 1:
        return anglesAdversaires2Joueurs;
      case 2:
        return anglesAdversaires3Joueurs;
      case 3:
        return anglesAdversaires4Joueurs;
    }
    throw ArgumentError.value(
      nombreAdversaires,
      'nombreAdversaires',
      'Le nombre d\'adversaires doit être compris entre 1 et 3.',
    );
  }

  TablePoint _directionDepuisCentre(double angleDegres) {
    final radians = angleDegres * math.pi / 180;
    final cosinus = math.cos(radians);
    final sinus = math.sin(radians);

    if (cosinus.abs() < 0.000001) {
      return TablePoint(0, sinus < 0 ? -1 : 1);
    }
    if (sinus.abs() < 0.000001) {
      return TablePoint(cosinus < 0 ? -1 : 1, 0);
    }

    return TablePoint(cosinus, sinus);
  }

  double _distanceAuBordDepuisCentre(TablePoint direction) {
    var distance = double.infinity;

    if (direction.x > 0) {
      distance = math.min(
        distance,
        (tapis.right - centre.x) / direction.x,
      );
    } else if (direction.x < 0) {
      distance = math.min(
        distance,
        (tapis.left - centre.x) / direction.x,
      );
    }

    if (direction.y > 0) {
      distance = math.min(
        distance,
        (tapis.bottom - centre.y) / direction.y,
      );
    } else if (direction.y < 0) {
      distance = math.min(
        distance,
        (tapis.top - centre.y) / direction.y,
      );
    }

    return distance;
  }

  TablePoint _calculerPositionDepot(
    double angleDegres,
    TablePoint direction,
  ) {
    final distanceBord = _distanceAuBordDepuisCentre(direction);
    final supportZoneCentrale = tailleZoneCentrale.width / 2 *
            direction.x.abs() +
        tailleZoneCentrale.height / 2 * direction.y.abs();
    final largeurZoneDepot = tailleCarte.width * 1.18;
    final hauteurZoneDepot = tailleCarte.height * 1.18;
    final rotationZoneDepot = (angleDegres + 270) % 360;
    final ecartOrientation =
        (angleDegres - rotationZoneDepot) * math.pi / 180;
    final supportZoneDepot = largeurZoneDepot /
            2 *
            math.cos(ecartOrientation).abs() +
        hauteurZoneDepot /
            2 *
            math.sin(ecartOrientation).abs();

    // Priorité : la zone reste dans le tapis, sur un anneau intermédiaire
    // entre le centre et le joueur. Les cartes du pli restent ainsi lisibles
    // tout en étant visiblement du côté de leur joueur.
    final distanceMaximale = math.max(
      0,
      math.min(
        distanceBord * 0.45,
        distanceBord - supportZoneDepot - 2,
      ),
    );
    final distanceSansChevauchement =
        supportZoneCentrale + supportZoneDepot + 2;

    final distance = math.min(
      distanceSansChevauchement,
      distanceMaximale,
    );

    final point = TablePoint(
      centre.x + direction.x * distance,
      centre.y + direction.y * distance,
    );

    final radiansRotation = rotationZoneDepot * math.pi / 180;
    final demiLargeurZone = largeurZoneDepot / 2 * math.cos(radiansRotation).abs() +
        hauteurZoneDepot / 2 * math.sin(radiansRotation).abs();
    final demiHauteurZone = largeurZoneDepot / 2 * math.sin(radiansRotation).abs() +
        hauteurZoneDepot / 2 * math.cos(radiansRotation).abs();
    final margeHorizontale = math.min(
      demiLargeurZone + 2,
      surface.width / 2,
    );
    final margeVerticale = math.min(
      demiHauteurZone + 2,
      surface.height / 2,
    );

    return TablePoint(
      point.x.clamp(margeHorizontale, surface.width - margeHorizontale),
      point.y.clamp(margeVerticale, surface.height - margeVerticale),
    );
  }

  TablePoint _calculerPositionTasLocal() {
    final marge = math.max(36, tailleCarte.height * 0.38);
    return TablePoint(centre.x, surface.height - marge);
  }

  TablePoint _calculerPositionTasAdverse(double angleDegres) {
    final radians = angleDegres * math.pi / 180;
    final cosinus = math.cos(radians);
    final sinus = math.sin(radians);

    final margeHorizontale = math.max(40, surface.width * 0.12);
    final demiLargeurArc = math.max(
      surface.width / 2 - margeHorizontale,
      0,
    );
    final hauteurBande = math.max(32, tailleCarte.height * 0.28);
    final profondeurArc = hauteurBande;

    return TablePoint(
      (centre.x + cosinus * demiLargeurArc)
          .clamp(margeHorizontale, surface.width - margeHorizontale)
          .toDouble(),
      hauteurBande + (1 + sinus) * profondeurArc,
    );
  }

  double _hauteurBandeAdversaires() {
    return math.max(32, tailleCarte.height * 0.28);
  }

  double _calculerEchelleSiege() {
    return ((tapis.width / 320).clamp(0.72, 1.2)) * echelleInterface;
  }
}

/// Affectation générique de joueurs à des sièges.
///
/// Le type [T] est opaque : le module de géométrie ne dépend ni d'un compte,
/// ni d'un pseudo, ni d'une session réseau. Deux joueurs sont considérés
/// identiques selon `==`, ce qui permet d'utiliser des identifiants stables
/// sans imposer leur structure.
class AffectationSieges<T> {
  final Map<int, T> joueurParSiege;

  const AffectationSieges({this.joueurParSiege = const {}});

  T? joueurAuSiege(int siege) => joueurParSiege[siege];

  int? siegeDuJoueur(T joueur) {
    for (final entree in joueurParSiege.entries) {
      if (entree.value == joueur) {
        return entree.key;
      }
    }
    return null;
  }

  AffectationSieges<T> avecJoueurAuSiege(T joueur, int siege) {
    final nouvelleTable = Map<int, T>.from(joueurParSiege);
    nouvelleTable.removeWhere((_, joueurOccupe) => joueurOccupe == joueur);
    nouvelleTable[siege] = joueur;
    return AffectationSieges<T>(joueurParSiege: Map.unmodifiable(nouvelleTable));
  }

  AffectationSieges<T> sansJoueur(T joueur) {
    final nouvelleTable = Map<int, T>.from(joueurParSiege);
    nouvelleTable.removeWhere((_, joueurOccupe) => joueurOccupe == joueur);
    return AffectationSieges<T>(joueurParSiege: Map.unmodifiable(nouvelleTable));
  }

  static AffectationSieges<T> sequentielle<T>(
    Iterable<T> joueurs, {
    int premierSiege = 0,
  }) {
    final table = <int, T>{};
    var siege = premierSiege;
    for (final joueur in joueurs) {
      table[siege] = joueur;
      siege++;
    }
    return AffectationSieges<T>(joueurParSiege: Map.unmodifiable(table));
  }
}
