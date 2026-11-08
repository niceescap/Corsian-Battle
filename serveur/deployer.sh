#!/usr/bin/env bash
# Déploiement de Corsian-Battle sur la machine de production (`noe`).
#
# C'est le script qui manquait : les units systemd et les fichiers
# d'environnement étaient décrits dans `docs/DEPLOIEMENT.md`, mais **jamais
# écrits dans le dépôt** — donc jamais installés. Sans eux, le serveur ne
# tourne pas, nginx renvoie `502`, et l'app affiche « OFFLINE » : c'est
# exactement le symptôme décrit.
#
#   sudo bash serveur/deployer.sh              # installation complète
#   bash serveur/deployer.sh --verifier        # recette seule (sans sudo)
#
# Ce qu'il fait, dans l'ordre :
#   1. copie le code dans `$RACINE` (hors dépôt, hors venv) ;
#   2. crée le venv et installe les dépendances ;
#   3. génère la clé de signature RS256 **si elle n'existe pas** ;
#   4. écrit `/etc/corsian/{auth,jeu}.env` ;
#   5. installe les units systemd et les active ;
#   6. vérifie que les deux services répondent.
set -euo pipefail

RACINE="${RACINE_CORSIAN:-/home/nicee/corsian-battle}"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_SRV="${USER_SRV:-nicee}"
ORIGINE_PUBLIQUE="${ORIGINE_PUBLIQUE:-https://soft.opik.net}"
PREFIXE_PUBLIC="${PREFIXE_PUBLIC:-/corsian-battle}"
ENVIRONNEMENT="${ENVIRONNEMENT:-prod}"
VENV="$RACINE/.venv"

VERIFIER_SEUL=0
[ "${1:-}" = "--verifier" ] && VERIFIER_SEUL=1

