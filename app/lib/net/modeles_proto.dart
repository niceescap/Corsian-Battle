/// Modèles du protocole réseau (`docs/PROTOCOLE.md`).
///
/// Le serveur est la seule autorité : l'app envoie des **intentions**
/// (« je pose ma carte », « je tape ») et affiche ce qu'il raconte. Elle
/// ne décide jamais d'un résultat.
library;

/// Un siège vu par ce client.
class SiegeInfo {
  /// Numéro du siège (0 = créateur de la table).
  final int numero;

  /// Pseudo affiché.
  final String pseudo;

  /// Nombre de cartes restantes (le contenu du tas n'est jamais transmis).
  final int nbCartes;

  /// Le joueur est-il connecté ?
  final bool present;

  /// Le siège est-il occupé par un bot (joueur parti depuis plus de 30 s) ?
  final bool estBot;

  /// La carte du dessus de CE siège — présente **uniquement** dans la copie
  /// destinée à son propriétaire.
  ///
  /// Le serveur place `ma_carte` dans l'objet du siège (`table.py`
  /// `instantane()`), pas à la racine de l'instantané : le lire à la racine
  /// revenait à ne jamais recevoir sa propre carte.
  final String? maCarte;

  const SiegeInfo({
    required this.numero,
    required this.pseudo,
    required this.nbCartes,
    required this.present,
    required this.estBot,
    this.maCarte,
  });

  factory SiegeInfo.fromJson(Map<String, dynamic> json) => SiegeInfo(
        numero: (json['siege'] as num?)?.toInt() ?? 0,
        pseudo: '${json['pseudo'] ?? 'Joueur'}',
        nbCartes: (json['nb_cartes'] as num?)?.toInt() ?? 0,
        present: json['present'] as bool? ?? false,
        estBot: json['est_bot'] as bool? ?? false,
        maCarte: json['ma_carte'] as String?,
      );
}

/// Un défi en cours (figure sortie).
class DefiInfo {
  final int poseur;
  final int repondeur;
  final int chancesRestantes;

  const DefiInfo({
    required this.poseur,
    required this.repondeur,
    required this.chancesRestantes,
  });

  factory DefiInfo.fromJson(Map<String, dynamic> json) => DefiInfo(
        poseur: (json['poseur'] as num?)?.toInt() ?? 0,
        repondeur: (json['repondeur'] as num?)?.toInt() ?? 0,
        chancesRestantes: (json['chances_restantes'] as num?)?.toInt() ?? 0,
      );
}

/// Instantané complet d'une table, filtré pour son destinataire.
///
/// `ma_carte` n'apparaît que dans la copie destinée à son propriétaire :
/// c'est la principale défense anti-triche (`docs/ARCHITECTURE.md` §8.3).
class EtatTable {
  /// `attente` · `compte_a_rebours` · `en_jeu` · `terminee`.
  final String etat;

  /// `duel` ou `table_quatre`.
  final String type;

  /// Sièges de la table.
  final List<SiegeInfo> sieges;

  /// Siège de ce client (`-1` si inconnu).
  final int monSiege;

  /// Cartes du pli en cours — publiques.
  final List<String> pli;

  /// Nombre de cartes du reste neutre — seul le compte est public.
  final int resteNeutre;

  /// Siège dont c'est le tour (`null` si personne ne peut jouer).
  final int? suivant;

  /// Défi en cours, s'il y en a un.
  final DefiInfo? defi;

  /// Nombre de coups joués.
  final int nbCoups;

  /// La carte du dessus de CE client, si elle est connue.
  final String? maCarte;

  const EtatTable({
    required this.etat,
    required this.type,
    required this.sieges,
    required this.monSiege,
    required this.pli,
    required this.resteNeutre,
    required this.suivant,
    required this.defi,
    required this.nbCoups,
    this.maCarte,
  });

