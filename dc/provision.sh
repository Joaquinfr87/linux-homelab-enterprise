#!/bin/bash
set -euo pipefail
# ============================================================
# provision.sh — Instala y provisiona un Samba 4 AD DC (NATIVO)
#
# Requisitos previos en el server:
#   * Debian 12+ (bookworm/trixie), usuario con sudo/root
#   * IP fija 192.168.0.2  y  hostname = dc1
#   * El hostname NUNCA debe resolverse a 127.0.0.1 (requisito Samba)
#
# Uso:
#   ADMIN_PASS='...' sudo bash dc/provision.sh
#   (si no pasás ADMIN_PASS, te la pide por prompt)
# ============================================================

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Parámetros (ajustables por env) ----------
REALM="${REALM:-SUDOERS.LAN}"
DOMAIN="${DOMAIN:-sudoers.lan}"
NETBIOS="${NETBIOS:-SUDOERS}"
DC_FQDN="${DC_FQDN:-dc1}"
IP_SERVER="${IP_SERVER:-192.168.0.2}"
DNS_FORWARDER="${DNS_FORWARDER:-192.168.0.1}"

export DEBIAN_FRONTEND=noninteractive

if [ -n "${ADMIN_PASS:-}" ]; then
    ADMIN_PASS_ARG="--adminpass=${ADMIN_PASS}"
else
    read -r -s -p "Password del administrador de dominio (administrator): " ADMIN_PASS
    echo
    [ -n "${ADMIN_PASS}" ] || { echo "ERROR: password vacía."; exit 1; }
    ADMIN_PASS_ARG="--adminpass=${ADMIN_PASS}"
fi

echo "==> [1/7] hostname y /etc/hosts"
hostnamectl set-hostname "${DC_FQDN}"
# El DC debe resolverse por su IP de LAN, nunca por 127.0.0.1
sed -i "/[[:space:]]${DC_FQDN}\.${DOMAIN}/d;/[[:space:]]${DC_FQDN}[[:space:]]\?$/d" /etc/hosts
grep -qx "${IP_SERVER} ${DC_FQDN}.${DOMAIN} ${DC_FQDN}" /etc/hosts \
    || sed -i "1i ${IP_SERVER} ${DC_FQDN}.${DOMAIN} ${DC_FQDN}" /etc/hosts
if grep -q "^127\.0\.0\.1.*${DC_FQDN}" /etc/hosts; then
    sed -i "/^127\.0\.0\.1.*${DC_FQDN}/d" /etc/hosts
fi
hostnamectl set-location "${DOMAIN}" 2>/dev/null || true

echo "==> [2/7] instalando paquetes (samba, kerberos, chrony)"
apt-get update
apt-get install -y --no-install-recommends \
    samba \
    samba-ad-dc \
    samba-ad-provision \
    krb5-user \
    krb5-config \
    chrony \
    dnsutils \
    acl \
    attr \
    smbclient
# Al instalar el paquete 'samba', Debian arranca smbd/nmbd/winbind como
# server standalone y chocan con el daemon del DC. Se detienen y
# desactivan YA (el DC los maneja interno; pidfiles no deben quedar).
systemctl stop smbd nmbd winbind 2>/dev/null || true
rm -f /run/samba/smbd.pid /run/samba/nmbd.pid /run/samba/winbindd.pid
systemctl disable smbd nmbd winbind 2>/dev/null || true

echo "==> [3/7] /etc/krb5.conf"
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
EOF

echo "==> [4/7] provision del dominio"
# Si existe un smb.conf previo (p.ej. el "standalone server" que genera el
# paquete), se respalda y se retira: samba-tool exige que no exista para
# generar el del DC (server role = active directory domain controller).
if [ -f /etc/samba/smb.conf ]; then
    BAK="/etc/samba/smb.conf.bak.$(date +%Y%m%d%H%M%S)"
    mv /etc/samba/smb.conf "${BAK}"
    echo "    smb.conf previo respaldado y retirado (${BAK})"
fi

# ntlm auth: requiere FreeRADIUS (WiFi 802.1X) para MSCHAPv2 vía ntlm_auth.
samba-tool domain provision \
    --realm="${REALM}" \
    --domain="${NETBIOS}" \
    "${ADMIN_PASS_ARG}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --use-rfc2307 \
    --host-name="${DC_FQDN}" \
    --host-ip="${IP_SERVER}" \
    --option="dns forwarder = ${DNS_FORWARDER}" \
    --option="ntlm auth = mschapv2-and-ntlmv2-only"

echo "==> [5/7] recursos de archivo (shares AD)"
mkdir -p /srv/samba/departamentos /srv/samba/homes /srv/samba/respaldo
cp "${SCRIPTS_DIR}/shares.conf" /etc/samba/shares.conf
grep -qx 'include = /etc/samba/shares.conf' /etc/samba/smb.conf \
    || echo "include = /etc/samba/shares.conf" >> /etc/samba/smb.conf
chmod 1777 /srv/samba/respaldo
echo "    shares.conf incluido en /etc/samba/smb.conf"

echo "==> [6/7] servicios del DC"
# En Debian 13+ el DC corre bajo 'samba-ad-dc' (el alias 'samba' de
# versiones previas dejó de habilitarse). Escogemos el unit disponible.
SAMBA_UNIT="samba-ad-dc"
if ! systemctl list-unit-files "${SAMBA_UNIT}.service" >/dev/null 2>&1; then
    SAMBA_UNIT="samba"
fi
systemctl enable --now "${SAMBA_UNIT}"
systemctl disable --now smbd nmbd winbind 2>/dev/null || true
echo "    ${SAMBA_UNIT} activo (smbd/nmbd/winbind deshabilitados: los maneja el DC)"

echo "==> [7/7] resumen"
echo "============================================"
echo "  DC provisionado"
echo "  Realm:      ${REALM}"
echo "  DC:         ${DC_FQDN}.${DOMAIN}  (${IP_SERVER})"
echo "  DNS:        SAMBA_INTERNAL (zona ${DOMAIN})"
echo "  Compartidos: departamentos, homes, respaldo  (/srv/samba/)"
echo ""
echo "  Probar:"
echo "    sudo kinit administrator     # pedirá la password de admin"
echo "    sudo klist                   # ticket Kerberos"
echo "    smbclient -L dc1 -U administrator   # lista shares"
echo ""
echo "  Siguientes pasos:"
echo "    sudo bash dc/add-users-groups.sh"
echo "    sudo bash dc/password-policy.sh"
echo "============================================"