#!/bin/bash
# ===================================================================
# bootstrap.sh — deja dc1 operativo de punta a punta (Debian 12/13)
#
# GUÍA DE USO
# -----------
#   sudo bash install.sh                       # instala/provisiona/aplica todo (incluye IDS/IPS)
#   sudo bash install.sh --check               # solo diagnostica, no cambia nada
#   sudo bash install.sh --ips                 # instala y activa modo IPS en línea (bloqueo)
#   sudo bash install.sh --skip-ids            # sin instalar Suricata (IDS/IPS)
#   sudo bash install.sh --skip-ad             # sin provisionar el AD (ya existe)
#   sudo bash install.sh --set-ip              # auto-configura la IP fija 192.168.0.2
#   sudo bash install.sh -i <interfaz>         # fuerza la interfaz de red (ej. eth0, eno1)
#   sudo bash install.sh --yes                 # sin confirmaciones (desatendido)
#   bash install.sh --help                     # esta ayuda
#
# Es IDEMPOTENTE: detecta lo que ya está hecho y no lo repite. Se puede
# correr las veces que haga falta (por ejemplo después de un git pull).
#
# QUÉ HACE (en orden)
# -------------------
#   1. Preflight: root, IP fija .2, gateway, DNS, disco, RAM, docker.
#   2. Identidad: hostname dc1, /etc/hosts (sin 127.0.1.1), TZ Buenos Aires.
#   3. Paquetes base: samba(-ad-dc/-ad-provision), krb5, chrony, dnsutils,
#      acl/attr, smbclient, freeradius(+utils), restic, openssl, curl,
#      suricata(+update), jq.
#   4. NTP: chrony con server/chrony.conf, systemd-timesyncd deshabilitado.
#   5. .env: server/gen-env.sh (secretos) + ADMIN_IPS_EXTRA con la IP desde
#      la que estás conectado (para no perder el SSH al aplicar el firewall).
#   6. AD: dc/provision.sh si no está provisionado, luego
#      dc/add-users-groups.sh y dc/password-policy.sh.
#   7. DNS local: /etc/resolv.conf → 127.0.0.1 (Samba) y verificación.
#   8. TLS del proxy + server/deploy.sh (firewall, sshd, chrony, RADIUS,
#      docker compose up -d --build).
#   9. Seguridad de red: IDS / IPS (Suricata con homelab.rules y alternador en caliente).
#  10. Verificación: servicios nativos, contenedores, puertos, DNS, NTP y reporte final.
#
# PENDIENTE DESPUÉS (manual, no lo puede hacer este script)
# --------------------------------------------------------
#   * APAGAR el DHCP del router TP-Link (si no, dos DHCP en la LAN).
#   * Router → Wireless → WPA2-Enterprise: RADIUS 192.168.0.2:1812,
#     password = RADIUS_SECRET de .env (ver clients/wifi.md).
#   * Registrar A de servicios si hace falta: sudo kinit administrator &&
#     sudo bash dc/dns-records.sh  (ver docs/publicar-servicios-admin.md).
#   * Clientes al dominio: clients/linux.md y clients/windows.md.
#
# SI ALGO SALE MAL
#   * SSH: deploy.sh comenta los ListenAddress que no existen en el host y
#     respalda sshd_config en /etc/ssh/sshd_config.bak.<ts>.
#   * Firewall: sudo nft list ruleset | menos; sudo nft flush table inet filter
#     para desactivar temporalmente (vuelve a aplicar con deploy.sh).
#   * Backup del smb.conf previo al provision: /etc/samba/smb.conf.bak.<ts>.
#   * Los secretos generados quedan en .env (chmod 600, en .gitignore).
# ===================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
HTTPS_URL="https://dc1.sudoers.lan"

CHECK_ONLY=0
SKIP_AD=0
ASSUME_YES=0
AUTO_SET_IP=0
ENABLE_IPS=0
SKIP_IDS=0
IFACE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)  awk 'f && /^# =====/{exit} f{sub(/^# ?/,""); print} /^# =====/{f=1}' "$0"; exit 0 ;;
        --check)    CHECK_ONLY=1; shift ;;
        --skip-ad)  SKIP_AD=1; shift ;;
        --skip-ids) SKIP_IDS=1; shift ;;
        --ips)      ENABLE_IPS=1; shift ;;
        --set-ip)   AUTO_SET_IP=1; shift ;;
        -y|--yes)   ASSUME_YES=1; shift ;;
        -i|--iface|--interface)
            [[ $# -ge 2 ]] || die "falta el argumento para $1"
            IFACE_ARG="$2"; shift 2 ;;
        --iface=*|--interface=*)
            IFACE_ARG="${1#*=}"; shift ;;
        *) echo "Opción desconocida: $1 (usá --help)" >&2; exit 2 ;;
    esac
done

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [[ $CHECK_ONLY -eq 1 ]]; then info "[check] $*"; else "$@"; fi; }