  factory EtatTable.fromJson(Map<String, dynamic> json) {
    final sieges = <SiegeInfo>[];
    final bruts = json['sieges'];
    if (bruts is List) {
      for (final siege in bruts) {
        if (siege is Map<String, dynamic>) sieges.add(SiegeInfo.fromJson(siege));
      }
    }
    final defiJson = json['defi'];
    return EtatTable(
      etat: '${json['etat'] ?? 'attente'}',
      type: '${json['type'] ?? 'duel'}',
      sieges: sieges,
      // `table_etat` porte `mon_siege`, `bienvenue` porte `siege`.
      monSiege: (json['mon_siege'] as num?)?.toInt() ??
          (json['siege'] as num?)?.toInt() ??
          -1,
      pli: (json['pli'] is List)
          ? (json['pli'] as List).map((c) => '$c').toList()
          : const [],
      resteNeutre: (json['reste_neutre'] as num?)?.toInt() ?? 0,
      suivant: (json['suivant'] as num?)?.toInt(),
      defi: defiJson is Map<String, dynamic> ? DefiInfo.fromJson(defiJson) : null,
      nbCoups: (json['nb_coups'] as num?)?.toInt() ?? 0,
      maCarte: json['ma_carte'] as String? ??
          _maCarteDuSiege(sieges, json),
    );
  }

  /// Retrouve `ma_carte` dans l'objet du siège de ce client.
  ///
  /// Le serveur n'envoie la carte du dessus qu'à son propriétaire, et la
  /// place dans l'objet du siège (`table.py` `instantane()`). Elle peut aussi
  /// arriver à la racine selon la forme de l'instantané : on accepte les
  /// deux, mais jamais celle d'un autre siège.
  static String? _maCarteDuSiege(List<SiegeInfo> sieges, Map<String, dynamic> json) {
    final numero = (json['mon_siege'] as num?)?.toInt() ??
        (json['siege'] as num?)?.toInt() ??
        -1;
    if (numero < 0) return null;
    for (final siege in sieges) {
      if (siege.numero == numero) return siege.maCarte;
    }
    return null;
  }

  /// Copie de cet état avec une carte du dessus connue.
  ///
  /// Utilisé quand le canal privé (`ta_carte_suivante`) est arrivé avant
  /// l'instantané : l'état ne doit pas perdre l'information.
  EtatTable avecMaCarte(String carte) => EtatTable(
        etat: etat,
        type: type,
        sieges: sieges,
        monSiege: monSiege,
        pli: pli,
        resteNeutre: resteNeutre,
        suivant: suivant,
        defi: defi,
        nbCoups: nbCoups,
        maCarte: carte,
      );

  /// Siège de ce client dans la liste, s'il existe.
  SiegeInfo? get monSiegeInfo {
    for (final siege in sieges) {
      if (siege.numero == monSiege) return siege;
    }
    return null;
  }
}

/// Une carte posée sur le tapis.
class CartePosee {
  final int siege;
  final String carte;
  final int taillePli;
  final int? suivant;
  final DefiInfo? defi;

  /// Le coup a été joué par le serveur (délai de tour dépassé).
  final bool auto;

  /// La carte a déjà été annoncée par `doublon_ouvert`.
  final bool annonce;

  const CartePosee({
    required this.siege,
    required this.carte,
    required this.taillePli,
    required this.suivant,
    required this.defi,
    required this.auto,
    required this.annonce,
  });

  factory CartePosee.fromJson(Map<String, dynamic> json) {
    final defiJson = json['defi'];
    return CartePosee(
      siege: (json['siege'] as num?)?.toInt() ?? 0,
      carte: '${json['carte'] ?? ''}',
      taillePli: (json['pli'] as num?)?.toInt() ?? 0,
      suivant: (json['suivant'] as num?)?.toInt(),
      defi: defiJson is Map<String, dynamic> ? DefiInfo.fromJson(defiJson) : null,
      auto: json['auto'] as bool? ?? false,
      annonce: json['annonce'] as bool? ?? false,
    );
  }
}

/// Une fenêtre de doublon ouverte.
class DoublonOuvert {
  /// Durée de la fenêtre, en millisecondes.
  final int fenetreMs;

  /// Les deux cartes du dessus (le pli et la carte à venir).
  final List<String> cartes;

