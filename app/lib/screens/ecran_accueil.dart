import 'package:flutter/material.dart';

import '../moteur/partie_locale.dart';
import 'ecran_table.dart';

/// Page de lancement : première brique de l'écran d'accueil.
///
/// À terme (production AAB) cette page devra enchaîner : recherche de
/// joueurs connectés en attente d'une partie, incrustation dans une partie
/// en cours, puis fallback vers le moteur local. L'ossature est posée ici
/// avec une section « En ligne » volontairement désactivée : le jour où le
/// serveur existe, il suffira de brancher ce bloc.
class EcranAccueil extends StatefulWidget {
  const EcranAccueil({super.key});

  @override
  State<EcranAccueil> createState() => _EcranAccueilState();
}

class _EcranAccueilState extends State<EcranAccueil> {
  ModePartie _mode = ModePartie.duel;

  final _ctrlNomHumain = TextEditingController(text: 'Toi');
  final _ctrlNomAdversaire = TextEditingController(text: 'Marc');

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
      nomHumain: _nettoyer(_ctrlNomHumain, 'Toi'),
      nomAdversaire: _nettoyer(_ctrlNomAdversaire, 'Marc'),
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
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _titre(),
                    const SizedBox(height: 26),
                    _carteMode(
                      mode: ModePartie.duel,
                      icone: Icons.bolt,
                      titre: 'Duel',
                      sousTitre: '1 contre 1 · l’adversaire épouse ton rythme',
                      accent: const Color(0xFFFFD54F),
                    ),
                    const SizedBox(height: 12),
                    _carteMode(
                      mode: ModePartie.tableQuatre,
                      icone: Icons.groups,
                      titre: 'Table à 4',
                      sousTitre: 'Marc, Julie et Théo · la table historique',
                      accent: const Color(0xFF80CBC4),
                    ),
                    const SizedBox(height: 22),
                    _champsNoms(),
                    const SizedBox(height: 24),
                    _boutonJouer(),
                    const SizedBox(height: 22),
                    _blocEnLigne(),
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
        // Motif de trois cartes éventailées, purement décoratif.
        SizedBox(
          height: 62,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                Transform.rotate(
                  angle: (i - 1) * 0.22,
                  child: Transform.translate(
                    offset: Offset((i - 1) * 26.0, 0),
                    child: Container(
                      width: 40,
                      height: 56,
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
        const Text(
          'BATAILLE CORSE',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _mode == ModePartie.duel
              ? 'Joue vite, il jouera vite.'
              : 'Le tapis classique, quatre autour de la table.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 14,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _carteMode({
    required ModePartie mode,
    required IconData icone,
    required String titre,
    required String sousTitre,
    required Color accent,
  }) {
    final selectionne = _mode == mode;
    return Material(
      color: selectionne ? Colors.white.withOpacity(0.14) : Colors.white.withOpacity(0.05),
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: selectionne ? accent.withOpacity(0.22) : Colors.white10,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icone,
                  color: selectionne ? accent : Colors.white60,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titre,
                      style: TextStyle(
                        color: selectionne ? Colors.white : Colors.white70,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sousTitre,
                      style: TextStyle(
                        color: selectionne ? Colors.white70 : Colors.white38,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
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
          etiquette: 'Ton pseudo',
          icone: Icons.person,
        ),
        if (estDuel) ...[
          const SizedBox(height: 10),
          _champ(
            ctrl: _ctrlNomAdversaire,
            etiquette: 'Nom de l’adversaire-machine',
            icone: Icons.smart_toy,
          ),
        ],
      ],
    );
  }

  Widget _champ({
    required TextEditingController ctrl,
    required String etiquette,
    required IconData icone,
  }) {
    return TextField(
      controller: ctrl,
      maxLength: 14,
      textAlign: TextAlign.center,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        counterText: '',
        hintText: etiquette,
        hintStyle: const TextStyle(color: Colors.white38),
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
      height: 54,
      child: ElevatedButton.icon(
        onPressed: _lancer,
        icon: const Icon(Icons.play_arrow_rounded, size: 30),
        label: Text(
          _mode == ModePartie.duel ? 'Entrer en duel' : 'Prendre place',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.6,
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

  /// Réservé : recherche de joueurs connectés / incrustation dans une
  /// partie en cours. Branché le jour où le serveur existe.
  Widget _blocEnLigne() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: const Row(
        children: [
          Icon(Icons.wifi_tethering_off, color: Colors.white30, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Partie en ligne — bientôt.\nRecherche de joueurs, incrustation dans une partie en cours.',
              style: TextStyle(color: Colors.white38, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}