# ─── Variables de red (alineadas con .env) ──────────────────────────
HOST_IP="192.168.0.2"
GATEWAY="192.168.0.1"
DOMAIN="sudoers.lan"
DC_FQDN="dc1"

detect_default_iface() {
    # 1. Flag explícito o variable de entorno
    if [[ -n "${IFACE_ARG:-}" ]]; then
        if ip link show "$IFACE_ARG" >/dev/null 2>&1; then
            echo "$IFACE_ARG"
            return 0
        else
            warn "la interfaz '$IFACE_ARG' especificada no existe en este host." >&2
        fi
    fi
    if [[ -n "${IFACE:-}" ]] && ip link show "$IFACE" >/dev/null 2>&1; then
        echo "$IFACE"
        return 0
    fi

    # 2. .env si ya define DHCP_INTERFACE
    if [[ -f "$ROOT/.env" ]]; then
        local env_iface
        env_iface="$(grep -E '^DHCP_INTERFACE=' "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "\"\' ")"
        if [[ -n "$env_iface" && "$env_iface" != "*" ]] && ip link show "$env_iface" >/dev/null 2>&1; then
            echo "$env_iface"
            return 0
        fi
    fi

    # 3. Interfaz con ruta hacia GATEWAY (192.168.0.1)
    local cand=""
    cand="$(ip -o -4 route get "$GATEWAY" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
    if [[ -n "$cand" ]] && ip link show "$cand" >/dev/null 2>&1; then
        echo "$cand"
        return 0
    fi

    # 4. Interfaz con ruta default
    cand="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    if [[ -z "$cand" ]]; then
        cand="$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null || true)"
    fi
    if [[ -n "$cand" ]] && ip link show "$cand" >/dev/null 2>&1; then
        echo "$cand"
        return 0
    fi

    # 5. Interfaz con IP en la misma subred (192.168.0.X)
    cand="$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^192\.168\.0\./ {print $2; exit}')"
    if [[ -n "$cand" ]] && ip link show "$cand" >/dev/null 2>&1; then
        echo "$cand"
        return 0
    fi

    # 6. Primera interfaz física no virtual
    for d in /sys/class/net/*; do
        [[ -d "$d" ]] || continue
        local name
        name="$(basename "$d")"
        [[ -d "$d/device" ]] || continue
        [[ "$name" =~ ^(lo|docker|veth|br-|virbr|tun|tap|tailscale|wg) ]] && continue
        local state carrier
        state="$(cat "$d/operstate" 2>/dev/null || true)"
        carrier="$(cat "$d/carrier" 2>/dev/null || true)"
        if [[ "$state" == "up" || "$carrier" == "1" ]]; then
            echo "$name"
            return 0
        fi
    done

    for d in /sys/class/net/*; do
        [[ -d "$d" ]] || continue
        local name
        name="$(basename "$d")"
        [[ -d "$d/device" ]] || continue
        [[ "$name" =~ ^(en|eth) ]] && { echo "$name"; return 0; }
    done

    for d in /sys/class/net/*; do
        [[ -d "$d" ]] || continue
        local name
        name="$(basename "$d")"
        [[ -d "$d/device" ]] || continue
        [[ "$name" =~ ^(lo|docker|veth|br-|virbr) ]] && continue
        echo "$name"
        return 0
    done

    echo ""
}

IFACE_DEF="$(detect_default_iface)"

if [[ $CHECK_ONLY -eq 0 && $EUID -ne 0 ]]; then
    die "hay que ejecutarlo como root:  sudo bash server/bootstrap.sh"
fi

# ===================================================================
# 1. Preflight
# ===================================================================
log "[1/10] Preflight"
[[ -f "$ROOT/docker-compose.yml" ]] || die "no encuentro $ROOT/docker-compose.yml"
[[ -f "$ROOT/.env.example" ]]       || die "falta .env.example en $ROOT"
ok "repo en $ROOT"

CUR_IPS="$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)"
if printf '%s\n' "$CUR_IPS" | grep -Fxq "$HOST_IP"; then
    HOST_IP_IFACE="$(ip -o -4 addr show to "$HOST_IP" 2>/dev/null | awk '{print $2; exit}')"
    ok "IP $HOST_IP presente en ${HOST_IP_IFACE:-$IFACE_DEF}"
elif [[ $CHECK_ONLY -eq 1 ]]; then
    warn "la IP $HOST_IP NO está configurada (IPs: $(echo $CUR_IPS | tr '\n' ' '))"
    warn "se configuraría con:  sudo bash server/set-ip.sh --yes --commit ${IFACE_DEF:+--iface $IFACE_DEF}"
else
    warn "la IP $HOST_IP NO está configurada en este host (IPs: $(echo $CUR_IPS | tr '\n' ' '))."
    SET_IP_CMD=(bash "$DIR/set-ip.sh" --yes --commit)
    [[ -n "$IFACE_DEF" ]] && SET_IP_CMD+=(--iface "$IFACE_DEF")
    if [[ $AUTO_SET_IP -eq 1 ]]; then
        info "configurando IP fija $HOST_IP en ${IFACE_DEF:-interfaz auto-detectada}..."
        "${SET_IP_CMD[@]}"
    elif [[ $ASSUME_YES -eq 0 ]]; then
        read -rp "    ¿Deseás configurar la IP fija $HOST_IP ahora usando server/set-ip.sh? [s/N] " ans_ip
        case "$ans_ip" in
            s|S|si|SI|sí|SÍ)
                "${SET_IP_CMD[@]}"
                ;;
            *)
                die "El DC se provisiona con --host-ip=$HOST_IP. Sin ella el AD queda roto. Aplicá primero: sudo bash server/set-ip.sh --yes --commit ${IFACE_DEF:+--iface $IFACE_DEF}"
                ;;
        esac
    else
        die "la IP $HOST_IP NO está configurada. Pasá --set-ip para configurarla automáticamente o aplicá: sudo bash server/set-ip.sh --yes --commit ${IFACE_DEF:+--iface $IFACE_DEF}"
    fi

    # Verificar que la IP haya quedado aplicada
    CUR_IPS="$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)"
    if printf '%s\n' "$CUR_IPS" | grep -Fxq "$HOST_IP"; then
        HOST_IP_IFACE="$(ip -o -4 addr show to "$HOST_IP" 2>/dev/null | awk '{print $2; exit}')"
        IFACE_DEF="${HOST_IP_IFACE:-$IFACE_DEF}"
        ok "IP $HOST_IP configurada y verificada en $IFACE_DEF"
    else
        die "no se pudo verificar la IP $HOST_IP tras ejecutar server/set-ip.sh"
    fi
fi

if ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then ok "gateway $GATEWAY responde"
else warn "el gateway $GATEWAY no responde (¿bridge de la VM?)"; fi

if getent hosts deb.debian.org >/dev/null 2>&1; then ok "DNS/Internet OK"
else warn "sin resolución DNS externa: los 'apt install' y los pulls de Docker pueden fallar"; fi

AVAIL_KB="$(df --output=avail / | tail -1 | tr -d ' ')"
if [[ "${AVAIL_KB:-0}" -lt 5242880 ]]; then
    warn "quedan $((AVAIL_KB/1024)) MB libres en / (recomendado > 5 GB para imágenes Docker)"
else
    ok "disco libre: $((AVAIL_KB/1024/1024)) GB"
fi
info "RAM: $(free -m | awk '/^Mem:/{print $2}') MB — $(( $(free -m | awk '/^Mem:/{print $7}') )) MB disponibles"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        warn "docker o docker-compose no detectados (se instalarían en ejecución normal)"
    else
        info "docker o docker-compose no detectados. Instalando paquetes oficiales..."
        env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io docker-compose-v2
        systemctl enable --now docker
        ok "docker y docker compose instalados"
    fi
else
    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') + compose"
fi

if [[ -f /var/lib/samba/private/sam.ldb ]]; then
    ok "AD ya provisionado"
    AD_READY=1
else
    info "AD sin provisionar (se hará en el paso 6)"
    AD_READY=0
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    info "modo --check: no se modifica nada"
fi

# ===================================================================
# 2. Identidad del host
# ===================================================================
log "[2/10] Identidad del host"
if [[ "$(hostname -s)" != "$DC_FQDN" ]]; then
    run hostnamectl set-hostname "$DC_FQDN"
    info "hostname → $DC_FQDN"
else
    ok "hostname ya es $DC_FQDN"
fi

if [[ $CHECK_ONLY -eq 0 ]]; then
    cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    # Samba exige que el nombre del DC NO resuelva a 127.0.0.1 ni 127.0.1.1.
    sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
    sed -i "\|${DC_FQDN}\.${DOMAIN}|d" /etc/hosts
    sed -i "\|^${HOST_IP}[[:space:]]|d" /etc/hosts
    # El hostname tiene que ir primero en /etc/hosts para que getent lo devuelva.
    sed -i "1i ${HOST_IP} ${DC_FQDN}.${DOMAIN} ${DC_FQDN}" /etc/hosts
fi
if getent hosts "$DC_FQDN.$DOMAIN" 2>/dev/null | grep -q "$HOST_IP"; then
    ok "$DC_FQDN.$DOMAIN → $HOST_IP"
else
    warn "$DC_FQDN.$DOMAIN no resuelve a $HOST_IP en /etc/hosts"
fi

run timedatectl set-timezone America/Argentina/Buenos_Aires
ok "timezone: $(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"

# ===================================================================
# 3. Paquetes base
# ===================================================================
log "[3/10] Paquetes base"
PKGS=()
command -v samba-tool       >/dev/null || PKGS+=(samba samba-ad-dc samba-ad-provision)
command -v kinit            >/dev/null || PKGS+=(krb5-user krb5-config)
command -v chronyd          >/dev/null || PKGS+=(chrony)
command -v dig              >/dev/null || PKGS+=(dnsutils)
command -v smbclient        >/dev/null || PKGS+=(smbclient)
command -v setfacl          >/dev/null || PKGS+=(acl)
command -v attr             >/dev/null || PKGS+=(attr)
command -v ntlm_auth        >/dev/null || PKGS+=(samba-common-bin)
command -v restic           >/dev/null || PKGS+=(restic)
command -v freeradius       >/dev/null || PKGS+=(freeradius)
command -v radclient        >/dev/null || PKGS+=(freeradius-utils)
command -v nft              >/dev/null || PKGS+=(nftables)
command -v curl             >/dev/null || PKGS+=(curl)
command -v openssl          >/dev/null || PKGS+=(openssl)
if [[ $SKIP_IDS -eq 0 ]]; then
    command -v suricata        >/dev/null || PKGS+=(suricata)
    command -v suricata-update >/dev/null || PKGS+=(suricata-update)
    command -v jq              >/dev/null || PKGS+=(jq)
fi
if [[ ${#PKGS[@]} -gt 0 ]]; then
    info "a instalar: ${PKGS[*]}"
    if [[ $CHECK_ONLY -eq 0 ]]; then
        run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"
    fi
else
    ok "todos los paquetes ya están instalados"
fi

# El paquete 'samba' arranca smbd/nmbd/winbind standalone y pelea con el DC.
if [[ $CHECK_ONLY -eq 0 ]]; then
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    rm -f /run/samba/smbd.pid /run/samba/nmbd.pid /run/samba/winbindd.pid 2>/dev/null || true
fi

# ===================================================================
# 4. NTP (chrony) — Kerberos necesita reloj sincronizado
# ===================================================================
log "[4/10] NTP"
if [[ $CHECK_ONLY -eq 0 ]]; then
    if systemctl is-enabled systemd-timesyncd >/dev/null 2>&1; then
        systemctl disable --now systemd-timesyncd || true
        info "systemd-timesyncd deshabilitado (lo reemplaza chrony)"
    fi
    [[ -f /etc/chrony/chrony.conf ]] && cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DIR/chrony.conf" /etc/chrony/chrony.conf
    systemctl enable --now chrony
    systemctl restart chrony
fi
if systemctl is-active --quiet chrony; then
    ok "chrony activo ($(chronyc -n tracking 2>/dev/null | awk -F: '/Reference ID/{gsub(/^ +/,"",$2); print $2; exit}' || echo 'sin fuente aún'))"
else
    warn "chrony no está activo"
fi

# ===================================================================
# 5. .env + secretos + IPs de administración
# ===================================================================
log "[5/10] .env y secretos"
if [[ $CHECK_ONLY -eq 0 ]]; then
    bash "$DIR/gen-env.sh" >/dev/null
else
    if [[ ! -f "$ROOT/.env" ]]; then
        info "[check] se generaría $ROOT/.env desde .env.example usando gen-env.sh"
    fi
fi

if [[ -f "$ROOT/.env" ]]; then
    ok ".env presente ($(stat -c %a "$ROOT/.env") $(stat -c %U "$ROOT/.env"))"

    # IPs desde las que hay sesiones SSH abiertas + la sesión actual: si no están
    # en admin_ips, el firewall (policy drop) cortaría el SSH al aplicarse.
    mapfile -t ADMIN_EXTRA < <(
        {
            [[ -n "${SSH_CONNECTION:-}" ]] && echo "${SSH_CONNECTION%% *}"
            who 2>/dev/null | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p'
        } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "$HOST_IP" | sort -u
    )
    EXISTING_EXTRA="$(grep -E '^ADMIN_IPS_EXTRA=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" || true)"
    for ip in $EXISTING_EXTRA; do ADMIN_EXTRA+=("$ip"); done
    mapfile -t ADMIN_EXTRA < <(printf '%s\n' "${ADMIN_EXTRA[@]:-}" | grep -E '^[0-9]' | sort -u)

    if [[ ${#ADMIN_EXTRA[@]} -gt 0 ]]; then
        EXTRA_VAL="$(printf '%s ' "${ADMIN_EXTRA[@]}" | sed 's/ *$//')"
        if [[ $CHECK_ONLY -eq 0 ]]; then
            if grep -qE '^ADMIN_IPS_EXTRA=' "$ROOT/.env"; then
                sed -i "s|^ADMIN_IPS_EXTRA=.*|ADMIN_IPS_EXTRA=\"${EXTRA_VAL}\"|" "$ROOT/.env"
            else
                printf 'ADMIN_IPS_EXTRA="%s"\n' "$EXTRA_VAL" >> "$ROOT/.env"
            fi
        fi
        ok "ADMIN_IPS_EXTRA = ${EXTRA_VAL}"
        info "(esas IPs podrán entrar por SSH/Portainer/5432 además de .50–.52)"
    else
        warn "no detecté IPs de sesión SSH para agregar a admin_ips"
    fi

    # Asegurar que DHCP_INTERFACE quede configurada con la interfaz detectada
    if [[ -n "${IFACE_DEF:-}" ]]; then
        CUR_DHCP_IFACE="$(grep -E '^DHCP_INTERFACE=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"\' " || true)"
        if [[ -z "$CUR_DHCP_IFACE" && $CHECK_ONLY -eq 0 ]]; then
            sed -i "s|^DHCP_INTERFACE=.*|DHCP_INTERFACE=${IFACE_DEF}|" "$ROOT/.env"
            ok "DHCP_INTERFACE fijada a '$IFACE_DEF' en .env"
        fi
    fi
elif [[ $CHECK_ONLY -eq 1 ]]; then
    info ".env pendiente de generar en modo normal"
else
    die "no se pudo crear .env"
fi

# ===================================================================
# 6. AD: provision + usuarios + política
# ===================================================================
log "[6/10] Active Directory (Samba nativo)"
ADMIN_PASS=""
if [[ -f "$ROOT/.env" ]]; then
    ADMIN_PASS="$(grep -E '^AD_ADMIN_PASSWORD=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" || true)"
fi
if [[ -z "$ADMIN_PASS" || "$ADMIN_PASS" == *"Cambiar"* ]]; then
    ADMIN_PASS="Adm!$(openssl rand -hex 6)2026"
    if [[ -f "$ROOT/.env" && $CHECK_ONLY -eq 0 ]]; then
        if grep -qE '^AD_ADMIN_PASSWORD=' "$ROOT/.env"; then
            sed -i "s|^AD_ADMIN_PASSWORD=.*|AD_ADMIN_PASSWORD=${ADMIN_PASS}|" "$ROOT/.env"
        else
            printf 'AD_ADMIN_PASSWORD="%s"\n' "$ADMIN_PASS" >> "$ROOT/.env"
        fi
    fi
fi

if [[ $SKIP_AD -eq 1 ]]; then
    warn "--skip-ad: no se toca el AD"
elif [[ $AD_READY -eq 1 && $CHECK_ONLY -eq 0 ]]; then
    ok "ya provisionado: no se re-provisiona"
    if ! systemctl is-active --quiet samba-ad-dc; then
        run systemctl enable --now samba-ad-dc
        info "samba-ad-dc habilitado/arrancado"
    fi
elif [[ $CHECK_ONLY -eq 0 ]]; then
    info "provisionando el dominio con clave de administrator"
    ADMIN_PASS="$ADMIN_PASS" bash "$DIR/../dc/provision.sh"
    AD_READY=1
fi

if [[ $CHECK_ONLY -eq 0 && $SKIP_AD -eq 0 && $AD_READY -eq 1 ]]; then
    info "usuarios y grupos del dominio (idempotente)"
    bash "$DIR/../dc/add-users-groups.sh" >/dev/null 2>&1 || warn "add-users-groups.sh devolvió advertencias (revisar a mano)"
    bash "$DIR/../dc/password-policy.sh"  >/dev/null 2>&1 || warn "password-policy.sh devolvió advertencias (revisar a mano)"
    ok "usuarios/grupos y política aplicados"

    info "registrando registros DNS A en el DC (mail, webmail, archivos, etc.)"
    printf '%s\n' "$ADMIN_PASS" | kinit administrator >/dev/null 2>&1 || true
    bash "$DIR/../dc/dns-records.sh" >/dev/null 2>&1 || warn "dns-records.sh devolvió advertencias (revisar a mano)"
    ok "registros DNS A publicados"
fi

if systemctl is-active --quiet samba-ad-dc; then
    ok "samba-ad-dc activo"
else
    warn "samba-ad-dc NO está activo (journalctl -u samba-ad-dc -n 50)"
fi

# ===================================================================
# 7. DNS local
# ===================================================================
log "[7/10] DNS del dominio"
if [[ $CHECK_ONLY -eq 0 && $SKIP_AD -eq 0 ]]; then
    if [[ -f /etc/resolv.conf ]] && ! grep -qE '^nameserver[[:space:]]+127\.0\.0\.1$' /etc/resolv.conf; then
        cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)"
        printf 'nameserver 127.0.0.1\nsearch %s\n' "$DOMAIN" > /etc/resolv.conf
        info "/etc/resolv.conf → 127.0.0.1 (Samba DNS)"
    fi
fi
if getent hosts "$DC_FQDN.$DOMAIN" | grep -q "$HOST_IP"; then
    ok "resolución de $DC_FQDN.$DOMAIN OK"
else
    warn "no resuelve $DC_FQDN.$DOMAIN (¿samba-ad-dc arriba? probá: dig +short $DC_FQDN.$DOMAIN @127.0.0.1)"
fi
if getent hosts deb.debian.org >/dev/null 2>&1; then
    ok "resolución externa (forwarder del DC) OK"
else
    warn "sin resolución externa: el DC no está reenviando a $GATEWAY"
    warn "los pulls de Docker pueden fallar; revisar 'dns forwarder' en smb.conf"
fi

# ─── Permisos de los shares ─────────────────────────────────────────
# /srv/samba/departamentos lo crea provision.sh como root:root 0755 →
# los usuarios del dominio pueden LEER pero no ESCRIBIR por SMB. Se le da
# el grupo AD srv-files (igual que valid users de dc/shares.conf).
if [[ $CHECK_ONLY -eq 0 && $SKIP_AD -eq 0 ]]; then
    for d in departamentos respaldo; do
        target="/srv/samba/$d"
        [[ -d "$target" ]] || continue
        if getent group "SUDOERS\\srv-files" >/dev/null 2>&1; then
            chgrp "SUDOERS\\srv-files" "$target"
            chmod 2770 "$target"
            info "$target → grupo SUDOERS\\srv-files, 2770 (lectura/escritura)"
        else
            warn "no resuelve el grupo 'SUDOERS\\srv-files': $target queda sin escritura para el dominio"
        fi
    done
fi

# ===================================================================
# 8. TLS + deploy (firewall, sshd, RADIUS, contenedores)
# ===================================================================
log "[8/10] TLS del proxy + server/deploy.sh"
if [[ ! -f "$ROOT/services/web/tls/server.crt" ]]; then
    info "generando CA interna + cert wildcard *.sudoers.lan"
    run bash "$ROOT/services/web/tls-gen.sh"
else
    ok "certs TLS ya existen"
fi

# Kea va a quedar sirviendo DHCP en la LAN: si el router sigue con su DHCP
# activo, hay DOS servidores y las IPs se pisan.
if [[ $CHECK_ONLY -eq 0 && $ASSUME_YES -eq 0 ]]; then
    echo
    warn "Kea (tso-dhcp) va a quedar sirviendo DHCP en 192.168.0.0/24."
    warn "Antes de continuar, APAGÁ el DHCP del router TP-Link:"
    warn "  router 192.168.0.1 → DHCP → Server → DHCP Server → Disable"
    read -rp "    ¿Ya está desactivado el DHCP del router? [s/N] " ans
    case "$ans" in
        s|S|si|SI|sí|SÍ) : ;;
        *) die "cancelado. Desactivá el DHCP del router y volvé a correr el script." ;;
    esac
fi

if [[ $CHECK_ONLY -eq 0 ]]; then
    bash "$DIR/deploy.sh"
else
    info "[check] se ejecutaría server/deploy.sh"
fi

# ===================================================================
# 9. Seguridad de Red: IDS / IPS (Suricata)
# ===================================================================
log "[9/10] Seguridad de Red: IDS / IPS (Suricata)"
if [[ $SKIP_IDS -eq 1 ]]; then
    warn "--skip-ids: se omite la configuración del IDS/IPS"
elif [[ $CHECK_ONLY -eq 1 ]]; then
    info "[check] se aprovisionaría Suricata y reglas de seguridad del homelab en $DIR/suricata/setup.sh"
    if [[ $ENABLE_IPS -eq 1 ]]; then
        info "[check] se activaría en modo IPS (bloqueo en línea vía NFQUEUE 0 + nftables)"
    else
        info "[check] se activaría en modo IDS (detección pasiva en $IFACE_DEF vía AF_PACKET)"
    fi
else
    info "configurando Suricata (IDS/IPS) y reglas de homelab..."
    bash "$DIR/suricata/setup.sh" -i "$IFACE_DEF"
    if [[ $ENABLE_IPS -eq 1 ]]; then
        info "activando modo IPS (bloqueo en línea)..."
        bash "$DIR/suricata/ips-toggle.sh" --ips
    fi
    ok "Suricata configurado y activo"
fi

# ===================================================================
# 10. Verificación y Reporte de Instalación
# ===================================================================
log "[10/10] Verificación de la Infraestructura"
[[ $CHECK_ONLY -eq 1 ]] && warn "modo --check: los chequeos reflejan el estado actual"

FAIL_COUNT=0

check_status() {
    local name="$1" status="$2"
    if [[ "$status" == "OK" ]]; then
        printf '    \033[32m✔\033[0m %-30s [ \033[32mOK\033[0m ]\n' "$name"
    else
        printf '    \033[31m✘\033[0m %-30s [ \033[31mFALLÓ\033[0m ]\n' "$name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

info "Servicios nativos del servidor:"
for svc in samba-ad-dc chrony nftables freeradius; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        check_status "$svc" "OK"
    else
        check_status "$svc" "FAIL"
    fi
done
if systemctl is-enabled --quiet tso-it-startup.service 2>/dev/null; then
    check_status "tso-it-startup (Auto-boot)" "OK"
else
    check_status "tso-it-startup (Auto-boot)" "FAIL"
fi
if [[ $SKIP_IDS -eq 0 ]]; then
    if systemctl is-active --quiet suricata 2>/dev/null; then
        check_status "suricata (IDS/IPS)" "OK"
    else
        check_status "suricata (IDS/IPS)" "FAIL"
    fi
fi

info "Contenedores Docker:"
if [[ $CHECK_ONLY -eq 0 ]]; then
    CONTAINERS=(tso-dhcp tso-web tso-mail tso-webmail tso-files tso-firma tso-db tso-print tso-portainer tso-grafana tso-prometheus tso-alertmanager)
    for c in "${CONTAINERS[@]}"; do
        if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q "^$c Up"; then
            check_status "$c" "OK"
        else
            check_status "$c" "FAIL"
        fi
    done
fi

info "Puertos de red clave:"
PORTS_TO_CHECK=(
    "53:DNS (Samba)"
    "67:DHCP (Kea)"
    "88:Kerberos (AD)"
    "389:LDAP (AD)"
    "445:SMB/CIFS (Shares)"
    "80:HTTP (Nginx)"
    "443:HTTPS (Nginx)"
    "25:SMTP (Mail)"
    "143:IMAP (Mail)"
    "993:IMAPS (Mail)"
    "1631:CUPS (Print)"
    "1812:FreeRADIUS (WiFi 802.1X)"
    "9443:Portainer (Docker Web)"
)
for item in "${PORTS_TO_CHECK[@]}"; do
    p="${item%%:*}"
    label="${item#*:}"
    if ss -Htuln "sport = :$p" 2>/dev/null | grep -q .; then
        printf '    \033[32m✔\033[0m Puerto %-5s %-25s [ \033[32mOK\033[0m ]\n' "$p" "$label"
    else
        printf '    \033[33m!\033[0m Puerto %-5s %-25s [ \033[33mNO ACTIVO\033[0m ]\n' "$p" "$label"
    fi
done

# Lectura de credenciales para el reporte
get_cfg() {
    local k="$1" def="${2:-}"
    if [[ -f "$ROOT/.env" ]]; then
        local v
        v="$(grep -E "^${k}=" "$ROOT/.env" | tail -1 | cut -d= -f2- || true)"
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        echo "${v:-$def}"
    else
        echo "$def"
    fi
}

REP_AD_PASS="$(get_cfg AD_ADMIN_PASSWORD "$ADMIN_PASS")"
REP_RADIUS_SECRET="$(get_cfg RADIUS_SECRET "No configurado")"
REP_MAIL_USERS="$(get_cfg MAIL_USERS "No configurado")"
REP_FILES_ADMIN_USER="$(get_cfg FILES_ADMIN_USER "admin")"
REP_FILES_ADMIN_PASS="$(get_cfg FILES_ADMIN_PASS "No configurado")"
REP_FILES_USERS="$(get_cfg FILES_USERS "$REP_MAIL_USERS")"
REP_GRAFANA_USER="$(get_cfg GRAFANA_ADMIN_USER "admin")"
REP_GRAFANA_PASS="$(get_cfg GRAFANA_ADMIN_PASSWORD "No configurado")"
REP_CUPS_USER="$(get_cfg CUPS_ADMIN_USER "admin")"
REP_CUPS_PASS="$(get_cfg CUPS_ADMIN_PASS "No configurado")"
REP_PG_USER="$(get_cfg POSTGRES_USER "tso")"
REP_PG_PASS="$(get_cfg POSTGRES_PASSWORD "No configurado")"
REP_RESTIC_PASS="$(get_cfg RESTIC_PASSWORD "No configurado")"

SURI_MODE_STR="No instalado o inactivo"
if systemctl is-active --quiet suricata 2>/dev/null; then
    if [[ -f /etc/default/suricata ]] && grep -qE '^SURICATA_OPTS=.*-q ' /etc/default/suricata; then
        SURI_MODE_STR="ACTIVO — Modo IPS (Prevención en línea NFQUEUE)"
    else
        SURI_MODE_STR="ACTIVO — Modo IDS (Detección pasiva AF_PACKET)"
    fi
elif [[ $SKIP_IDS -eq 1 ]]; then
    SURI_MODE_STR="Omitido (--skip-ids)"
fi

SUMMARY_FILE="$ROOT/IT_INSTALL_SUMMARY.txt"
[[ $EUID -eq 0 ]] && SUMMARY_FILE="/root/IT_INSTALL_SUMMARY.txt"

OVERALL_STATUS="INSTALACIÓN EXITOSA Y SERVICIOS ACTIVOS"
[[ $FAIL_COUNT -gt 0 ]] && OVERALL_STATUS="INSTALACIÓN CON $FAIL_COUNT ADVERTENCIA(S) / SERVICIO(S) INACTIVOS"

generate_summary() {
cat <<EOF
================================================================================
           RESUMEN DE INSTALACIÓN — INFRAESTRUCTURA IT (TSO-II)
================================================================================
Fecha de instalación : $(date '+%Y-%m-%d %H:%M:%S %Z')
Servidor principal   : dc1.sudoers.lan (IP: $HOST_IP)
Puerta de enlace     : $GATEWAY (Router TP-Link TL-WR850N)
Estado global        : $OVERALL_STATUS

--------------------------------------------------------------------------------
 1. SERVICIOS Y ACCESO WEB (HTTPS)
--------------------------------------------------------------------------------
 • Portal Intranet    : https://dc1.sudoers.lan
 • Webmail Roundcube  : https://webmail.sudoers.lan
 • Archivos (Web)     : https://archivos.sudoers.lan  (Shares: /srv/samba/)
 • Firma Digital PAdES: https://firma.sudoers.lan
 • Impresión (CUPS)   : https://print.sudoers.lan
 • Grafana Dashboard : https://grafana.sudoers.lan
 • Portainer (Docker) : https://portainer.sudoers.lan:9443
 • Monitoreo Zabbix   : http://zabbix.sudoers.lan  (Server dedicado: 192.168.0.3)
 • Métricas Internas  : ssh -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 joaquin@$HOST_IP
 • IDS/IPS Suricata   : server/suricata/ (Modo IDS pasivo / IPS NFQUEUE)

--------------------------------------------------------------------------------
 2. CREDENCIALES GENERADAS
--------------------------------------------------------------------------------
 [ Active Directory / Samba DC ]
   - Dominio / Realm  : SUDOERS.LAN (NetBIOS: SUDOERS)
   - Administrador    : administrator
   - Password Admin   : $REP_AD_PASS
   - Usuarios creados : joaquin, david, nicolas (clave inicial: CambiarMe!2026)
                        grupo2 .. grupo9 (usuarios de prueba en oficina)

 [ Correo Electrónico & Webmail ]
   - Cuentas activas  : $REP_MAIL_USERS
   - Servidor IMAP    : mail.sudoers.lan (puertos 143/993)
   - Servidor SMTP    : mail.sudoers.lan (puerto 587)

 [ Gestor de Archivos Web ]
   - Administrador    : $REP_FILES_ADMIN_USER / $REP_FILES_ADMIN_PASS
   - Cuentas estándar : $REP_FILES_USERS

 [ Monitoreo & Bases de Datos & CUPS ]
   - Grafana Admin    : $REP_GRAFANA_USER / $REP_GRAFANA_PASS
   - CUPS Impresión   : $REP_CUPS_USER / $REP_CUPS_PASS
   - PostgreSQL       : usuario=$REP_PG_USER / db=tso / password=$REP_PG_PASS
   - Restic Backup    : $REP_RESTIC_PASS

 [ WiFi WPA2-Enterprise / 802.1X ]
   - RADIUS Secret    : $REP_RADIUS_SECRET
   - Autenticación    : PEAP / MSCHAPv2 (usuarios del dominio AD)

 [ Seguridad de Red (IDS / IPS) ]
   - Estado del Motor : $SURI_MODE_STR
   - Alternar Modo    : sudo bash server/suricata/ips-toggle.sh {--ids|--ips|--status}
   - Suite de Pruebas : sudo bash server/suricata/test-ids-ips.sh
   - Logs de Eventos  : /var/log/suricata/fast.log & eve.json

--------------------------------------------------------------------------------
 3. PASOS REQUERIDOS PARA CONFIGURAR EL ROUTER (TP-Link TL-WR850N)
--------------------------------------------------------------------------------
 Conectarse al router desde un navegador web: http://$GATEWAY

 [PASO 1] DESACTIVAR EL SERVIDOR DHCP DEL ROUTER (CRÍTICO)
   1. Ir al menú lateral: "DHCP" -> "DHCP Settings" (o "Servidor DHCP").
   2. En la opción "DHCP Server", seleccionar: [X] "Disable" (Deshabilitar).
   3. Hacer clic en "Save" (Guardar).
   * Motivo: Kea DHCP en dc1 ($HOST_IP) es ahora el único DHCP oficial de la
     red. Si no se desactiva el del router, habrá conflicto de IPs dobles.

 [PASO 2] CONFIGURAR WIFI EMPRESARIAL 802.1X (WPA2-ENTERPRISE)
   1. Ir a "Wireless" (Inalámbrico) -> "Wireless Security" (Seguridad Inalámbrica).
   2. Seleccionar la opción: "WPA/WPA2 - Enterprise".
   3. Configurar los campos:
      - Version (Versión)         : WPA2
      - Encryption (Cifrado)      : AES
      - Radius Server IP          : $HOST_IP
      - Radius Port (Puerto)      : 1812
      - Radius Password (Secreto) : $REP_RADIUS_SECRET
   4. Hacer clic en "Save" (Guardar) y reiniciar el router si lo solicita.

 [PASO 3] VERIFICACIÓN DE CONEXIÓN WIFI DE CLIENTES
   - Red SSID                 : "sudoers"
   - Tipo de Seguridad        : WPA2-Enterprise / 802.1X EAP
   - Método EAP               : PEAP
   - Autenticación Fase 2     : MSCHAPv2
   - Certificado CA           : "No validar" (o instalar services/web/tls/ca.crt)
   - Usuario y Contraseña     : Usar cualquier usuario del AD (ej. joaquin / david)

--------------------------------------------------------------------------------
 4. ARCHIVO DE CONFIGURACIÓN Y SECRETOS
--------------------------------------------------------------------------------
 • Archivo maestro    : $ROOT/.env (chmod 600)
 • Este informe       : $SUMMARY_FILE
================================================================================
EOF
}

# Mostrar en consola y guardar a archivo
generate_summary | tee "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"
ok "informe guardado de forma segura en: $SUMMARY_FILE"
