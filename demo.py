"""Démo : fait tourner des parties de Bataille Corse entre bots pour
valider le moteur (règles pures, sans réseau ni interface)."""
from bataille_corse import BatailleCorse


def jouer_une_partie_verbose(noms, seed=None):
    partie = BatailleCorse(noms, seed=seed)
    print(f"--- Nouvelle partie : {noms} (seed={seed}) ---")
    print(f"Cartes de reste au départ : {len(partie.cartes_reste_neutres)}")
    coups = 0
    while partie.gagnant_final() is None:
        partie.jouer_un_coup()
        coups += 1
        if coups > 200_000:
            print("Boucle trop longue, arrêt.")
            break
    gagnant = partie.gagnant_final()
    print(f"Gagnant : {gagnant.nom if gagnant else 'aucun'} en {coups} coups.")
    print("Derniers événements :")
    for ligne in partie.historique[-8:]:
        print(" ", ligne)
    print()
    return gagnant, coups


if __name__ == "__main__":
    jouer_une_partie_verbose(["Alice", "Bob"], seed=1)
    jouer_une_partie_verbose(["Alice", "Bob", "Chloé", "Denis"], seed=42)

    # Petite série pour vérifier qu'aucune partie ne boucle à l'infini
    # et que la répartition des cartes reste toujours cohérente (52).
    print("--- Série de robustesse (50 parties à 3 et 5 joueurs) ---")
    for i in range(50):
        n = 3 if i % 2 == 0 else 5
        noms = [f"J{k}" for k in range(n)]
        partie = BatailleCorse(noms, seed=1000 + i)
        gagnant = partie.jouer_partie()
        total = sum(j.nombre_cartes() for j in partie.joueurs)
        assert total == 52, f"Total de cartes incohérent : {total}"
    print("OK : 50 parties terminées, totaux de cartes toujours cohérents.")
