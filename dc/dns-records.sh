#!/bin/bash
set -euo pipefail

# ===================================================================
# dc/dns-records.sh — Registros A de servicios públicos (idempotente).
#
# Crea/verifica en el DNS AD los nombres que publican servicios internos.
# Los servicios de admins apuntan al proxy (192.168.0.2); Zabbix es
# una excepción y apunta directamente a su servidor (192.168.0.3).
#
# USAR el nombre del DC (no 127.0.0.1): samba-tool dns contra loopback
# falla al bindear el RPC (NT_STATUS_INVALID_PARAMETER en el puerto
# dinámico). Con dc1.sudoers.lan (~192.168.0.2) no da ese problema.
#
# Uso (EN EL DC, con ticket Kerberos de administrador):
#   sudo kinit administrator        # pide el password una sola vez
#   sudo bash dc/dns-records.sh
#
# Guía de publicación: docs/publicar-servicios-admin.md
# ===================================================================

SERVER="dc1.sudoers.lan"
ZONE="sudoers.lan"
PROXY_IP="192.168.0.2"
ZABBIX_IP="192.168.0.3"

ensure_a() {
    local host="$1"
    local target_ip="$2"
    local old_ip="${3:-}"
    local query=""
    local out=""

    query="$(samba-tool dns query "$SERVER" "$ZONE" "$host" A --use-kerberos=required 2>/dev/null || true)"

    if printf '%s\n' "$query" | grep -Fqs "$target_ip"; then
        echo "  ok    $host.$ZONE  →  $target_ip  (ya existe)"
        return
    fi

    if [ -n "$old_ip" ] && printf '%s\n' "$query" | grep -Fqs "$old_ip"; then
        out="$(samba-tool dns update "$SERVER" "$ZONE" "$host" A "$old_ip" "$target_ip" --use-kerberos=required 2>&1)" || {
            echo "  ERROR al actualizar $host.$ZONE:"
            printf '%s\n' "$out"
            exit 1
        }
        echo "  ok    $host.$ZONE  →  $target_ip  (actualizado)"
        return
    fi

    if [ -n "$query" ]; then
        echo "  ERROR: $host.$ZONE ya existe con otro valor:"
        printf '%s\n' "$query"
        exit 1
    fi

    out="$(samba-tool dns add "$SERVER" "$ZONE" "$host" A "$target_ip" --use-kerberos=required 2>&1)" || {
        echo "  ERROR al crear $host.$ZONE:"
        printf '%s\n' "$out"
        exit 1
    }
    echo "  ok    $host.$ZONE  →  $target_ip  (creado)"
}

echo "==> Servicios del DC y web (via proxy) ..."
ensure_a mail "$PROXY_IP" "$PROXY_IP"
ensure_a webmail "$PROXY_IP" "$PROXY_IP"
ensure_a archivos "$PROXY_IP" "$PROXY_IP"
ensure_a firma "$PROXY_IP" "$PROXY_IP"
ensure_a grafana "$PROXY_IP" "$PROXY_IP"
ensure_a david "$PROXY_IP" "$PROXY_IP"
ensure_a nicolas "$PROXY_IP" "$PROXY_IP"

echo "==> Zabbix (acceso directo) ..."
ensure_a zabbix "$ZABBIX_IP" "$PROXY_IP"

echo
echo "Listo. Verificar con: dig firma.sudoers.lan / dig mail.sudoers.lan / dig webmail.sudoers.lan / dig archivos.sudoers.lan / dig grafana.sudoers.lan / dig david.sudoers.lan / dig nicolas.sudoers.lan / dig zabbix.sudoers.lan"
