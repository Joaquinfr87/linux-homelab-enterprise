#!/bin/bash
# ===================================================================
# ssh-apply.sh — aplica server/sshd_config de forma segura
#
# GUÍA DE USO
# -----------
#   sudo bash server/ssh-apply.sh            # aplica y reinicia ssh
#   sudo bash server/ssh-apply.sh --dry-run  # valida y muestra, no aplica
#   bash server/ssh-apply.sh --help          # esta ayuda
#
# QUÉ HACE
# --------
#   1. Respalda /etc/ssh/sshd_config (sshd_config.bak.<fecha>).
#   2. Copia la versión del repo, pero comenta los `ListenAddress` cuya IP
#      NO existe en el host: si no, sshd no arranca y perdés el acceso
#      (y `sshd -t` no detecta ese caso).
#   3. Valida con `sshd -t` ANTES de tocar el servicio.
#   4. Reinicia ssh y muestra la configuración efectiva (`sshd -T`).
#
# IMPORTANTE
#   - Reiniciar ssh NO corta las sesiones ya abiertas: podés aplicar esto
#     estando conectado. Si algo sale mal, la sesión actual sigue viva y
#     podés restaurar el respaldo.
#   - El acceso remoto queda por CONTRASEÑA (PubkeyAuthentication no); el
#     origen se restringe por firewall (admin_ips + ADMIN_IPS_EXTRA en .env).
#   - Rollback manual:
#       sudo cp /etc/ssh/sshd_config.bak.<fecha> /etc/ssh/sshd_config
#       sudo systemctl restart ssh
# ===================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        -h|--help)  awk 'f && /^# =====/{exit} f{sub(/^# ?/,""); print} /^# =====/{f=1}' "$0"; exit 0 ;;
        --dry-run)  DRY_RUN=1 ;;
        *) echo "Opción desconocida: $arg (usá --help)" >&2; exit 2 ;;
    esac
done

log()  { printf '    %s\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "ejecutar con sudo (root)"
[[ -f "$DIR/sshd_config" ]] || die "no existe $DIR/sshd_config"

echo "==> Respaldo y preparación de sshd_config ..."
TS="$(date +%Y%m%d%H%M%S)"
if [[ -f /etc/ssh/sshd_config ]]; then
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$TS"
    log "respaldo: /etc/ssh/sshd_config.bak.$TS"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
LOCAL_IPS="$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)"
MISSING=""
while IFS= read -r LINE; do
    if [[ "$LINE" =~ ^[[:space:]]*ListenAddress[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        LIP="${BASH_REMATCH[1]}"
        if printf '%s\n' "$LOCAL_IPS" | grep -Fxq "$LIP"; then
            printf '%s\n' "$LINE"
        else
            printf '# [ssh-apply] omitida: %s no existe en este host\n# %s\n' "$LIP" "$LINE"
            MISSING="$MISSING $LIP"
        fi
    else
        printf '%s\n' "$LINE"
    fi
done < "$DIR/sshd_config" > "$TMP"

if [[ -n "$MISSING" ]]; then
    log "ListenAddress omitidas (IP inexistente):$MISSING"
fi

echo "==> Validando sintaxis (sshd -t) ..."
if ! sshd -t -f "$TMP"; then
    die "sshd -t falló: NO se aplica nada (tu sesión sigue intacta)"
fi
log "sintaxis OK"

if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] no se copia ni se reinicia. Config resultante:"
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$TMP" | sed 's/^/      /'
    exit 0
fi

echo "==> Aplicando y reiniciando ssh ..."
cp "$TMP" /etc/ssh/sshd_config
if ! systemctl restart ssh; then
    echo "ERROR: ssh no reinició. Restaurando respaldo ..." >&2
    cp -a "/etc/ssh/sshd_config.bak.$TS" /etc/ssh/sshd_config
    systemctl restart ssh || true
    die "se restauró la config anterior (revisá: journalctl -u ssh -n 50)"
fi
log "ssh reiniciado"

echo "==> Configuración efectiva:"
sshd -T 2>/dev/null | grep -E '^(port|listenaddress|passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication|usepam|allowusers|x11forwarding|maxauthtries|usedns) ' | sed 's/^/      /'

cat <<EOF

────────────────────────────────────────────────────────────
SSH aplicado. Conectate desde la LAN:
    ssh joaquin@192.168.0.2

  * Autenticación: SOLO contraseña (claves deshabilitadas).
  * El firewall limita el origen: admin_ips (.50–.52) + ADMIN_IPS_EXTRA
    de .env. Si cambiás de IP, agregala y volvé a correr
    server/deploy.sh (o bootstrap.sh).
  * Rollback: sudo cp /etc/ssh/sshd_config.bak.$TS /etc/ssh/sshd_config
              sudo systemctl restart ssh
────────────────────────────────────────────────────────────
EOF
