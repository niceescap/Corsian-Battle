import 'package:flutter/material.dart';
import 'screens/ecran_accueil.dart';

void main() {
  runApp(const BatailleCorseApp());
}

class BatailleCorseApp extends StatelessWidget {
  const BatailleCorseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Titre in-app (barre de tâches / multitâche). Le nom visible pour le
      // joueur reste « CORSIAN BATTLE », affiché sur l'écran d'accueil.
      title: 'Corsian Battle',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B3D2E),
      ),
      // L'app ouvre sur la page de lancement : c'est elle qui choisit la
      // configuration de table (duel 1v1 ou table à 4) avant d'entrer sur
      // le tapis.
      home: const EcranAccueil(),
    );
  }
}
