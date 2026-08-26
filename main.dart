import 'package:flutter/material.dart';
import 'screens/ecran_table.dart';

void main() {
  runApp(const BatailleCorseApp());
}

class BatailleCorseApp extends StatelessWidget {
  const BatailleCorseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bataille Corse',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B3D2E),
      ),
      home: const EcranTable(),
    );
  }
}
