# Corsian-Battle — Conformité Google Play, RGPD et publication

> Ce document prépare les trois obligations qui bloquent le plus souvent une soumission :
> la **politique de confidentialité publique**, le **formulaire Data Safety**, et la
> **suppression de compte**. Il anticipe aussi l'obligation **UGC** (pseudos visibles d'autres
> joueurs) et l'état réel de la piste **iOS**.

---

## 1. Ce que Play exige pour cette application

| Exigence | Statut du projet | Où c'est traité |
|---|---|---|
| Politique de confidentialité à URL publique, accessible sans compte | À publier | §3, page `privacy.html` |
| URL de cette politique renseignée dans Play Console **et** accessible dans l'app | À faire | §3.4 |
| Formulaire **Data Safety** cohérent avec la politique | À remplir | §4 |
| **Suppression de compte** : dans l'app **et** sur une page web | Conçu | §5 |
| Mécanisme de **signalement** et de **blocage** si contenu généré par les utilisateurs | Conçu | §6 |
| **Modération** des contenus utilisateurs (pseudos) | Conçu | §6 |
| Format **AAB** signé pour une nouvelle application | Bloqué par la CI actuelle | `DEPLOIEMENT.md` §9 |
| Niveau d'API cible imposé à la date de soumission | À vérifier dans la Console | §7 |
| Questionnaire de classification (IARC) | À remplir | §8 |
| Déclaration des publicités si AdMob est branché | Non branché en V1 | §9 |

## 2. Données réellement manipulées

Inventaire exhaustif — ce qui n'est pas dans cette liste n'est ni collecté ni stocké :

| Donnée | Collectée | Stockée | Durée | Partagée |
|---|---|---|---|---|
| Pseudo (choisi par le joueur, visible des autres) | oui | oui | vie du compte | autres joueurs |
| Identifiant d'appareil (UUID **généré par l'app**) | oui | oui | vie du compte | non |
| Adresse IP | oui (journaux nginx) | non (hors journaux système) | rotation des journaux | non |
| Adresse email | **seulement si le joueur la fournit** | oui | vie du compte | non |
| Empreinte de mot de passe (argon2id) | si email fourni | oui | vie du compte | non |
| Statistiques de jeu (parties, victoires, doublons, délais de tape) | oui | oui | vie du compte | classement public : **pseudo + chiffres uniquement** |
| Contenu des parties en cours | en mémoire | non | durée de la table | non |
| Localisation, contacts, téléphone, caméra, micro | **non** | — | — | — |
| Identifiants publicitaires | **non** en V1 | — | — | — |

Points sensibles à ne pas perdre de vue :

- l'**UUID d'appareil** est un identifiant technique persistant au sens du formulaire Data
  Safety → il doit être déclaré (catégorie « identifiants ») ;
- les **délais de tape** sont des données de comportement de jeu, pas des données biométriques ;
- **aucune donnée d'enfant** n'est collectée sciemment, et l'app n'est pas conçue pour être
  destinée aux enfants (§8).

## 3. Politique de confidentialité

### 3.1 Emplacements

| Emplacement | Contenu |
|---|---|
| `https://soft.opik.net/corsian-battle/privacy.html` | Texte intégral, accessible sans compte |
| Dans l'app | Lien depuis l'écran d'accueil (pictogramme) + écran « À propos / Compte » |
| Play Console | Même URL |

### 3.2 ⏳ À trancher avant publication

1. **Adresse de contact** obligatoire dans la politique (une boîte réellement lue).
2. **Responsable de traitement** : nom ou raison sociale à faire figurer.
3. Hébergeur : Scaleway (à citer nommément, avec la localisation des données : France).

### 3.3 Texte prêt à publier (à compléter des trois points ci-dessus)