  /// Délai minimal accepté (en deçà : suspicion de triche).
  final int plancherMs;

  const DoublonOuvert({
    required this.fenetreMs,
    required this.cartes,
    required this.plancherMs,
  });

  factory DoublonOuvert.fromJson(Map<String, dynamic> json) => DoublonOuvert(
        fenetreMs: (json['fenetre_ms'] as num?)?.toInt() ?? 900,
        cartes: (json['cartes'] is List)
            ? (json['cartes'] as List).map((c) => '$c').toList()
            : const [],
        plancherMs: (json['plancher_ms'] as num?)?.toInt() ?? 120,
      );
}

/// Verdict d'une fenêtre de doublon.
class DoublonResolu {
  /// Siège vainqueur, `null` si personne n'a tapé.
  final int? gagnant;

  /// Délai local du vainqueur.
  final double? delaiMsGagnant;

  /// Personne n'a tapé : le pli n'est attribué à personne.
  final bool personne;

  const DoublonResolu({
    required this.gagnant,
    required this.delaiMsGagnant,
    required this.personne,
  });

  factory DoublonResolu.fromJson(Map<String, dynamic> json) => DoublonResolu(
        gagnant: (json['gagnant'] as num?)?.toInt(),
        delaiMsGagnant: (json['delai_ms_gagnant'] as num?)?.toDouble(),
        personne: json['personne'] as bool? ?? false,
      );
}

/// Un pli attribué.
class PliGagne {
  final int? gagnant;
  final int nbCartes;
  final String raison;
  final bool resteNeutreInclus;

  const PliGagne({
    required this.gagnant,
    required this.nbCartes,
    required this.raison,
    required this.resteNeutreInclus,
  });

  factory PliGagne.fromJson(Map<String, dynamic> json) => PliGagne(
        gagnant: (json['gagnant'] as num?)?.toInt(),
        nbCartes: (json['nb_cartes'] as num?)?.toInt() ?? 0,
        raison: '${json['raison'] ?? ''}',
        resteNeutreInclus: json['reste_neutre_inclus'] as bool? ?? false,
      );
}

/// Fin de partie.
class PartieFinie {
  final int? gagnant;
  final String raison;
  final int nbCoups;
  final int dureeMs;

  /// Statistiques par siège.
  final List<StatsSiege> stats;

  const PartieFinie({
    required this.gagnant,
    required this.raison,
    required this.nbCoups,
    required this.dureeMs,
    required this.stats,
  });

  factory PartieFinie.fromJson(Map<String, dynamic> json) {
    final stats = <StatsSiege>[];
    final bruts = json['stats'];
    if (bruts is List) {
      for (final ligne in bruts) {
        if (ligne is Map<String, dynamic>) stats.add(StatsSiege.fromJson(ligne));
      }
    }
    return PartieFinie(
      gagnant: (json['gagnant'] as num?)?.toInt(),
      raison: '${json['raison'] ?? ''}',
      nbCoups: (json['nb_coups'] as num?)?.toInt() ?? 0,
      dureeMs: (json['duree_ms'] as num?)?.toInt() ?? 0,
      stats: stats,
    );
  }
}

/// Statistiques d'un siège en fin de partie.
class StatsSiege {
  final int siege;
  final String pseudo;
  final int nbCartes;
  final bool gagnant;
  final int doublonsGagnes;

  const StatsSiege({
    required this.siege,
    required this.pseudo,
    required this.nbCartes,
    required this.gagnant,
    required this.doublonsGagnes,
  });

  factory StatsSiege.fromJson(Map<String, dynamic> json) => StatsSiege(
        siege: (json['siege'] as num?)?.toInt() ?? 0,
        pseudo: '${json['pseudo'] ?? 'Joueur'}',
        nbCartes: (json['nb_cartes'] as num?)?.toInt() ?? 0,
        gagnant: json['gagnant'] as bool? ?? false,
        doublonsGagnes: (json['doublons_gagnes'] as num?)?.toInt() ?? 0,
      );
}
