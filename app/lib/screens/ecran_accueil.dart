import 'package:flutter/material.dart';

import '../moteur/partie_locale.dart';
import '../net/client_jeu.dart';
import '../net/config_reseau.dart';
import '../net/client_jeu_rest.dart';
import '../net/erreur_reseau.dart';
import '../net/session_jeu.dart';
import '../widgets/emplacement_pub.dart';
import 'ecran_compte.dart';
import 'ecran_salle.dart';
import 'ecran_table.dart';

/// Page de lancement.
///
/// UX UNIVERSELLE : le titre « CORSIAN BATTLE » est le seul élément de marque
/// développé. Tout le reste passe par des PICTOGRAMMES (univers des cartes à
/// jouer) et des termes anglais minimaux. Le choix du mode de table se fait
/// visuellement : 1 contre 1 (duel) ou la table à 4.
///
/// À terme (production AAB) cette page enchaînera : recherche de joueurs
/// connectés, incrustation dans une partie en cours, puis fallback local.
/// Le bloc « ONLINE » est réservé et désactivé : le jour où le serveur
/// existe, il suffira de le brancher.
class EcranAccueil extends StatefulWidget {
  const EcranAccueil({super.key});

  @override
  State<EcranAccueil> createState() => _EcranAccueilState();
}

class _EcranAccueilState extends State<EcranAccueil> {
  ModePartie _mode = ModePartie.duel;

  final _ctrlNomHumain = TextEditingController(text: 'YOU');
  final _ctrlNomAdversaire = TextEditingController(text: 'MARC');

  // --- Multijoueur en ligne ---------------------------------------------
  /// Configuration réseau de la compilation.
  ///
  /// Une seule instance partagée par tous les clients de cet écran : le
  /// REST, la session et la socket doivent viser **le même** serveur, sinon
  /// la table créée d'un côté n'est pas celle rejointe de l'autre.
  final ConfigurationReseau _config = ConfigurationReseau.depuisDefines();

  /// Session courante (compte invité). Créée à la demande.
  late final SessionJeu _session = SessionJeu(config: _config);

  /// Client REST de jeu (tables, configuration).
  late final ClientJeuRest _rest = ClientJeuRest(config: _config);

  /// Le multijoueur en ligne est-il disponible ?
  bool _enLigneDisponible = false;

  /// Une opération réseau est-elle en cours ?
  bool _chargement = false;

  /// Message d'erreur à afficher (hors-jeu, donc du texte est acceptable).
  String? _erreur;

  /// Code de table à rejoindre (saisi par le joueur).
  final _ctrlCodeTable = TextEditingController();

  @override
  void initState() {
    super.initState();
    _testerServeur();
  }

  @override
  void dispose() {
    _ctrlNomHumain.dispose();
    _ctrlNomAdversaire.dispose();
    _ctrlCodeTable.dispose();
    _rest.close();
    super.dispose();
  }

  /// Vérifie que le serveur répond et prépare la session.
  ///
  /// L'app **ne bloque jamais** le jeu hors-ligne : si le serveur est
  /// injoignable, le mode duel contre la machine reste utilisable.
  Future<void> _testerServeur() async {
    try {
      await _rest.config();
      final existante = await _session.sessionPersistee();
      if (!mounted) return;
      setState(() => _enLigneDisponible = true);
      if (existante == null) {
        // On ne crée le compte invité qu'au premier besoin : inutile de
        // solliciter le serveur pour quelqu'un qui ne jouera qu'en local.
      }
    } on ErreurReseau {
      if (!mounted) return;
      setState(() => _enLigneDisponible = false);
    }
  }

  /// Ouvre (ou crée) la session joueur.
  Future<String?> _jeton() async {
    final session = await _session.ouvrirSession(
      pseudo: _nettoyer(_ctrlNomHumain, 'YOU'),
    );
    return session.jetonAcces;
  }