```
POLITIQUE DE CONFIDENTIALITÉ — Corsian-Battle
Dernière mise à jour : [date]

1. Responsable du traitement
[Nom / raison sociale] — contact : [adresse électronique]

2. Ce que nous collectons
Corsian-Battle fonctionne sans compte obligatoire. Pour jouer en ligne, l'application crée un
profil invité composé d'un pseudo que vous choisissez et d'un identifiant technique généré par
l'application sur votre appareil. Cet identifiant ne provient d'aucun système d'exploitation et
ne permet pas de vous identifier personnellement.

Si vous souhaitez conserver votre progression sur un autre appareil, vous pouvez facultativement
rattacher une adresse électronique et un mot de passe. Le mot de passe est stocké sous forme
d'empreinte irréversible (argon2id) ; nous ne pouvons pas le lire.

Pendant le jeu, nous enregistrons des statistiques de partie : nombre de parties, victoires,
doublons réussis, temps de réaction. Ces données servent uniquement à établir votre historique
et le classement du jeu.

3. Ce que nous ne collectons pas
Aucune donnée de localisation, aucun contact, aucun contenu de votre appareil, aucune photographie,
aucun identifiant publicitaire, aucune donnée de paiement. Le contenu des parties en cours n'est
jamais écrit sur disque : il vit en mémoire le temps de la table, puis disparaît.

4. Ce qui est visible par les autres joueurs
Votre pseudo, le nombre de cartes de votre tas pendant une partie, et vos statistiques agrégées
dans le classement. Rien d'autre. Ni votre adresse électronique, ni votre identifiant d'appareil,
ni votre adresse IP ne sont visibles des autres joueurs.

5. Finalités et bases légales
Exécution du service de jeu (contractuelle) : création du profil, déroulement des parties,
classement. Intérêt légitime : prévention de la triche et des abus, sécurité du service.
Consentement : rattachement d'une adresse électronique.

6. Destinataires
Les données restent sur un serveur hébergé par Scaleway, en France. Aucun tiers n'y a accès.
Aucune donnée n'est vendue, louée, ni utilisée à des fins publicitaires. La distribution de
l'application par Google Play implique que Google traite ses propres données d'installation,
selon la politique de Google, hors de notre périmètre.

7. Durées de conservation
Profil et statistiques : jusqu'à la suppression du compte. Sessions de connexion renouvelables :
30 jours glissants. Journaux techniques du serveur web : durée de rotation de l'hébergeur.
Signalements : 90 jours après traitement.

8. Vos droits
Accès, rectification, effacement, limitation, portabilité, opposition. Vous pouvez exercer
l'ensemble de ces droits en supprimant votre compte directement depuis l'application
(Compte → Supprimer mon compte) ou depuis la page
https://soft.opik.net/corsian-battle/suppression-compte.html — la suppression est immédiate et
définitive, y compris pour l'historique de vos parties, qui est alors anonymisé.
Réclamation : CNIL (France).

9. Mineurs
Le jeu ne sollicite aucune donnée personnelle et ne propose aucune transaction. Il n'est pas
destiné aux enfants de moins de 13 ans et aucune collecte knowingly effectuée auprès d'eux
n'est prévue.

10. Sécurité
Communications chiffrées (TLS), mots de passe empreintés, jetons de session à durée limitée et
révocables, accès au serveur restreint. Aucune base de données n'est exposée sur Internet.

11. Modification de cette politique
Toute modification est publiée à cette adresse avec une date de mise à jour. Les joueurs sont
informés dans l'application lors d'un changement affectant leurs données.
```

### 3.4 Dans l'app

L'UX actuelle est volontairement **sans aucun mot** en jeu. La politique de confidentialité est
donc une exception assumée : elle passe par un écran hors-jeu (« À propos / Compte »), où du
texte est acceptable. Le lien en jeu, s'il existe, est un pictogramme.

## 4. Formulaire Data Safety — réponses préparées

