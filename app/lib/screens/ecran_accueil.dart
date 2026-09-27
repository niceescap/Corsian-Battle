import 'package:flutter/material.dart';

import '../moteur/partie_locale.dart';
import '../widgets/emplacement_pub.dart';
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

  @override
  void dispose() {
    _ctrlNomHumain.dispose();
    _ctrlNomAdversaire.dispose();
    super.dispose();
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
                    const SizedBox(height: 16),
                    // Emplacement publicitaire réservé (rectangle moyen).
                    EmplacementPub(
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
          ? Colors.white.withOpacity(0.14)
          : Colors.white.withOpacity(0.05),
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
                      ? accent.withOpacity(0.22)
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
                      ? accent.withOpacity(0.25)
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
        fillColor: Colors.black.withOpacity(0.22),
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

  /// Réservé : recherche de joueurs connectés / incrustation dans une partie
  /// en cours. Branché le jour où le serveur existe. Picto seul + « SOON ».
  Widget _blocEnLigne() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_tethering, color: Colors.white30, size: 18),
          const SizedBox(width: 10),
          Text(
            'ONLINE',
            style: TextStyle(
              color: Colors.white.withOpacity(0.45),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Text(
              'SOON',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
