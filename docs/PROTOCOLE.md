# Corsian-Battle — Protocole réseau

> Spécification du dialogue entre l'app et `corsian-jeu`. Version de protocole : **1**.
> Toute la logique de règles est décrite dans `bataille_corse/moteur.py` ; ce document ne décrit
> que son **transport**, son **rythme** et ce qui est **visible** par chaque client.

---

## 1. Transport

| Élément | Valeur |
|---|---|
| Protocole | WebSocket sur TLS (wss://) |
| URL publique | `wss://soft.opik.net/corsian-battle/ws` |
| Chemin backend | `/ws` sur `127.0.0.1:8112` (nginx strippe `/corsian-battle`) |
| Format | JSON UTF-8, un objet par message, pas de batch |
| Taille max d'un message | 8 Ko entrant, 32 Ko sortant |
| Cœur de connexion | `ping` client toutes les 25 s ; socket fermé après 75 s de silence |
| Reconnexion | Nouvelle connexion, nouveau `bonjour`, même code de table |

Le REST (`/corsian-battle/api/jeu/…`) ne sert qu'à créer une table, récupérer un code
d'invitation, consulter les statistiques et poser un signalement. **Le jeu lui-même passe
uniquement par le WebSocket.**

## 2. Enveloppes

**Serveur → client**

```json
{ "type": "carte_posee", "seq": 148, "d": { … } }
```

- `seq` : entier strictement croissant **par table**, attribué au moment de l'émission.
  Il sert à détecter les trous et à rejeter les actions périmées. Les messages de connexion
  (`bienvenue`, `erreur`, `pong`) portent `seq: 0`.

**Client → serveur**

```json
{ "type": "poser_carte", "seq_attendu": 148, "d": { } }
```

- `seq_attendu` : dernier `seq` serveur appliqué par le client. Si le serveur a déjà avancé
  au-delà, l'action est refusée (`erreur` code `coup_perime`) au lieu d'être rejouée : c'est la
  protection contre le rejeu et les doubles appuis.

Aucun champ superflu : pas d'horodatage client (inutilisable), pas d'identifiant de joueur
(déduit du socket authentifié), jamais de contenu de carte envoyé par le client.

## 3. Ouverture de session

Le jeton **n'est jamais passé en query string** (il finirait dans les journaux nginx).

```
client ──► connexion WebSocket (/ws)
client ──► {"type":"bonjour","d":{"jeton":"<JWT accès>","table":"K7M2QP","version_proto":1}}
serveur ─► {"type":"bienvenue","seq":0,"d":{"table":"K7M2QP","siege":2,"seq_courant":148}}
serveur ─► {"type":"table_etat","seq":148,"d":{…}}          ← instantané filtré (§6)
```

Délai maximal pour envoyer `bonjour` : **5 s**, sinon fermeture `4408`.

## 4. États d'une table

```
attente ──(tous les sièges prêts)──► compte_a_rebours ──(3 s)──► en_jeu ──► terminee
   ▲                                                                    │
   └────────────────── un joueur quitte avant le lancement ─────────────┘
```

| État | Ce qui se passe |
|---|---|
| `attente` | Les sièges se remplissent ; chaque arrivant envoie `pret` ; le créateur peut lancer dès que 2 sièges au moins sont occupés et prêts |
| `compte_a_rebours` | 3 s, annulé si un joueur se déconnecte |
| `en_jeu` | Distribution faite par le serveur, boucle de coups |
| `terminee` | `partie_finie` émis, la table reste ouverte 30 s pour l'affichage du bilan puis est fermée |

**Code de table** : 6 caractères, alphabet sans ambiguïté `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`
(sans `0/O`, `1/I`), tiré au sort, valable 2 h, réutilisable après fermeture. Il s'énonce
oralement aussi bien qu'il se saisit.

**Invitation sans deep link** (les App Links exigent un arbre `android/` commité, ce que la CI
ne fait pas encore) : on partage
`https://soft.opik.net/corsian-battle/#table=K7M2QP`. La page affiche le code en très grand
avec la consigne « Ouvre Corsian Battle → Rejoindre → saisis ce code ». Zéro configuration
native, fonctionne dès S2.

## 5. Messages

### 5.1 Client → serveur

| `type` | `d` | Effet |
|---|---|---|
| `bonjour` | `jeton`, `table`, `version_proto` | Ouvre la session (§3) |
| `pret` | — | Marque le siège prêt en `attente` |
| `poser_carte` | — | Joue **la carte du dessus** du siège. Le client ne désigne jamais une carte : le serveur la connaît, c'est la règle du jeu |
| `tape` | `delai_ms` (entier) | Déclare un appui sur le tapis pendant une fenêtre de doublon (§10) |
| `ping` | — | Réponse `pong` ; sert à l'estimation d'offset d'affichage |
| `quitter` | — | Libère le siège ; en `en_jeu`, un bot prend la suite |
| `signaler` | `siege`, `motif` | Enregistre un signalement (UGC, obligation Play) |
| `resynchroniser` | — | Force un nouvel `table_etat` (après trou de `seq`) |

### 5.2 Serveur → client

| `type` | Contenu public | Destiné à |
|---|---|---|
| `bienvenue` | `table`, `siege`, `seq_courant` | le client qui se connecte |
| `table_etat` | instantané complet filtré (§6) | un client (reconnexion) ou tous |
| `joueur_rejoint` | `siege`, `pseudo`, `est_bot` | tous |
| `joueur_pret` | `siege` | tous |
| `joueur_parti` | `siege`, `remplace_par_bot` | tous |
| `compte_a_rebours` | `secondes` | tous |
| `partie_lancee` | `nb_joueurs`, `taille_tas`, `nb_reste_neutre`, `premier_siege` | tous |
| `carte_posee` | `siege`, `carte`, `pli` (taille), `suivant`, `defi` (`null` ou `{poseur, repondeur, chances_restantes}`), `auto` | tous |
| `ta_carte_suivante` | `carte` | **un seul** destinataire |
| `defi_ouvert` | `poseur`, `repondeur`, `chances` | tous |
| `defi_rebondit` | `nouveau_poseur`, `repondeur`, `chances` | tous |
| `doublon_ouvert` | `fenetre_ms`, `cartes` (les deux du dessus) | tous |
| `doublon_resolu` | `gagnant`, `delai_ms_gagnant`, `personne` (bool) | tous |
| `pli_gagne` | `gagnant`, `nb_cartes`, `raison`, `reste_neutre_inclus` | tous |
| `bot_prend_la_main` | `siege` | tous |
| `partie_finie` | `gagnant`, `raison`, `stats` par siège, `duree_ms`, `nb_coups` | tous |
| `pong` | `seq_courant` | le demandeur |
| `erreur` | `code`, `message` (technique, jamais affiché tel quel à l'écran) | le fautif |

`raison` ∈ `doublon` · `defi_manque` · `victoire` · `abandon` · `partie_nulle` (garde-fou de
boucle infinie du moteur : aucune présentation « Match interrompu », mais un pictogramme de
partie nulle, conformément à l'UX déjà en place).

## 6. Instantané `table_etat`

```json
{
  "type": "table_etat", "seq": 148,
  "d": {
    "etat": "en_jeu",
    "sieges": [
      {"siege": 0, "pseudo": "Nina",  "nb_cartes": 19, "present": true, "est_bot": false},
      {"siege": 1, "pseudo": "Marc",  "nb_cartes": 12, "present": true, "est_bot": true },
      {"siege": 2, "pseudo": "moi",   "nb_cartes": 21, "present": true, "est_bot": false,
       "ma_carte": "KH"}
    ],
    "mon_siege": 2,
    "pli": ["7C", "7H"],
    "reste_neutre": 0,
    "suivant": 2,
    "defi": null,
    "fenetre_tape": null,
    "dernier_evenement": {"type": "carte_posee", "seq": 148}
  }
}
```

Règle : **chaque champ privé n'apparaît que dans la copie destinée à son propriétaire.**
`ma_carte` n'est présent que pour le siège concerné. Le pli est public ; les tas adverses ne
le sont que par leur **taille**.

## 7. Déroulé d'un coup normal

```
serveur ─► carte_posee  (le serveur a joué le coup via jouer_un_coup())
serveur ─► ta_carte_suivante   (au seul joueur dont la carte du dessus a changé)
client   : anime le vol (250-750 ms), puis affiche l'état
```

Le serveur **n'attend pas** la fin de l'animation pour accepter le coup suivant : la table
avance au rythme des intentions, chaque client joue sa propre animation. C'est ce qui permet
le tempo rapide déjà obtenu en local.

### 7.1 Tour de jeu et joueur inactif

- Délai de tour : **12 s** à partir de `carte_posee` désignant `suivant`.
- À échéance, le serveur joue la carte du dessus automatiquement et émet `carte_posee` avec
  `auto: true` (l'app affiche un léger pictogramme, pas de texte).
- Deux tours automatiques consécutifs → le siège est signalé comme inactif aux autres joueurs
  (`joueur_parti` avec `remplace_par_bot`), pour ne pas faire subir une table morte.

### 7.2 Défi (figure)

Le serveur applique le barème existant (**As 4 · Roi 3 · Dame 2 · Valet 1**) et la règle déjà
validée : seul le joueur suivant est répondeur, il pose **toutes** ses chances d'affilée, une
figure sortie fait **rebondir** le défi sur le joueur suivant avec le barème plein (non
cumulatif), l'échec attribue le pli au dernier poseur de figure.

```
serveur ─► carte_posee {carte:"AS", defi:{poseur:0, repondeur:1, chances_restantes:4}}
serveur ─► defi_ouvert {poseur:0, repondeur:1, chances:4}
client 1 ─► poser_carte  → carte_posee {…, defi:{… chances_restantes:3}}
…
serveur ─► pli_gagne {gagnant:0, raison:"defi_manque", nb_cartes:6}
```

Un joueur **sans carte** reste en jeu : il ne peut plus poser, mais il peut taper (§10). Le
champ `suivant` saute automatiquement les sièges vides, comme le fait déjà
`_prochain_index_avec_cartes()`.

## 8. Ce que le client ne reçoit jamais

- l'ordre du paquet, ni une quelconque carte à venir autre que **sa** carte du dessus ;
- le contenu des tas adverses ;
- les délais de tape des autres joueurs (sauf celui du gagnant, pour l'affichage) ;
- le `seed` du moteur (il est conservé en base pour la reproductibilité, jamais diffusé) ;
- les jetons des autres joueurs.

## 9. Rythme, latence et équité

1. **Une seule grandeur est comparée entre joueurs : une durée mesurée localement.** Chaque
   client mesure l'intervalle entre le début du rendu de l'événement (carte qui se retourne,
   doublon qui s'affiche) et l'appui du joueur. Aucune horloge murale n'est comparée.
2. `ping`/`pong` ne sert **qu'à l'affichage** (estimer un offset pour caler les animations), pas
   à l'arbitrage.
3. La latence réseau ne fausse pas l'équité du doublon : elle retarde la *réception* des
   `tape`, mais le classement se fait sur les `delai_ms` mesurés localement. Elle n'influe que
   sur le départage des égalités parfaites (ordre d'arrivée serveur).
4. Fenêtre de tape annoncée explicitement dans `doublon_ouvert` (`fenetre_ms`) pour que l'app
   borne son propre chronomètre et n'affiche pas une zone de tap au-delà du verdict.
5. La fenêtre d'équité locale (déjà calibrée en jeu hors-ligne, ~480-850 ms selon le tempo du
   joueur) est remplacée en ligne par la fenêtre serveur unique, identique pour tous.

## 10. Le doublon en ligne

### 10.1 Séquence

Le moteur résout le doublon **pendant** `jouer_un_coup()` : il n'y a pas de
place pour une attente réseau à l'intérieur du coup. Le serveur **prédit** donc
le doublon avant de jouer (il connaît le sommet du pli et la carte du dessus du
joueur dont c'est le tour), ouvre la fenêtre, puis joue avec un résolveur déjà
nourri des délais reçus.

```
t0   serveur : prédit le doublon (sommet du pli + carte du dessus du joueur)
t0   serveur ─► doublon_ouvert {fenetre_ms: 900, plancher_ms: 120, cartes:["7C","7H"]}
                à TOUS les sièges — y compris les joueurs sans carte, qui
                peuvent taper pour revenir en jeu
t0   chaque client démarre son chronomètre au début du rendu de l'animation
t1   client ─► tape {delai_ms: 214}
t2   fenêtre close à t0 + 900 ms, ou dès que tous les sièges connectés ont répondu
t3   serveur : jouer_un_coup() avec le résolveur nourri
t3   serveur ─► carte_posee {siege:3, carte:"7H", annonce:true, …}
t3   serveur ─► doublon_resolu {gagnant:2, delai_ms_gagnant:214, personne:false, nb_tapes:3}
t3   serveur ─► pli_gagne {gagnant:2, raison:"doublon", nb_cartes:9, reste_neutre_inclus:true}
```

**Deux conséquences pour le client** :

1. Pour la carte qui fait le doublon, `doublon_ouvert` arrive **avant**
   `carte_posee`. C'est `doublon_ouvert.cartes[1]` qui doit déclencher
   l'animation de la carte et le chronomètre.
2. Le `carte_posee` qui suit porte **`annonce: true`** : il ne faut **pas**
   rejouer l'animation, seulement mettre à jour l'état (tour, défi, taille du
   pli). Sans ce marquage, la carte serait animée deux fois.

Le chronomètre part donc au rendu de `doublon_ouvert` : c'est pourquoi
`proxy_buffering off` sur le WebSocket est une condition d'**équité** et non de
confort (`DEPLOIEMENT.md` §5.2).

### 10.1bis Sémantique de `pli_gagne.raison`

Deux valeurs, à ne pas confondre — l'ambiguïté a été relevée en recette du lot A :

| `raison` | Qui empoche le pli | Quand |
|---|---|---|
| `doublon` | **Celui qui a tapé le premier**, quel que soit son siège — y compris un joueur qui n'a plus de carte, qui revient ainsi en jeu | Une fenêtre de tape a abouti |
| `defi_manque` | **Le dernier poseur de figure** | Le répondeur a épuisé ses chances (ou n'a plus de carte) sans sortir de figure |

Les deux peuvent tomber sur le **même coup** : un joueur pose une carte qui
fait doublon, personne ne tape, et cette même carte épuisait la dernière chance
du défi. Le serveur émet alors `doublon_non_tape` **puis** `pli_gagne` avec
`raison: "defi_manque"` — le pli vient du défi, pas de la tape. Un client qui
afficherait « gagné par la tape » sur ce coup raconterait une fausse règle.

### 10.2 Règles de validité d'un `tape`

| Condition | Traitement |
|---|---|
| Aucune fenêtre ouverte | Message ignoré silencieusement (compté dans les limites de débit) |
| `delai_ms` < 100 | **Rejeté**, suspicion enregistrée (§8.4 de `ARCHITECTURE.md`) |
| `delai_ms` < 120 | Accepté mais marqué « sous le plancher physiologique » : ne peut pas gagner contre un délai ≥ 120 |
| `delai_ms` > `fenetre_ms` | Ignoré (le joueur est réputé n'avoir pas tapé) |
| Plusieurs `tape` du même siège dans une fenêtre | Seul le **premier** est retenu |
| Reçu après clôture de la fenêtre | Ignoré, compté comme retard réseau |

Le gagnant est le plus petit `delai_ms` **plausible** ; égalité → ordre d'arrivée serveur,
puis numéro de siège.

### 10.3 Personne ne tape

Cas réel (doublon raté par tout le monde) : le serveur émet
`doublon_resolu {personne: true}` et **le coup continue normalement** — le pli n'est attribué à
personne, la carte suivante sera posée par `suivant`, et le doublon cesse d'exister dès qu'une
nouvelle carte recouvre le pli.

⚠️ **Impact moteur** : `ResolveurTape.determiner_gagnant()` doit être autorisé à renvoyer
`None` (« personne n'a tapé »), et `_resoudre_doublon()` doit alors rendre la main sans
attribuer le pli. `ResolveurSimulationBots` ne renvoie jamais `None`, donc `demo.py` et toutes
les simulations existantes conservent un comportement strictement identique.

### 10.4 Attente bloquante ou non

Le serveur **suspend l'avancée du tour** pendant la fenêtre (au plus 900 ms) : sans cela, un
joueur pourrait poser la carte suivante et effacer le doublon avant que les autres aient eu le
temps de taper. C'est la seule attente imposée par le protocole ; elle est bornée et
perceptuellement courte.

## 11. Déconnexion, reconnexion, remplacement

| Durée d'absence | Effet |
|---|---|
| < 30 s | Siège marqué `present: false`, rien d'autre ; les `tape` de ce siège ne sont plus collectés |
| ≥ 30 s | Un bot prend le siège (`bot_prend_la_main`) ; le bot joue avec les profils de réflexe existants |
| Retour avant la fin | Le joueur récupère son siège (`table_etat`), le bot se retire ; ses statistiques restent celles d'un humain |
| Retour après la fin | La partie est consultable dans le bilan, pas de reprise |
| Jamais revenu | Le bot termine la partie ; la participation est enregistrée avec `est_bot: true` |

Le siège d'un joueur déconnecté **continue de recevoir** ses cartes : la pré-annonce
(`ta_carte_suivante`) est mise en file et délivrée à la reconnexion via `table_etat`.

## 12. Codes de fermeture WebSocket

| Code | Sens | L'app affiche |
|---|---|---|
| `4401` | Jeton absent, invalide ou expiré | Pictogramme « reconnecte-toi » → renouvelle le jeton puis rouvre |
| `4404` | Table inexistante ou expirée | Pictogramme « table introuvable » |
| `4408` | `bonjour` non reçu dans les 5 s | Reconnexion automatique une fois |
| `4409` | Table pleine | Pictogramme « complet » |
| `4410` | Message non conforme au protocole | Reconnexion + `resynchroniser` |
| `4413` | `version_proto` non prise en charge | Message « mets à jour l'app » (seul cas où du texte est acceptable) |
| `4429` | Trop de messages | Reconnexion après temporisation |
| `1011` | Erreur interne serveur | Reconnexion automatique avec recul exponentiel (1 s, 2 s, 4 s, max 30 s) |

Aucun de ces codes ne doit provoquer de perte de partie visible : la reconnexion reprend
l'instantané.

## 13. Limites et abus

| Limite | Valeur |
|---|---|
| Messages par socket | 10/s en moyenne, rafale 20 |
| Tables simultanées par processus | 200 (au-delà : `erreur` `serveur_sature`, refus de création) |
| Sièges par table | 4 (2 en duel) |
| Durée maximale d'une partie | 30 min → clôture en `partie_nulle` |
| Garde-fou du moteur | Inchangé (`max_coups`), clôture en `partie_nulle` |
| Reconnexions par siège | 10 par partie, au-delà le bot reste |

## 14. Extrait de session (transcript)

```
C ─► {"type":"bonjour","d":{"jeton":"eyJ…","table":"K7M2QP","version_proto":1}}
S ─► {"type":"bienvenue","seq":0,"d":{"table":"K7M2QP","siege":2,"seq_courant":41}}
S ─► {"type":"table_etat","seq":41,"d":{"etat":"en_jeu","mon_siege":2,…,"pli":["3D"],"suivant":2}}
S ─► {"type":"ta_carte_suivante","seq":41,"d":{"carte":"KH"}}
C ─► {"type":"poser_carte","seq_attendu":41,"d":{}}
S ─► {"type":"carte_posee","seq":42,"d":{"siege":2,"carte":"KH","pli":2,"suivant":3,
                                          "defi":{"poseur":2,"repondeur":3,"chances_restantes":3},
                                          "auto":false}}
S ─► {"type":"defi_ouvert","seq":43,"d":{"poseur":2,"repondeur":3,"chances":3}}
S ─► {"type":"carte_posee","seq":44,"d":{"siege":3,"carte":"KD","pli":3,"suivant":0,"defi":null,
                                          "auto":false}}
S ─► {"type":"doublon_ouvert","seq":45,"d":{"fenetre_ms":900,"cartes":["KH","KD"]}}
C ─► {"type":"tape","seq_attendu":45,"d":{"delai_ms":214}}
S ─► {"type":"doublon_resolu","seq":46,"d":{"gagnant":2,"delai_ms_gagnant":214,"personne":false}}
S ─► {"type":"pli_gagne","seq":47,"d":{"gagnant":2,"nb_cartes":3,"raison":"doublon",
                                        "reste_neutre_inclus":false}}
S ─► {"type":"ta_carte_suivante","seq":47,"d":{"carte":"9S"}}
```

Note de règles : `KD` après `KH` est bien un doublon (mêmes rangs, couleurs différentes) —
la priorité du doublon sur le défi en cours est respectée, comme dans le moteur.

## 15. Versionnement

- `version_proto` est annoncée dans `bonjour` ; le serveur refuse `4413` au-delà de ce qu'il
  sait servir.
- Ajout de champ = compatible (les clients ignorent l'inconnu). Retrait ou changement de
  sémantique = incrémentation de la version.
- L'app embarque la version qu'elle sait parler ; le serveur accepte une plage (V1 : `1`).
