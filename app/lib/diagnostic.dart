import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _limiteEntreesDiagnostic = 40;

final ValueNotifier<List<String>> _journalDiagnostic =
    ValueNotifier<List<String>>(const []);

/// Ajoute une ligne horodatée au journal visible et à la sortie de diagnostic.
void tracer(String message) {
  final maintenant = DateTime.now();
  final heure = '${maintenant.hour.toString().padLeft(2, '0')}:'
      '${maintenant.minute.toString().padLeft(2, '0')}:'
      '${maintenant.second.toString().padLeft(2, '0')}';
  final ligne = '$heure $message';
  final lignes = [..._journalDiagnostic.value, ligne];
  _journalDiagnostic.value = lignes.length <= _limiteEntreesDiagnostic
      ? lignes
      : lignes.sublist(lignes.length - _limiteEntreesDiagnostic);
  debugPrint(ligne);
}

/// Panneau repliable qui affiche les dernières lignes du journal de diagnostic.
class PanneauDiagnostic extends StatefulWidget {
  const PanneauDiagnostic({super.key});

  @override
  State<PanneauDiagnostic> createState() => _PanneauDiagnosticState();
}

class _PanneauDiagnosticState extends State<PanneauDiagnostic> {
  bool _ouvert = false;

  Future<void> _copier(List<String> lignes) async {
    await Clipboard.setData(ClipboardData(text: lignes.join('\n')));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: _journalDiagnostic,
      builder: (context, lignes, _) => Container(
        margin: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _ouvert = !_ouvert),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.receipt_long,
                            color: Colors.white54,
                            size: 15,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            'DIAGNOSTIC (${lignes.length})',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            _ouvert ? Icons.expand_less : Icons.expand_more,
                            color: Colors.white54,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copier le journal',
                  onPressed: () => _copier(lignes),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, color: Colors.white54, size: 15),
                ),
              ],
            ),
            if (_ouvert)
              SizedBox(
                height: 160,
                child: lignes.isEmpty
                    ? const Center(
                        child: Text(
                          'Aucun événement',
                          style: TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                        itemCount: lignes.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: SelectableText(
                            lignes[index],
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              height: 1.2,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
