import 'package:flutter/material.dart';

import '../net/session_jeu.dart';

/// Écran « Compte » : pseudo, état de la session, suppression du compte.
///
/// La suppression du compte est une **exigence** : RGPD (droit à l'effacement)
/// et politique Google Play, qui impose que la suppression soit possible
/// *depuis l'application* (`docs/CONFORMITE.md` §5). Elle est immédiate et
/// irréversible côté serveur.
///
/// Le reste de l'UX est sans mot ; cet écran est un écran de gestion, pas
/// un écran de jeu : il peut donc employer des mots.
class EcranCompte extends StatefulWidget {
  /// Session de jeu partagée avec l'écran d'accueil.
  final SessionJeu session;

  const EcranCompte({super.key, required this.session});

  @override
  State<EcranCompte> createState() => _EcranCompteState();
}

class _EcranCompteState extends State<EcranCompte> {
  bool _suppressionEnCours = false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final session = widget.session.session;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compte'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _bloc('Joueur', session?.pseudo ?? '—'),
                  _bloc('Identifiant technique',
                      'Généré par l\'app, jamais transmis à un service tiers.'),
                  const SizedBox(height: 22),
                  if (_message != null) ...[
                    Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _boutonSupprimer(),
                  const SizedBox(height: 14),
                  Text(
                    'La suppression est immédiate et irréversible : le compte et '
                    'les données associées sont effacés. Les parties déjà '
                    'jouées restent visibles pour les autres joueurs, avec le '
                    'siège « Joueur ».',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bloc(String titre, String valeur) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titre,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            valeur,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _boutonSupprimer() {
    return SizedBox(
      height: 50,
      child: ElevatedButton.icon(
        onPressed: _suppressionEnCours ? null : _supprimer,
        icon: const Icon(Icons.delete_outline, size: 20),
        label: Text(_suppressionEnCours ? 'SUPPRESSION…' : 'SUPPRIMER LE COMPTE'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF7B2C2C),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  /// Supprime le compte, après confirmation explicite.
  Future<void> _supprimer() async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (contexte) => AlertDialog(
        backgroundColor: const Color(0xFF1B2A24),
        title: const Text(
          'Supprimer le compte ?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Cette action est immédiate et irréversible.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(contexte).pop(false),
            child: const Text('ANNULER'),
          ),
          TextButton(
            onPressed: () => Navigator.of(contexte).pop(true),
            child: const Text(
              'SUPPRIMER',
              style: TextStyle(color: Color(0xFFFF8A80)),
            ),
          ),
        ],
      ),
    );
    if (confirme != true) return;

    setState(() {
      _suppressionEnCours = true;
      _message = null;
    });

    try {
      await widget.session.supprimerCompte();
      if (!mounted) return;
      setState(() {
        _suppressionEnCours = false;
        _message = 'Compte supprimé.';
      });
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _suppressionEnCours = false;
        _message = 'Suppression impossible : $e';
      });
    }
  }
}
