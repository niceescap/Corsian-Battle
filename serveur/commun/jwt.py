"""Jetons : RS256 signé par corsian-auth, vérifié par corsian-jeu via JWKS.

Pourquoi une paire asymétrique plutôt qu'un secret partagé :

- `corsian-jeu` ne possède **que la clé publique** ; une compromission du
  service de jeu ne permet donc pas de forger des jetons ;
- la rotation de clé se fait en publiant un nouveau `kid`, l'ancien restant
  au JWKS le temps que les jetons émis expirent (30 jours maxi).

Le JWKS n'est servi que sur `127.0.0.1` : il n'est **pas** exposé par nginx
(`docs/ENDPOINTS.md` §3.10).

En `dev`, une clé absente est générée au démarrage pour permettre un premier
lancement sans manipulation ; en `prod`, l'absence de clé est une erreur
bloquante (`charger_ou_generer_cle`).
"""
from __future__ import annotations

import base64
import hashlib
import logging
import os
import secrets
import time
from typing import Any, Dict, Optional, Tuple

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from serveur.commun.config import AUDIENCE, EMETTEUR

ALGORITHME = "RS256"
TAILLE_CLE_BITS = 2048
journal = logging.getLogger("corsian.jwt")


class ErreurJeton(Exception):
    """Jeton absent, malformé, expiré ou signé par une clé inconnue."""

    def __init__(self, code: str = "jeton_invalide", message: str = "Session expirée.") -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# ---------------------------------------------------------------------------
# Clés
# ---------------------------------------------------------------------------
def charger_ou_generer_cle(chemin: str, environnement: str = "dev") -> bytes:
    """Renvoie la clé privée au format PEM, en la générant si besoin en dev."""
    if chemin and os.path.exists(chemin):
        with open(chemin, "rb") as fichier:
            return fichier.read()
    if environnement == "prod":
        raise RuntimeError(
            f"Clé de signature absente : {chemin or '(CLE_PRIVEE non renseigné)'}. "
            "Générez-la puis passez-la en 600 :\n"
            "  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out <chemin>\n"
            "  chmod 600 <chemin>"
        )
    cle = rsa.generate_private_key(public_exponent=65537, key_size=TAILLE_CLE_BITS)
    pem = cle.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    dossier = os.path.dirname(os.path.abspath(chemin)) if chemin else ""
    if dossier:
        os.makedirs(dossier, exist_ok=True)
    with open(chemin, "wb") as fichier:
        fichier.write(pem)
    os.chmod(chemin, 0o600)
    journal.warning(
        "Clé de signature de développement générée dans %s (environnement=%s). "
        "Ne jamais faire cela en production.",
        chemin,
        environnement,
    )
    return pem


def cle_publique(pem_prive: bytes) -> Any:
    return serialization.load_pem_private_key(pem_prive, password=None).public_key()


def _b64url(nombre: int) -> str:
    longueur = (nombre.bit_length() + 7) // 8
    return base64.urlsafe_b64encode(nombre.to_bytes(longueur, "big")).decode("ascii").rstrip("=")


def jwks(pem_prive: bytes, kid: str) -> Dict[str, Any]:
    """Jeu de clés publiques au format RFC 7517, servi par corsian-auth."""
    nombres = cle_publique(pem_prive).public_numbers()
    return {
        "keys": [
            {
                "kty": "RSA",
                "kid": kid,
                "use": "sig",
                "alg": ALGORITHME,
                "n": _b64url(nombres.n),
                "e": _b64url(nombres.e),
            }
        ]
    }


# ---------------------------------------------------------------------------
# Émission (corsian-auth uniquement)
# ---------------------------------------------------------------------------
def emettre_acces(
    pem_prive: bytes, kid: str, joueur_id: str, pseudo: str, duree_s: int
) -> str:
    instant = int(time.time())
    contenu = {
        "sub": joueur_id,
        "pseudo": pseudo,
        "typ": "acces",
        "iss": EMETTEUR,
        "aud": AUDIENCE,
        "iat": instant,
        "nbf": instant,
        "exp": instant + max(int(duree_s), 1),
    }
    return jwt.encode(contenu, pem_prive, algorithm=ALGORITHME, headers={"kid": kid})


def emettre_refresh() -> Tuple[str, str]:
    """Renvoie `(jeton_opaque, empreinte_sha256)`.

    Seul le jeton repart vers l'app ; la base ne conserve que l'empreinte
    (`docs/SCHEMA_BD.md` §3) : une fuite de base ne permet pas d'usurper une
    session.
    """
    jeton = "rt_" + secrets.token_urlsafe(32)
    return jeton, empreinte(jeton)


def empreinte(jeton: str) -> str:
    return hashlib.sha256(jeton.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Vérification
# ---------------------------------------------------------------------------
def verifier_acces(jeton: str, cle: Any) -> Dict[str, Any]:
    """Vérifie un jeton d'accès avec une clé publique déjà chargée."""
    if not jeton:
        raise ErreurJeton("jeton_absent", "Authentification requise.")
    try:
        contenu = jwt.decode(
            jeton,
            cle,
            algorithms=[ALGORITHME],
            audience=AUDIENCE,
            issuer=EMETTEUR,
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.ExpiredSignatureError as erreur:
        raise ErreurJeton("jeton_expire", "Session expirée.") from erreur
    except jwt.PyJWTError as erreur:
        raise ErreurJeton("jeton_invalide", "Session invalide.") from erreur
    if contenu.get("typ") != "acces":
        raise ErreurJeton("jeton_invalide", "Type de jeton refusé.")
    return contenu


class VerificateurJwks:
    """Vérification côté `corsian-jeu`, sans jamais posséder la clé privée.

    Les clés sont mises en cache par PyJWT (durée de vie par défaut 5 min),
    donc l'absence temporaire de `corsian-auth` ne casse pas les parties en
    cours — comportement décrit dans `docs/ARCHITECTURE.md` §9.
    """

    def __init__(self, url: str) -> None:
        self.url = url
        self._client: Optional[jwt.PyJWKClient] = None

    @property
    def client(self) -> jwt.PyJWKClient:
        if self._client is None:
            self._client = jwt.PyJWKClient(self.url, cache_keys=True)
        return self._client

    def verifier(self, jeton: str) -> Dict[str, Any]:
        if not jeton:
            raise ErreurJeton("jeton_absent", "Authentification requise.")
        try:
            cle = self.client.get_signing_key_from_jwt(jeton).key
        except jwt.PyJWKClientError as erreur:
            raise ErreurJeton("cle_indisponible", "Service d'authentification injoignable.") from erreur
        except jwt.PyJWTError as erreur:
            raise ErreurJeton("jeton_invalide", "Session invalide.") from erreur
        return verifier_acces(jeton, cle)


def extraire_porteur(entete: Optional[str]) -> str:
    """`Authorization: Bearer xyz` → `xyz` (vide si absent ou malformé)."""
    if not entete:
        return ""
    parties = entete.split(None, 1)
    if len(parties) != 2 or parties[0].lower() != "bearer":
        return ""
    return parties[1].strip()
