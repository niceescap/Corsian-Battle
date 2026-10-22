import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/client_jeu.dart';
import '../net/modeles_proto.dart';
import 'ecran_table_en_ligne.dart';

/// Salle d'attente : le code de la table, les joueurs présents, le partage.
///
/// Le code s'énonce oralement aussi bien qu'il se saisit : il est affiché
/// en très grand, sans ambiguïté (`0/O` et `1/I` sont exclus par le
/// serveur). L'invitation passe par le presse-papier et, si possible, par
/// le partage système.
///
/// Tant que la table est en attente, cet écran est affiché ; il laisse la
/// place à l'écran de jeu dès que la partie démarre.
class EcranSalle extends StatefulWidget {
  final ClientJeu client;
  final String codeTable;
  final String? urlPartage;
  final int monSiege;

  const EcranSalle({
    super.key,
    required this.client,
    required this.codeTable,
    this.urlPartage,
    this.monSiege = -1,
  });

  @override
  State<EcranSalle> createState() => _EcranSalleState();
}

class _EcranSalleState extends State<EcranSalle> {
  EtatTable? _etat;
  bool _basculeVersJeu = false;

  StreamSubscription<EtatTable>? _abonnement;

  @override
  void initState() {
    super.initState();
    _abonnement = widget.client.etats.listen((EtatTable etat) {
      if (!mounted) return;
      setState(() => _etat = etat);
      // La table passe en jeu : on cède la place à l'écran de jeu.
      if (etat.etat == 'en_jeu' || etat.etat == 'compte_a_rebours') {
        if (!_basculeVersJeu) {
          _basculeVersJeu = true;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => EcranTableEnLigne(
                client: widget.client,
                codeTable: widget.codeTable,
                monSiege: etat.monSiege,
              ),
            ),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _abonnement?.cancel();
    super.dispose();
  }

  Future<void> _copier() async {
    await Clipboard.setData(ClipboardData(text: widget.codeTable));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Code copié'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final etat = _etat;
    final sieges = etat?.sieges ?? const <SiegeInfo>[];
    final occupes = sieges.where((s) => s.present || s.pseudo.isNotEmpty).length;

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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Picto + titre : le code EST l'invitation.
                    const Icon(
                      Icons.wifi_tethering,
                      color: Color(0xFF80CBC4),
                      size: 34,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'CODE',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Le code, en très grand.
                    GestureDetector(
                      onTap: _copier,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 26,
                          vertical: 18,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: const Color(0xFF80CBC4),
                            width: 2,
                          ),
                        ),
                        child: Text(
                          widget.codeTable,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 52,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 8,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Consigne : joining requires the app.
                    const Text(
                      'Rejoindre → saisir ce code',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Sièges occupés.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final siege in sieges)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: _pastilleSiege(siege),
                          ),
                        if (sieges.isEmpty)
                          const Icon(
                            Icons.hourglass_empty,
                            color: Colors.white30,
                            size: 20,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$occupes / ${sieges.isEmpty ? 2 : sieges.length}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Partager / copier.
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: _copier,
                              icon: const Icon(Icons.copy, size: 18),
                              label: const Text('COPY'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white12,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: widget.urlPartage == null
                                  ? null
                                  : () => _partager(widget.urlPartage!),
                              icon: const Icon(Icons.ios_share, size: 18),
                              label: const Text('SHARE'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF80CBC4),
                                foregroundColor: const Color(0xFF071F18),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    // Attente des autres joueurs.
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          height: 14,
                          width: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF80CBC4),
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'EN ATTENTE',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
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

  Widget _pastilleSiege(SiegeInfo siege) {
    final vide = !siege.present && siege.pseudo.isEmpty;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        shape: BoxShape.circle,
        border: Border.all(
          color: siege.present ? const Color(0xFF80CBC4) : Colors.white12,
          width: siege.present ? 2 : 1,
        ),
      ),
      child: Icon(
        vide ? Icons.person_outline : Icons.person,
        color: vide ? Colors.white24 : Colors.white,
        size: 20,
      ),
    );
  }

  /// Partage système (Android 6+). Silencieux si indisponible.
  Future<void> _partager(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Lien copié'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