| Question Play | Réponse |
|---|---|
| Collectez-vous des données ? | **Oui** |
| Identifiants (device ID) | **Oui** — collecté, stocké, chiffré en transit, non partagé, supprimable |
| Informations personnelles → adresse email | **Oui, facultative** — collectée, stockée, supprimable, non partagée |
| Nom / pseudo | **Oui** — collecté, stocké, visible des autres joueurs, supprimable |
| Activité dans l'app (statistiques de jeu) | **Oui** — collectée, stockée, supprimable |
| Localisation, contacts, SMS, photos, audio, fichiers, historique web | **Non** |
| Données de santé / financières | **Non** |
| Les données sont-elles chiffrées en transit ? | **Oui** (TLS 1.2/1.3) |
| Suppression possible sur demande ? | **Oui** — via l'app et via une page web |
| URL de suppression de compte | `https://soft.opik.net/corsian-battle/suppression-compte.html` |
| Données partagées avec des tiers ? | **Non** |
| Publicités | **Non** en V1 |

⚠️ Si AdMob est branché plus tard (`app/lib/widgets/emplacement_pub.dart` existe déjà), ce
tableau change substantiellement : identifiant publicitaire, partage avec des tiers, obligation
de recueil du consentement (UMP / GDPR message) et, pour l'Europe, conformité à la politique
européenne de Google en matière de consentement. **Décision à prendre avant, pas après.**

## 5. Suppression de compte (obligation Play)

| Voie | Parcours |
|---|---|
| Dans l'app | Compte → pictogramme corbeille → confirmation (double appui, pas de texte ambigu) → `DELETE /api/auth/compte` → retour à l'accueil en mode invité |
| Sur le web | `suppression-compte.html` : soit email + mot de passe, soit **code à 9 caractères** généré dans l'app (`POST /api/auth/compte/code`) pour les comptes invités sans email → `DELETE /api/auth/compte/code` |

Effet : effacement immédiat et irréversible des données personnelles ; les participations aux
parties des autres joueurs sont anonymisées (« Joueur ») pour ne pas trouer leur historique
(détail technique : `SCHEMA_BD.md` §6).

La page web doit être **accessible sans compte** et sans application installée — c'est
explicitement testé par les équipes de revue Play.

## 6. Contenu généré par les utilisateurs (pseudos)

Dès qu'un pseudo s'affiche à d'autres joueurs, Play considère qu'il y a contenu utilisateur.
Les quatre verrous nécessaires sont prévus dès la V1 :

1. **Filtre à la création** : liste de termes refusés, longueur ≤ 20 caractères, jeu de
   caractères restreint (lettres, chiffres, `_`, `-`, espaces simples), aucune adresse ni URL,
   normalisation (casse, accents) pour éviter les contournements.
2. **Signalement** : accessible depuis le panneau d'un adversaire en table et depuis le
   classement ; motifs fermés (`pseudo`, `comportement`, `triche`, `autre`) ; 10 / jour / joueur.
3. **Blocage** : empêche l'appariement et la rejointe d'une table commune ; liste visible et
   révocable.
4. **Traitement** : file des signalements non traités consultable par l'exploitant ; décisions
   enregistrées (`classe`, `avertissement`, `suspension`) ; suspension = refus de connexion,
   l'app reste utilisable hors ligne.

Aucun chat texte en V1 : c'est le choix qui réduit le plus le périmètre de modération.

## 7. Contraintes techniques de soumission

