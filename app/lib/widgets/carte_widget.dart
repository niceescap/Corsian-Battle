import 'package:flutter/material.dart';

/// Représente visuellement une carte.
/// [code] au format poker (ex: "AH", "KC", "TH", "9S", "7D") — voir
/// cartes.py côté moteur, qui génère exactement ce même code. Si [code]
/// est null, la carte est affichée dos visible (assets/cartes/back.png).
class CarteWidget extends StatelessWidget {
  final String? code;
  final double largeur;
  final double hauteur;

  const CarteWidget({
    super.key,
    this.code,
    this.largeur = 64,
    this.hauteur = 90,
  });

  String get _cheminAsset =>
      code == null ? 'assets/cartes/back.png' : 'assets/cartes/$code.png';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: largeur,
      height: hauteur,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(1, 2)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        _cheminAsset,
        fit: BoxFit.cover,
        errorBuilder: (context, error, pile) => _PlaceholderCarte(code: code),
      ),
    );
  }
}

/// Rectangle de secours tant que les vrais assets PNG ne sont pas encore
/// livrés — évite un écran cassé pendant le développement de l'UI.
class _PlaceholderCarte extends StatelessWidget {
  final String? code;
  const _PlaceholderCarte({this.code});

  @override
  Widget build(BuildContext context) {
    final estDos = code == null;
    return Container(
      color: estDos ? const Color(0xFF7A1F2B) : Colors.white,
      alignment: Alignment.center,
      child: estDos
          ? const Icon(Icons.style, color: Colors.white70, size: 20)
          : Text(
              code!,
              style: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
    );
  }
}
