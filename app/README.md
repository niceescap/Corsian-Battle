# `app/` — application Flutter

Interface tactile de Corsian-Battle : duel contre la machine, table à 4
locale, et **multijoueur en ligne** (compte invité, tables par code, jeu en
WebSocket).

## Structure

```
lib/
  main.dart                  point d'entrée
  modeles.dart               types d'UI partagés
  effets.dart                effets visuels (flash, bannière)
  moteur/                    port Dart des règles, pour le jeu HORS-LIGNE
    partie_locale.dart       moteur local (duel, table à 4)
    rythme.dart              mesure du rythme du joueur (miroir du bot)
  net/                       COUCHE RÉSEAU (nouveau)
    config_reseau.dart       préfixe public, origines, configuration
    client_auth.dart         REST `corsian-auth` (invite, refresh, profil)
    client_jeu_rest.dart     REST `corsian-jeu` (tables, config, stats)
    client_jeu.dart          WebSocket de jeu (protocole v1)
    modeles_proto.dart       modèles du protocole
    session_jeu.dart         session persistée (jetons, identifiant appareil)
    erreur_reseau.dart       erreurs lisibles (code + message)
  screens/
    ecran_accueil.dart       page de lancement (local + en ligne)
    ecran_table.dart         table de jeu locale
    ecran_table_en_ligne.dart table de jeu en ligne (nouveau)
  widgets/                   composants (cartes, tas, entête, flèches…)
```

## Règle d'or

> **Le serveur décide, le client affiche.**

`lib/net/` ne rejoue **jamais** les règles : elle envoie des intentions
(« je pose ma carte du dessus », « je tape ») et affiche ce que le serveur
raconte. `lib/moteur/` reste la version **hors-ligne** du jeu : elle ne sert
jamais à arbitrer une partie en ligne (`docs/ARCHITECTURE.md` §3.2).

## Lancer en développement

Le backend local est nécessaire pour le mode en ligne :

```bash
# 1) le serveur (à la racine du dépôt)
bash serveur/lancer_local.sh

# 2) l'app
cd app
flutter pub get
flutter run
```

L'app vise `127.0.0.1:8111` (auth) et `127.0.0.1:8112` (jeu). Pour un
téléphone physique ou un émulateur, on surcharge l'hôte à la compilation :

```bash
flutter run --dart-define=HOST_IP=192.168.1.20      # téléphone sur le LAN
flutter run --dart-define=HOST_IP=10.0.2.2          # émulateur Android
```

## Tests

```bash
flutter analyze     # doit rester vert (bloquant en CI)
flutter test        # test d'intégration réseau, ignoré sans serveur
```

Le test d'intégration joue une **vraie partie complète** en WebSocket
contre le backend local. Sans serveur, il est ignoré (jamais en échec) :
en CI, il n'y a pas de serveur, la étape est donc neutre.

## Construire l'APK

L'arbre `android/` est **versionné** : il porte le nom d'application
« Corsian Battle », la permission `INTERNET` et la configuration de
sécurité réseau. La CI ne le régénère plus.

```bash
flutter build apk --debug        # APK de test
flutter build appbundle --release  # AAB pour le Play Store (S5)
```