| Point | État |
|---|---|
| Format | **AAB** obligatoire pour une nouvelle application (l'APK ne suffit plus) |
| Signature | Keystore à générer et **conserver précieusement** ; Play App Signing recommandé |
| Niveau d'API cible | Celui imposé par Play à la date de soumission — à vérifier dans la Console, la CI est aujourd'hui en Flutter 3.24.5 / SDK 35 |
| Arbre `android/` | **Non commité** : la CI le régénère par `flutter create`. À résoudre avant toute soumission (`DEPLOIEMENT.md` §9) |
| Nom du paquet | `fr.niceescap.bataille_corse` aujourd'hui (généré par `--org fr.niceescap` + nom de projet `bataille_corse`) — **à figer définitivement avant la première publication**, il est immuable ensuite. Décision à prendre : garder `fr.niceescap.bataille_corse` ou aligner sur `fr.niceescap.corsianbattle` |
| Nom affiché sous l'icône | Encore `bataille_corse` — à remplacer par « Corsian Battle » quand `android/` sera commité |
| Icône et écran de démarrage | À produire (512×512 pour la fiche, icône adaptative pour l'app) |
| Captures | À produire depuis une vraie partie |

## 8. Classification de contenu (IARC)

Réponses attendues au questionnaire :

- Violence : aucune (cartes, aucune représentation de violence).
- Jeux d'argent : **aucun enjeu réel, aucune mise, aucune monnaie virtuelle, aucun achat** →
  pas de jeu d'argent simulé. À déclarer comme tel ; la simple présence d'un jeu de cartes ne
  suffit pas à caractériser un jeu d'argent simulé, mais la réponse doit être explicite.
- Interactions entre utilisateurs : **oui** (parties en ligne, pseudos visibles) → la
  classification inclut généralement la mention « interactions entre utilisateurs ».
- Achats intégrés : non en V1.
- Publicité : non en V1.

Positionnement recommandé : **tout public**, application **non destinée aux enfants** au sens de
la politique Famille (ne pas cocher « destiné aux enfants »), ce qui évite d'hériter des
contraintes publicitaires et de collecte renforcées de la politique Families sans bénéfice pour
ce jeu.

## 9. Publicité (AdMob) — décision en suspens

`app/lib/widgets/emplacement_pub.dart` définit déjà les formats (bannière 320×50, 320×100 sur
table, 300×250 sur accueil, leaderboard 728×90) mais **le SDK n'est pas branché** : la CI
régénère `android/`, donc `AndroidManifest.xml` ne contient pas l'App ID AdMob et
`MobileAds.initialize()` ferait plancher l'app au lancement.

Conséquences à peser avant de l'activer :

- Data Safety à reprendre entièrement (identifiant publicitaire, partage avec des tiers) ;
- consentement RGPD à recueillir (message UMP) ;
- bannières en jeu = friction avec l'UX « aucun mot, tapis carré » déjà en place ;
- un commit de l'arbre `android/` devient un prérequis.

Recommandation : publier la V1 **sans publicité**, brancher AdMob dans une version suivante une
fois l'arbre `android/` stabilisé et la fiche Play validée.

## 10. iOS — état réel

| Élément | Réalité |
|---|---|
| Compilation | **Impossible depuis noe** : il faut macOS + Xcode |
| Distribution hors App Store | **Inexistante** pour le grand public (pas de sideload équivalent à l'APK, sauf entreprise ou AltStore/jailbreak) |
| TestFlight | Nécessite un compte Apple Developer (99 $/an), un Mac pour compiler, et une revue Apple |
| App Store | Même prérequis + revue + fiche produit + politique de confidentialité (la même URL convient) |

Conséquence sur le site : l'encart iOS annonce « TestFlight — bientôt » avec un lien de recueil
d'intérêt (adresse électronique), **sans bouton de téléchargement mort**. Le protocole réseau, la
politique de confidentialité et la suppression de compte sont déjà compatibles iOS : rien à
refaire le jour où un Mac est disponible.

## 11. Site `soft.opik.net/corsian-battle/` — pages à prévoir

| Page | Contenu | Statut |
|---|---|---|
| `index.html#download` | Présentation, APK + empreinte SHA-256, lien Play, encart iOS | ⏳ existence à vérifier |
| `privacy.html` | Texte du §3.3 | à créer |
| `terms.html` | Conditions d'utilisation (licence d'usage, interdiction de triche, absence de garantie, droit applicable) | à créer |
| `suppression-compte.html` | Formulaire à deux voies (§5) | à créer |
| `support.html` | Contact, FAQ (installation d'un APK, code de table, déconnexion) | à créer |
| `#table=CODE` | Affichage du code d'invitation en très grand, consigne d'ouverture de l'app | à créer |
| `apk/` | Binaires signés | à créer |

Règle : **aucun fichier existant n'est écrasé** tant que le `ls -la` du dossier n'a pas été
fait (§10.1 de `DEPLOIEMENT.md`).
