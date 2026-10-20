#!/usr/bin/env bash
# Démarre corsian-auth (8111) puis corsian-jeu (8112) en premier plan.
# Ctrl-C arrête les deux. Aucun systemd requis : c'est l'outil de recette
# locale (et le plus pratique depuis Termux).
#
#   bash serveur/lancer_local.sh
#   chmod +x serveur/lancer_local.sh && ./serveur/lancer_local.sh   (au choix)
#
# En production, utiliser les units systemd de docs/DEPLOIEMENT.md §4 avec
# ENVIRONNEMENT=prod, une clé générée par openssl et chmod 600.
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RACINE" || exit 1

if [ -n "${PYTHON:-}" ]; then
  PY="$PYTHON"
elif [ -x "$RACINE/.venv/bin/python" ]; then
  PY="$RACINE/.venv/bin/python"
elif [ -x "$HOME/corsian-battle/.venv/bin/python" ]; then
  PY="$HOME/corsian-battle/.venv/bin/python"
else
  PY="python3"
fi

PORT_AUTH="${PORT_AUTH:-8111}"
PORT_JEU="${PORT_JEU:-8112}"

export ENVIRONNEMENT="${ENVIRONNEMENT:-dev}"
export BASE_DSN="${BASE_DSN:-sqlite:///$RACINE/var/corsian.db}"
export CLE_PRIVEE="${CLE_PRIVEE:-$RACINE/var/cles/auth-rs256.pem}"
export JWKS_LOCAL="${JWKS_LOCAL:-http://127.0.0.1:$PORT_AUTH/api/auth/.well-known/jwks.json}"
export PREFIXE_PUBLIC="${PREFIXE_PUBLIC:-/corsian-battle}"
export ORIGINE_PUBLIQUE="${ORIGINE_PUBLIQUE:-https://soft.opik.net}"

mkdir -p "$RACINE/var/cles"

# --workers 1 est obligatoire : l'état des tables vit dans le processus.
OPTS=(--workers 1 --proxy-headers --forwarded-allow-ips 127.0.0.1 --log-level info)

echo "• python : $PY"
echo "• base   : $BASE_DSN"
echo "• clé    : $CLE_PRIVEE"
echo "• auth   : 127.0.0.1:$PORT_AUTH    jeu : 127.0.0.1:$PORT_JEU"
echo

"$PY" -m uvicorn serveur.auth.main:app --host 127.0.0.1 --port "$PORT_AUTH" "${OPTS[@]}" &
PID_AUTH=$!

# corsian-jeu lit le JWKS de l'auth au premier jeton vérifié : on attend que
# l'auth réponde avant de démarrer le jeu, pour un démarrage propre en une
# seule commande.
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:$PORT_AUTH/api/auth/sante" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

"$PY" -m uvicorn serveur.jeu.main:app --host 127.0.0.1 --port "$PORT_JEU" "${OPTS[@]}" &
PID_JEU=$!

arret() {
  echo
  echo "• arrêt des services…"
  kill "$PID_AUTH" "$PID_JEU" 2>/dev/null || true
  wait "$PID_AUTH" "$PID_JEU" 2>/dev/null || true
}
trap arret INT TERM EXIT

cat <<RECETTE

Recette immédiate :
  curl -s 127.0.0.1:$PORT_AUTH/api/auth/sante | python3 -m json.tool
  curl -s 127.0.0.1:$PORT_JEU/api/jeu/sante   | python3 -m json.tool
  curl -s 127.0.0.1:$PORT_JEU/api/jeu/config  | python3 -m json.tool

Compte invité puis table de duel :
  curl -s -X POST 127.0.0.1:$PORT_AUTH/api/auth/invite \\
       -H 'Content-Type: application/json' \\
       -d '{"uuid_appareil":"termux-0001","pseudo":"Nina","plateforme":"test"}'

Ctrl-C pour tout arrêter.
RECETTE

wait