log() { printf '\033[1;32m•\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Code
# ---------------------------------------------------------------------------
if [ "$VERIFIER_SEUL" -eq 0 ]; then
  log "Code du dépôt → $RACINE"
  sudo mkdir -p "$RACINE/app"
  # On copie le **contenu** du dépôt dans `$RACINE/app` : c'est là que les
  # units systemd travaillent (`WorkingDirectory=$RACINE/app`), et c'est là
  # que le moteur `bataille_corse/` doit se trouver — il est importé par
  # `serveur.jeu.partie`.
  sudo rsync -a --delete \
    --exclude '.git' --exclude '.venv' --exclude 'var' \
    --exclude 'sauvegardes' --exclude 'build' \
    --exclude 'app/build' \
    "$SOURCE/" "$RACINE/app/"
  sudo mkdir -p "$RACINE/var/cles" "$RACINE/sauvegardes"
  sudo chown -R "$USER_SRV:$USER_SRV" "$RACINE"

  # 2. Venv et dépendances
  log "Python : venv + dépendances"
  if [ ! -x "$VENV/bin/python" ]; then
    sudo -u "$USER_SRV" python3 -m venv "$VENV"
  fi
  sudo -u "$USER_SRV" "$VENV/bin/pip" install --upgrade pip >/dev/null
  sudo -u "$USER_SRV" "$VENV/bin/pip" install -r "$RACINE/app/serveur/requirements.txt" >/dev/null

  # 3. Clé de signature — générée UNE FOIS, jamais régénérée.
  #
  # La régénérer invaliderait tous les jetons émis : les joueurs devraient
  # se reconnecter. Elle n'est jamais dans le dépôt (`var/` est ignoré).
  if [ ! -f "$RACINE/var/cles/auth-rs256.pem" ]; then
    log "Clé de signature RS256 : génération (première installation)"
    sudo -u "$USER_SRV" openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
      -out "$RACINE/var/cles/auth-rs256.pem"
    sudo chmod 600 "$RACINE/var/cles/auth-rs256.pem"
    sudo chown "$USER_SRV:$USER_SRV" "$RACINE/var/cles/auth-rs256.pem"
  else
    log "Clé de signature : déjà présente (conservée)"
  fi

  # 4. Fichiers d'environnement
  log "Fichiers d'environnement → /etc/corsian"
  sudo mkdir -p /etc/corsian
  if [ ! -f /etc/corsian/auth.env ]; then
    sudo tee /etc/corsian/auth.env >/dev/null <<ENV
HOST=127.0.0.1
PORT=8111
ENVIRONNEMENT=$ENVIRONNEMENT
BASE_DSN=sqlite:///$RACINE/var/corsian.db
CLE_PRIVEE=$RACINE/var/cles/auth-rs256.pem
KID=2026-09
DUREE_ACCES_S=900
DUREE_REFRESH_J=30
PREFIXE_PUBLIC=$PREFIXE_PUBLIC
ORIGINE_PUBLIQUE=$ORIGINE_PUBLIQUE
ENV
  fi
  if [ ! -f /etc/corsian/jeu.env ]; then
    sudo tee /etc/corsian/jeu.env >/dev/null <<ENV
HOST=127.0.0.1
PORT=8112
ENVIRONNEMENT=$ENVIRONNEMENT
BASE_DSN=sqlite:///$RACINE/var/corsian.db
JWKS_LOCAL=http://127.0.0.1:8111/api/auth/.well-known/jwks.json
PREFIXE_PUBLIC=$PREFIXE_PUBLIC
ORIGINE_PUBLIQUE=$ORIGINE_PUBLIQUE
FENETRE_TAPE_MS=900
PLANCHER_TAPE_MS=120
DELAI_TOUR_MS=12000
GRACE_DECONNEXION_S=30
MAX_TABLES=200
ENV
  fi
  sudo chown root:"$USER_SRV" /etc/corsian/auth.env /etc/corsian/jeu.env
  sudo chmod 640 /etc/corsian/auth.env /etc/corsian/jeu.env

  # 5. Units systemd
  log "Units systemd"
  sudo cp "$RACINE/serveur/systemd/corsian-auth.service" /etc/systemd/system/
  sudo cp "$RACINE/serveur/systemd/corsian-jeu.service" /etc/systemd/system/
  sudo cp "$RACINE/serveur/systemd/corsian-sauvegarde.service" /etc/systemd/system/
  sudo cp "$RACINE/serveur/systemd/corsian-sauvegarde.timer" /etc/systemd/system/
  sudo chmod +x "$RACINE/app/serveur/sauvegarder.sh"
  sudo systemctl daemon-reload
  sudo systemctl enable --now corsian-auth corsian-jeu
  sudo systemctl enable --now corsian-sauvegarde.timer
fi

# ---------------------------------------------------------------------------
# 6. Recette
# ---------------------------------------------------------------------------
log "Recette"
FIN=0
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8111/api/auth/sante >/dev/null 2>&1; then break; fi
  sleep 1
done

verifier() {
  local url="$1" attendu="$2" nom="$3"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo 000)"
  if [ "$code" = "$attendu" ]; then
    printf '  \033[1;32mok\033[0m   %-28s %s\n' "$nom" "$code"
  else
    printf '  \033[1;31m✗\033[0m   %-28s %s (attendu %s)\n' "$nom" "$code" "$attendu"
    FIN=1
  fi
}

verifier "http://127.0.0.1:8111/api/auth/sante" 200 "auth /sante"
verifier "http://127.0.0.1:8112/api/jeu/sante" 200 "jeu /sante"
verifier "http://127.0.0.1:8112/api/jeu/config" 200 "jeu /config"
verifier "https://soft.opik.net${PREFIXE_PUBLIC}/api/auth/sante" 200 "public auth /sante"
verifier "https://soft.opik.net${PREFIXE_PUBLIC}/api/jeu/sante" 200 "public jeu /sante"

if [ "$FIN" -eq 0 ]; then
  log "Le serveur répond. L'app affiche « ONLINE »."
else
  err "Le serveur ne répond pas complètement. Voir : journalctl -u corsian-auth -u corsian-jeu -n 50"
fi
exit "$FIN"