  /// Crée une table puis ouvre la socket de jeu.
  Future<void> _creerTableEnLigne() async {
    if (_chargement) return;
    setState(() {
      _chargement = true;
      _erreur = null;
    });
    try {
      final jeton = await _jeton();
      if (jeton == null) return;
      final table = await _rest.creerTable(
        jeton: jeton,
        type: _mode == ModePartie.duel ? 'duel' : 'table_quatre',
      );
      await _ouvrirTable(table.code, urlPartage: table.urlPartage);
    } on ErreurReseau catch (e) {
      if (!mounted) return;
      setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _chargement = false);
    }
  }

  /// Rejoint une table par son code.
  Future<void> _rejoindreTable() async {
    if (_chargement) return;
    final code = _ctrlCodeTable.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _erreur = 'Saisis le code de la table.');
      return;
    }
    setState(() {
      _chargement = true;
      _erreur = null;
    });
    try {
      final jeton = await _jeton();
      if (jeton == null) return;
      await _rest.rejoindreTable(jeton: jeton, code: code);
      await _ouvrirTable(code, urlPartage: _config.urlPartage(code));
    } on ErreurReseau catch (e) {
      if (!mounted) return;
      setState(() => _erreur = e.message);
    } finally {
      if (mounted) setState(() => _chargement = false);
    }
  }

  /// Ouvre la socket de jeu et bascule sur la salle d'attente.
  ///
  /// La salle affiche le code à 6 caractères (l'invitation) et les joueurs
  /// présents ; elle cède la place à l'écran de jeu quand la partie démarre.
  Future<void> _ouvrirTable(String code, {String? urlPartage}) async {
    final jeton = await _jeton();
    if (jeton == null) return;
    final client = ClientJeu(config: _config);
    try {
      await client.ouvrir(jeton: jeton, codeTable: code);
    } on ErreurReseau catch (e) {
      if (!mounted) return;
      setState(() => _erreur = e.message);
      await client.fermer();
      return;
    }
    if (!mounted) {
      await client.fermer();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EcranSalle(
          client: client,
          codeTable: code,
          urlPartage: urlPartage,
        ),
      ),
    );
    // L'écran a fermé la socket : on ne conserve rien.
    await client.disposing();
  }

  String _nettoyer(TextEditingController ctrl, String repli) {
    final valeur = ctrl.text.trim();
    return valeur.isEmpty ? repli : valeur;
  }

  void _lancer() {
    final config = ConfigPartie(
      mode: _mode,
      nomHumain: _nettoyer(_ctrlNomHumain, 'YOU'),
      nomAdversaire: _nettoyer(_ctrlNomAdversaire, 'MARC'),
    );

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EcranTable(config: config),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF12694A), Color(0xFF0B3D2E), Color(0xFF071F18)],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _titre(),
                    const SizedBox(height: 24),
                    _carteMode(
                      mode: ModePartie.duel,
                      icone: Icons.bolt,
                      titre: 'DUEL',
                      badge: '1v1',
                      accent: const Color(0xFFFFD54F),
                    ),
                    const SizedBox(height: 12),
                    _carteMode(
                      mode: ModePartie.tableQuatre,
                      icone: Icons.groups,
                      titre: 'TABLE',
                      badge: '4',
                      accent: const Color(0xFF80CBC4),
                    ),
                    const SizedBox(height: 22),
                    _champsNoms(),
                    const SizedBox(height: 22),
                    _boutonJouer(),
                    const SizedBox(height: 20),
                    _blocEnLigne(),
                    const SizedBox(height: 12),
                    _boutonCompte(),
                    const SizedBox(height: 16),
                    // Emplacement publicitaire réservé (rectangle moyen).
                    const EmplacementPub(
                      format: FormatPub.rectangleMoyen,
                      largeurDisponible: 300,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titre() {
    return Column(
      children: [
        // Motif de trois cartes éventailées, purement décoratif (logo).
        SizedBox(
          height: 64,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                Transform.rotate(
                  angle: (i - 1) * 0.22,
                  child: Transform.translate(
                    offset: Offset((i - 1) * 26.0, 0),
                    child: Container(
                      width: 42,
                      height: 58,
                      decoration: BoxDecoration(
                        color: const Color(0xFF7A1F2B),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: Colors.white38),
                        boxShadow: const [
                          BoxShadow(color: Colors.black54, blurRadius: 8),
                        ],
                      ),
                      child: const Icon(
                        Icons.style,
                        color: Colors.white38,
                        size: 18,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // Seul élément de marque développé.
        const Text(
          'CORSIAN BATTLE',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
          ),
        ),
      ],
    );
  }

  Widget _carteMode({
    required ModePartie mode,
    required IconData icone,
    required String titre,
    required String badge,
    required Color accent,
  }) {
    final selectionne = _mode == mode;
    return Material(
      color: selectionne
          ? Colors.white.withValues(alpha: 0.14)
          : Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _mode = mode),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selectionne ? accent : Colors.white24,
              width: selectionne ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: selectionne
                      ? accent.withValues(alpha: 0.22)
                      : Colors.white10,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icone,
                  color: selectionne ? accent : Colors.white60,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                titre,
                style: TextStyle(
                  color: selectionne ? Colors.white : Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: selectionne
                      ? accent.withValues(alpha: 0.25)
                      : Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    color: selectionne ? accent : Colors.white54,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const Spacer(),
              Icon(
                selectionne
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selectionne ? accent : Colors.white30,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _champsNoms() {
    final estDuel = _mode == ModePartie.duel;
    return Column(
      children: [
        _champ(
          ctrl: _ctrlNomHumain,
          icone: Icons.person,
        ),
        if (estDuel) ...[
          const SizedBox(height: 10),
          _champ(
            ctrl: _ctrlNomAdversaire,
            icone: Icons.smart_toy,
          ),
        ],
      ],
    );
  }

  Widget _champ({
    required TextEditingController ctrl,
    required IconData icone,
  }) {
    return TextField(
      controller: ctrl,
      maxLength: 14,
      textAlign: TextAlign.center,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        counterText: '',
        prefixIcon: Icon(icone, color: Colors.white38, size: 20),
        filled: true,
        fillColor: Colors.black.withValues(alpha: 0.22),
        contentPadding: const EdgeInsets.symmetric(vertical: 4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFFFD54F), width: 2),
        ),
      ),
    );
  }

  Widget _boutonJouer() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: _lancer,
        icon: const Icon(Icons.play_arrow_rounded, size: 32),
        label: const Text(
          'PLAY',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFFFD54F),
          foregroundColor: const Color(0xFF071F18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 6,
          shadowColor: Colors.black54,
        ),
      ),
    );
  }

  /// Bloc « en ligne » : créer une table ou en rejoindre une par son code.
  ///
  /// Le jeu hors-ligne reste prioritaire : si le serveur ne répond pas, ce
  /// bloc est simplement inerte et le duel contre la machine fonctionne
  /// toujours (`docs/ARCHITECTURE.md` §1.5).
  /// Accès au compte : pseudo et suppression du compte.
  ///
  /// La suppression doit être possible **depuis l'application** : c'est une
  /// exigence RGPD et une condition de passage sur Google Play
  /// (`docs/CONFORMITE.md` §5).
  Widget _boutonCompte() {
    return SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        onPressed: _ouvrirCompte,
        icon: const Icon(Icons.person_outline, size: 18),
        label: const Text(
          'ACCOUNT',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white70,
          side: const BorderSide(color: Colors.white24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Future<void> _ouvrirCompte() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EcranCompte(session: _session),
      ),
    );
    if (!mounted) return;
    // La session a pu être supprimée : l'accueil doit refléter l'état.
    setState(() {});
  }

  Widget _blocEnLigne() {
    if (!_enLigneDisponible) {
      // Serveur injoignable : on le signale par un picto, sans texte.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, color: Colors.white30, size: 18),
            SizedBox(width: 10),
            Text(
              'OFFLINE',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.wifi_tethering, color: Color(0xFF80CBC4), size: 18),
              const SizedBox(width: 10),
              const Text(
                'ONLINE',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              if (_chargement)
                const SizedBox(
                  height: 14,
                  width: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF80CBC4),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Créer une table.
          SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _chargement ? null : _creerTableEnLigne,
              icon: const Icon(Icons.add, size: 20),
              label: const Text(
                'CREATE TABLE',
                style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF80CBC4),
                foregroundColor: const Color(0xFF071F18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Rejoindre par code.
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrlCodeTable,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                  ),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'CODE',
                    hintStyle: const TextStyle(
                      color: Colors.white24,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w700,
                    ),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.22),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 2, horizontal: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFF80CBC4),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 46,
                width: 52,
                child: ElevatedButton(
                  onPressed: _chargement ? null : _rejoindreTable,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white12,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Icon(Icons.login, size: 22),
                ),
              ),
            ],
          ),
          if (_erreur != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _erreur!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
