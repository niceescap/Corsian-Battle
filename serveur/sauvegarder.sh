#!/usr/bin/env bash
# Sauvegarde de la base : `VACUUM INTO` (copie compacte et cohérente),
# puis purge des sauvegardes de plus de 7 jours.
#
# Lancé par `corsian-sauvegarde.timer`. Réussi aussi en mode manuel :
#   bash serveur/sauvegarder.sh
set -uo pipefail

# `RACINE_CORSIAN` est la racine de l'installation (celle qui contient
# `app/` et `var/`). Le script vit dans `app/serveur/` : on remonte donc de
# deux niveaux quand la variable n'est pas fournie.
RACINE="${RACINE_CORSIAN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BASE_DSN="${BASE_DSN:-sqlite:///$RACINE/var/corsian.db}"
SAUVEGARDES="${SAUVEGARDES:-$RACINE/sauvegardes}"
JOUR="${JOUR:-$(date -u +%Y-%m-%d)}"
CONSERVER="${CONSERVER_JOURS:-7}"

mkdir -p "$SAUVEGARDES"
CIBLE="$SAUVEGARDES/corsian-$JOUR.db"

# `VACUUM INTO` écrit un fichier **complet et cohérent**, même si la base
# est en cours d'écriture (WAL) : c'est preferable à un simple `cp`.
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "${BASE_DSN#sqlite:///}" "VACUUM INTO '$CIBLE'" || exit 1
else
  echo "sqlite3 absent : sauvegarde impossible" >&2
  exit 1
fi

# Purge : on garde `CONSERVER` jours.
find "$SAUVEGARDES" -maxdepth 1 -name 'corsian-*.db' -mtime "+$CONSERVER" -delete

echo "Sauvegarde : $CIBLE ($(du -h "$CIBLE" | cut -f1))"
