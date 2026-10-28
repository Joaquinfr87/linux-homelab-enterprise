#!/bin/bash
set -euo pipefail
# ============================================================
# tls-gen.sh — CA interna + certificado wildcard para servicios/web
#
# Genera en services/web/tls/ (NO versionado, ver .gitignore):
#   ca.crt / ca.key    ← CA interna "SUDOERS.LAN CA"
#   server.crt / server.key ← cert para *.sudoers.lan
#
# Uso (EN EL SERVIDOR, dentro del repo):
#   sudo bash services/web/tls-gen.sh
#   docker compose up -d --build web
#
# Los clientes que quieran confiar en el certificado deben
# instalar ca.crt como CA de confianza del sistema.
# ============================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
TLS="$DIR/tls"
mkdir -p "$TLS"

DOMAIN="${DOMAIN:-sudoers.lan}"
HOST="${HOST:-dc1}"
DAYS_CA=3650
DAYS_SERVER=825

ALT="DNS:$DOMAIN,DNS:*.$DOMAIN,DNS:$HOST.$DOMAIN,DNS:firma.$DOMAIN,DNS:web.$DOMAIN,DNS:www.$DOMAIN,DNS:print.$DOMAIN,DNS:portainer.$DOMAIN,DNS:mail.$DOMAIN,DNS:webmail.$DOMAIN,DNS:dashboard.$DOMAIN,DNS:joaquin.$DOMAIN,DNS:david.$DOMAIN,DNS:nicolas.$DOMAIN"

# ── CA interna (se genera una sola vez) ─────────────────────
if [ ! -s "$TLS/ca.key" ]; then
    echo "=> Generando CA interna ..."
    openssl genrsa -out "$TLS/ca.key" 4096
    openssl req -new -x509 -days "$DAYS_CA" -key "$TLS/ca.key" -sha256 \
        -subj "/C=AR/O=SUDOERS.LAN/CN=SUDOERS.LAN CA" \
        -out "$TLS/ca.crt"
else
    echo "=> CA existente, se reutiliza."
fi

# ── Certificado del server (wildcard *.sudoers.lan) ─────────
echo "=> Generando certificado para *.$DOMAIN ..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "$TLS/server.key" -sha256 \
    -subj "/C=AR/O=SUDOERS.LAN/CN=*.$DOMAIN" \
    -addext "basicConstraints=CA:FALSE" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -addext "subjectAltName=$ALT" \
    -out "$TLS/server.csr"

# -copy_extensions copy: arrastra las extensiones del CSR al cert.
openssl x509 -req \
    -in "$TLS/server.csr" \
    -CA "$TLS/ca.crt" -CAkey "$TLS/ca.key" -CAcreateserial \
    -days "$DAYS_SERVER" -sha256 \
    -copy_extensions copy \
    -out "$TLS/server.crt"

rm -f "$TLS/server.csr"
chmod 600 "$TLS/ca.key" "$TLS/server.key"
chmod 644 "$TLS/ca.crt" "$TLS/server.crt"

echo "============================================"
echo "  TLS listo en $TLS/"
echo "  CA:       ca.crt (instalá en los clientes para confiar)"
echo "  Server:   server.crt / server.key  (*.$DOMAIN, $DAYS_SERVER días)"
echo "  Para aplicarlo: docker compose up -d --build web"
echo "============================================"