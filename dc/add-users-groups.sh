#!/bin/bash
set -euo pipefail
# ============================================================
# add-users-groups.sh — Grupos y usuarios de la organización (AD)
#
# Requiere el DC provisionado (dc/provision.sh) y correr como root
# en el server.
#   sudo bash dc/add-users-groups.sh
#
# Es idempotente: si el usuario/grupo ya existe, no hace nada.
# ============================================================

# ---------- Grupos de seguridad de la organización ----------
# (el sufijo srv-* agrupa "servicios" y se usa en los shares)
# OJO: no usar el nombre "GROUPS": es variable reservada de bash con los
# GIDs del usuario actual y no se puede reasignar.
AD_GROUPS=(
    "admins"        # gestión del server, SSH, sudo
    "sistemas"      # soporte / mantenimiento
    "contabilidad"  # PCs Windows con software contable
    "marketing"     # PCs Windows / edición
    "oficina"       # resto de usuarios Linux
    "srv-dba"       # acceso a PostgreSQL/MariaDB
    "srv-mail"      # acceso a buzones
    "srv-files"     # acceso a recursos de archivo
)

# ---------- Usuarios iniciales ----------
# Formato: "usuario"                  → se pide la password
#          "usuario:PasswordInicial"  → crea con esa password
# Si se define AD_INITIAL_PASSWORD (lo hace install.sh), esa clave manda
# para todos los usuarios nuevos.
AD_INITIAL_PASSWORD="${AD_INITIAL_PASSWORD:-}"
USERS=(
    "joaquin:CambiarMe!2026"
    "david:CambiarMe!2026"
    "nicolas:CambiarMe!2026"
    # Usuarios de prueba (grupo2..grupo9) en "oficina"
    "grupo2:CambiarMe!2026"
    "grupo3:CambiarMe!2026"
    "grupo4:CambiarMe!2026"
    "grupo5:CambiarMe!2026"
    "grupo6:CambiarMe!2026"
    "grupo7:CambiarMe!2026"
    "grupo8:CambiarMe!2026"
    "grupo9:CambiarMe!2026"
)

# Miembros por grupo (usuario -> grupos separados por comas)
MEMBERSHIPS=(
    "joaquin:admins,sistemas,srv-files"
    "david:admins,sistemas,srv-files"
    "nicolas:admins,sistemas,srv-dba"
    "grupo2:oficina"
    "grupo3:oficina"
    "grupo4:oficina"
    "grupo5:oficina"
    "grupo6:oficina"
    "grupo7:oficina"
    "grupo8:oficina"
    "grupo9:oficina"
)

echo "==> Grupos"
GROUP_LIST=$(samba-tool group list 2>/dev/null || true)
for g in "${AD_GROUPS[@]}"; do
    if echo "$GROUP_LIST" | grep -qx "$g"; then
        echo "    ok: $g"
    else
        samba-tool group add "$g" && echo "    + $g"
    fi
done

echo "==> Usuarios"
USER_LIST=$(samba-tool user list 2>/dev/null || true)
for entry in "${USERS[@]}"; do
    user="${entry%%:*}"
    pass="${entry#*:}"
    [ "${pass}" = "${user}" ] && pass=""
    [ -n "$AD_INITIAL_PASSWORD" ] && pass="$AD_INITIAL_PASSWORD"
    if echo "$USER_LIST" | grep -qx "$user"; then
        echo "    ok: $user"
    else
        if [ -z "$pass" ]; then
            if [ -t 0 ]; then
                read -r -s -p "    Password inicial para ${user}: " pass; echo
            else
                echo "    ERROR: falta AD_INITIAL_PASSWORD y no hay TTY para pedir la clave de ${user}"
                exit 1
            fi
            [ -n "$pass" ] || { echo "    ERROR: password vacía para ${user}"; exit 1; }
        fi
        samba-tool user create "$user" "$pass" --must-change-at-next-login
        echo "    + $user"
    fi
done

echo "==> Membresías"
for entry in "${MEMBERSHIPS[@]}"; do
    user="${entry%%:*}"
    groups="${entry#*:}"
    for g in ${groups//,/ }; do
        members=$(samba-tool group listmembers "$g" 2>/dev/null || true)
        if printf '%s\n' "$members" | grep -qx "$user"; then
            echo "    ok: ${user} -> ${g}"
        else
            samba-tool group addmembers "$g" "$user"
            echo "    + ${user} -> ${g}"
        fi
    done
done

echo "==> Verificación"
echo "  Grupos:  $(samba-tool group list | wc -l)"
echo "  Usuarios: $(samba-tool user list | wc -l)"
echo "  Probar login:  sudo kinit joaquin"