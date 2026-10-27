#!/bin/bash
# ==============================================================================
# start-it.sh — Orquestador de arranque, auto-reparación y diagnóstico de dc1
# ==============================================================================
# Este script asegura que toda la infraestructura IT arranque en el orden
# correcto al iniciar el sistema (o tras un reinicio/apagado):
#
#   1. Espera y valida la interfaz de red física y la IP fija (192.168.0.2).
#   2. Corrige /etc/resolv.conf para resolución interna del dominio AD.
#   3. Evita conflictos de Samba (detiene/enmascara smbd/nmbd/winbind huérfanos).
#   4. Inicia servicios nativos en orden: Chrony (NTP) -> Samba AD DC -> Firewall (nftables)
#      -> FreeRADIUS (WiFi) -> Suricata (IDS/IPS).
#   5. Inicia el stack de contenedores Docker (docker compose up -d) y reintenta
#      Kea DHCP si la red física no estaba lista al boot.
#   6. Ejecuta pruebas de diagnóstico funcionales (puertos, DNS, HTTP, estado contenedores).
#   7. Muestra un resumen visual detallado y sugerencias de solución ante errores.
#
# Puede correrse como servicio systemd en cada boot o manualmente en cualquier momento:
#   sudo bash server/start-it.sh                  # Inicia y diagnostica todo
#   sudo bash server/start-it.sh --check          # Solo diagnóstico (sin reiniciar nada)
#   sudo bash server/start-it.sh --force          # Fuerza reinicio de todos los servicios
#   sudo bash server/start-it.sh --install-service# Habilita el servicio de inicio en el boot
#   sudo bash server/start-it.sh --uninstall-service # Deshabilita el servicio de inicio
# ==============================================================================

set -uo pipefail

# ─── Rutas y Variables Globales ───────────────────────────────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

if [[ $EUID -eq 0 ]]; then
    LOG_FILE="/var/log/tso-startup.log"
    SUMMARY_FILE="/var/log/tso-startup-summary.txt"
else
    LOG_FILE="$ROOT/tso-startup.log"
    SUMMARY_FILE="$ROOT/tso-startup-summary.txt"
fi

SYSTEMD_UNIT="/etc/systemd/system/tso-it-startup.service"
BIN_LINK="/usr/local/bin/tso-start"

MODE_CHECK=0
MODE_FORCE=0
MODE_QUIET=0
COLOR=1

# ─── Colores y Formato ────────────────────────────────────────────────────────
setup_colors() {
    if [[ $COLOR -eq 1 ]] && [[ -t 1 || "${TERM:-}" =~ (color|xterm|ansi) ]]; then
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_RED="\033[31m"
        C_GREEN="\033[32m"
        C_YELLOW="\033[33m"
        C_BLUE="\033[34m"
        C_CYAN="\033[36m"
        C_GRAY="\033[90m"
    else
        C_RESET=""
        C_BOLD=""
        C_RED=""
        C_GREEN=""
        C_YELLOW=""
        C_BLUE=""
        C_CYAN=""
        C_GRAY=""
    fi
}
setup_colors

# ─── Logging Dual (Consola + Archivo) ─────────────────────────────────────────
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local msg="$*"
    printf "${C_BOLD}==> %s${C_RESET}\n" "$msg"
    printf "[%s] [INFO] %s\n" "$(ts)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
    local msg="$*"
    printf "    %s\n" "$msg"
    printf "[%s] [INFO]     %s\n" "$(ts)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

ok() {
    local msg="$*"
    printf "    ${C_GREEN}✔${C_RESET} %s\n" "$msg"
    printf "[%s] [OK]       %s\n" "$(ts)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    local msg="$*"
    printf "    ${C_YELLOW}! %s${C_RESET}\n" "$msg"
    printf "[%s] [WARN]     %s\n" "$(ts)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

err() {
    local msg="$*"
    printf "    ${C_RED}✘ %s${C_RESET}\n" "$msg"
    printf "[%s] [ERROR]    %s\n" "$(ts)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

header() {
    local title="$1"
    printf "\n${C_CYAN}${C_BOLD}┌────────────────────────────────────────────────────────────────────────┐${C_RESET}\n"
    printf "${C_CYAN}${C_BOLD}│ %-70s │${C_RESET}\n" "$title"
    printf "${C_CYAN}${C_BOLD}└────────────────────────────────────────────────────────────────────────┘${C_RESET}\n"
    printf "[%s] ========== %s ==========\n" "$(ts)" "$title" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Variables de Diagnóstico ─────────────────────────────────────────────────
FAIL_COUNT=0
WARN_COUNT=0
ERRORS_LIST=()
FIX_SUGGESTIONS=()

record_fail() {
    local service="$1"
    local desc="$2"
    local fix="$3"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ERRORS_LIST+=("$service: $desc")
    FIX_SUGGESTIONS+=("$service -> $fix")
}

record_warn() {
    local service="$1"
    local desc="$2"
    WARN_COUNT=$((WARN_COUNT + 1))
}

# ─── Parseo de Variables de Entorno (.env) ────────────────────────────────────
env_get() {
    local key="$1" def="${2:-}" val=""
    if [[ -r "$ROOT/.env" ]]; then
        val="$(grep -E "^${key}=" "$ROOT/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    fi
    echo "${val:-$def}"
}

HOST_IP="$(env_get HOST_IP "192.168.0.2")"
GATEWAY="$(env_get DHCP_GATEWAY "192.168.0.1")"
DOMAIN="$(env_get DNS_DOMAIN "sudoers.lan")"

# ─── Ayuda y Argumentos ───────────────────────────────────────────────────────
show_help() {
    cat <<EOF
start-it.sh — Orquestador de arranque, recuperación y diagnóstico de dc1

Uso:
  sudo bash server/start-it.sh [OPCIONES]
  sudo start-it.sh [OPCIONES]              (si está en la raíz)
  sudo tso-start [OPCIONES]                 (si se instaló el comando global)

Opciones:
  --check               Modo diagnóstico: evalúa el estado sin iniciar ni cambiar nada.
  --force               Fuerza el reinicio de todos los servicios nativos y contenedores.
  --install-service     Instala y habilita la unidad de systemd para inicio automático al boot.
  --uninstall-service   Deshabilita y elimina la unidad de systemd.
  --no-color            Deshabilita los colores ANSI en la terminal.
  --quiet, -q           Salida mínima en consola (todo se registra en /var/log/tso-startup.log).
  -h, --help            Muestra esta ayuda.

Archivos de registro:
  Logs completos : /var/log/tso-startup.log
  Último resumen : /var/log/tso-startup-summary.txt
EOF
}

# ─── Instalación / Desinstalación como Servicio Systemd ───────────────────────
install_systemd_service() {
    header "Instalando Servicio Systemd para Inicio Automático"
    if [[ $EUID -ne 0 ]]; then
        err "Se requieren permisos de root para instalar el servicio: sudo $0 --install-service"
        exit 1
    fi

    cat <<EOF > "$SYSTEMD_UNIT"
[Unit]
Description=Arranque y Verificacion de Infraestructura IT (TSO-II dc1)
After=network.target network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ROOT
ExecStart=/bin/bash $DIR/start-it.sh
TimeoutStartSec=180
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SYSTEMD_UNIT"
    systemctl daemon-reload
    systemctl enable tso-it-startup.service >/dev/null 2>&1
    ok "Unidad creada en $SYSTEMD_UNIT"
    ok "Servicio 'tso-it-startup.service' habilitado para arrancar en cada inicio del sistema."

    # Crear symlink en /usr/local/bin para facilitar el uso
    ln -sf "$DIR/start-it.sh" "$BIN_LINK"
    chmod +x "$BIN_LINK"
    ok "Comando global disponible: sudo tso-start"

    echo
    info "Para probar el servicio ahora mismo:"
    info "  sudo systemctl start tso-it-startup.service"
    info "Para ver los logs del servicio:"
    info "  journalctl -u tso-it-startup.service -f"
    exit 0
}

uninstall_systemd_service() {
    header "Desinstalando Servicio Systemd"
    if [[ $EUID -ne 0 ]]; then
        err "Se requieren permisos de root: sudo $0 --uninstall-service"
        exit 1
    fi

    systemctl disable --now tso-it-startup.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_UNIT"
    rm -f "$BIN_LINK"
    systemctl daemon-reload
    ok "Servicio tso-it-startup.service eliminado y deshabilitado."
    exit 0
}

# Procesar argumentos
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)              show_help; exit 0 ;;
        --check|-c)             MODE_CHECK=1; shift ;;
        --force|-f)             MODE_FORCE=1; shift ;;
        --install-service)      install_systemd_service ;;
        --uninstall-service)    uninstall_systemd_service ;;
        --no-color)             COLOR=0; setup_colors; shift ;;
        --quiet|-q)             MODE_QUIET=1; shift ;;
        *)                      echo "Opción desconocida: $1"; show_help; exit 1 ;;
    esac
done

# Preparar archivo de log
touch "$LOG_FILE" 2>/dev/null || true
printf "\n[%s] ========== INICIO DE EJECUCIÓN (check=%d, force=%d) ==========\n" "$(ts)" "$MODE_CHECK" "$MODE_FORCE" >> "$LOG_FILE" 2>/dev/null || true

# ─── Verificación de Privilegios ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    if [[ $MODE_CHECK -eq 1 ]]; then
        warn "Ejecutando en modo diagnóstico como usuario no root (algunos chequeos pueden ser inexactos)."
    else
        err "Para iniciar y corregir los servicios del sistema se requieren permisos de root."
        info "Ejecutar: sudo bash $0"
        exit 1
    fi
fi

# ─── PASO 0: Auto-aseguramiento del Servicio Systemd (Boot Persistente) ───────
header "Paso 0: Servicio de Inicio Automático (Systemd Boot)"

ensure_systemd_service() {
    if [[ $EUID -eq 0 && $MODE_CHECK -eq 0 ]]; then
        local need_update=0
        if [[ ! -f "$SYSTEMD_UNIT" ]]; then
            need_update=1
        elif ! grep -q "ExecStart=/bin/bash $DIR/start-it.sh" "$SYSTEMD_UNIT" 2>/dev/null; then
            need_update=1
        fi

        if [[ $need_update -eq 1 ]]; then
            info "Configurando unidad systemd en $SYSTEMD_UNIT..."
            cat <<EOF > "$SYSTEMD_UNIT"
[Unit]
Description=Arranque y Verificacion de Infraestructura IT (TSO-II dc1)
Documentation=https://github.com/joaquin/linux-homelab-enterprise
After=network.target network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ROOT
ExecStart=/bin/bash $DIR/start-it.sh
TimeoutStartSec=180
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
            chmod 644 "$SYSTEMD_UNIT"
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi

        # Habilitar en systemd para que arranque en cada inicio del sistema
        if ! systemctl is-enabled tso-it-startup.service >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable tso-it-startup.service >/dev/null 2>&1 || true
            ok "Servicio systemd 'tso-it-startup.service' autohabilitado para arranque en cada boot."
        else
            ok "Servicio systemd 'tso-it-startup.service' verificado y habilitado en el arranque."
        fi

        # Crear o actualizar symlink global /usr/local/bin/tso-start
        if [[ ! -L "$BIN_LINK" ]] || [[ "$(readlink -f "$BIN_LINK" 2>/dev/null)" != "$(readlink -f "$DIR/start-it.sh" 2>/dev/null)" ]]; then
            ln -sf "$DIR/start-it.sh" "$BIN_LINK" 2>/dev/null || true
            chmod +x "$BIN_LINK" 2>/dev/null || true
            ok "Comando global 'sudo tso-start' disponible y actualizado."
        fi
    else
        # Modo diagnóstico o sin root
        if systemctl is-enabled tso-it-startup.service >/dev/null 2>&1; then
            ok "Servicio systemd 'tso-it-startup.service': HABILITADO para boot."
        else
            warn "Servicio systemd 'tso-it-startup.service': NO habilitado (se auto-habilitará al correr con sudo)."
            record_warn "Systemd Boot" "tso-it-startup.service no está habilitado"
        fi
    fi
}
ensure_systemd_service

# ─── PASO 1: Red Física e IP Fija ─────────────────────────────────────────────
header "Paso 1: Red Física y Conectividad Local"

get_iface() {
    local iface=""
    if [[ -f /etc/default/suricata ]]; then
        iface="$(grep -E '^IFACE=' /etc/default/suricata 2>/dev/null | cut -d= -f2- | tr -d "\"\' ")"
    fi
    if [[ -z "$iface" ]] || ! ip link show "$iface" >/dev/null 2>&1; then
        iface="$(ip -o -4 route get "$GATEWAY" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
    fi
    if [[ -z "$iface" ]] || ! ip link show "$iface" >/dev/null 2>&1; then
        iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    fi
    if [[ -z "$iface" ]] || ! ip link show "$iface" >/dev/null 2>&1; then
        for d in /sys/class/net/*; do
            [[ -d "$d/device" ]] || continue
            local name="$(basename "$d")"
            [[ "$name" =~ ^(lo|docker|veth|br-|virbr) ]] && continue
            iface="$name"
            break
        done
    fi
    echo "${iface:-}"
}

NET_IFACE="$(get_iface)"
if [[ -n "$NET_IFACE" ]]; then
    info "Interfaz física detectada: $NET_IFACE"
    
    # Esperar hasta 20 segundos si el link está 'DOWN' o 'NO-CARRIER'
    if [[ $MODE_CHECK -eq 0 ]]; then
        local_attempts=0
        while [[ $local_attempts -lt 20 ]]; do
            if ip link show "$NET_IFACE" 2>/dev/null | grep -q "state UP"; then
                break
            fi
            sleep 1
            local_attempts=$((local_attempts + 1))
        done
    fi

    # Verificar si tiene la IP esperada (192.168.0.2)
    if ip -4 addr show dev "$NET_IFACE" 2>/dev/null | grep -q "$HOST_IP"; then
        ok "Interfaz $NET_IFACE activa con IP esperada: $HOST_IP"
    else
        CURRENT_IP="$(ip -o -4 addr show dev "$NET_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
        if [[ -n "$CURRENT_IP" ]]; then
            warn "Interfaz $NET_IFACE tiene IP $CURRENT_IP (diferente de $HOST_IP)."
            record_warn "Red" "IP actual $CURRENT_IP difiere de $HOST_IP"
        else
            err "Interfaz $NET_IFACE NO tiene dirección IP configurada."
            record_fail "Red" "Sin IP en interfaz $NET_IFACE" "sudo bash $DIR/set-ip.sh -i $NET_IFACE --yes --commit"
        fi
    fi
else
    err "No se pudo identificar una interfaz de red física activa."
    record_fail "Red" "Interfaz no identificada" "Revisar cable de red o 'ip a'"
fi

# ─── PASO 2: Configuración de /etc/resolv.conf ─────────────────────────────────
header "Paso 2: Resolución DNS Local (/etc/resolv.conf)"

# El servidor dc1 debe apuntar a sí mismo (127.0.0.1) para que el DNS de Samba resuelva el dominio
RESOLV_OK=0
if grep -E '^[[:space:]]*nameserver[[:space:]]+(127\.0\.0\.1|192\.168\.0\.2)' /etc/resolv.conf >/dev/null 2>&1; then
    RESOLV_OK=1
    ok "/etc/resolv.conf apunta correctamente al DNS local (127.0.0.1 / $HOST_IP)"
else
    warn "/etc/resolv.conf no apunta al DNS del DC (podría haber sido sobrescrito en el boot)."
    if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
        info "Restaurando nameserver 127.0.0.1 y search $DOMAIN en /etc/resolv.conf..."
        # Backup rápido
        cp /etc/resolv.conf /etc/resolv.conf.bak.tso 2>/dev/null || true
        cat <<EOF > /etc/resolv.conf
# Configurado por start-it.sh — DNS provisto por Samba AD DC
nameserver 127.0.0.1
nameserver $HOST_IP
nameserver $GATEWAY
search $DOMAIN
EOF
        ok "/etc/resolv.conf corregido."
    else
        record_warn "DNS Local" "/etc/resolv.conf no tiene nameserver 127.0.0.1"
    fi
fi

# ─── PASO 3: Prevención de Conflictos de Samba Standalone ──────────────────────
header "Paso 3: Verificación de Conflictos de Samba"

# En Debian, los servicios smbd, nmbd y winbind colisionan con samba-ad-dc
ROGUE_SERVICES=(smbd nmbd winbind)
for s in "${ROGUE_SERVICES[@]}"; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
        warn "Servicio en conflicto '$s' está ACTIVO (debe ser gestionado solo por samba-ad-dc)."
        if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
            systemctl stop "$s" 2>/dev/null || true
            systemctl mask "$s" 2>/dev/null || true
            ok "Servicio '$s' detenido y enmascarado."
        else
            record_fail "Samba Conflict" "$s activo" "sudo systemctl stop $s && sudo systemctl mask $s"
        fi
    else
        ok "Servicio colisionante '$s' inactivo/enmascarado."
    fi
done

# Limpieza de PIDs huérfanos si samba-ad-dc no está corriendo
if ! systemctl is-active --quiet samba-ad-dc 2>/dev/null && ! systemctl is-active --quiet samba 2>/dev/null; then
    if [[ -d /run/samba ]]; then
        rm -f /run/samba/smbd.pid /run/samba/nmbd.pid /run/samba/winbindd.pid /run/samba/samba.pid 2>/dev/null || true
    fi
fi

# ─── PASO 4: Servicios Nativos del Sistema ─────────────────────────────────────
header "Paso 4: Orquestación de Servicios Nativos"

# 1. Chrony (NTP) — Vital para Kerberos / Active Directory
if command -v chronyd >/dev/null 2>&1; then
    if systemctl is-active --quiet chrony 2>/dev/null; then
        ok "Chrony (NTP): en ejecución."
    else
        warn "Chrony (NTP) está detenido."
        if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
            systemctl restart chrony 2>/dev/null || systemctl start chrony
            sleep 1
            if systemctl is-active --quiet chrony; then
                ok "Chrony (NTP): iniciado con éxito."
            else
                err "No se pudo iniciar Chrony."
                record_fail "chrony" "Fallo al iniciar" "sudo systemctl status chrony"
            fi
        else
            record_fail "chrony" "Servicio detenido" "sudo systemctl start chrony"
        fi
    fi
else
    warn "Chrony no instalado en este host."
fi

# 2. Samba Active Directory Domain Controller
SAMBA_UNIT="samba-ad-dc"
if ! systemctl list-unit-files "${SAMBA_UNIT}.service" >/dev/null 2>&1; then
    SAMBA_UNIT="samba"
fi

if [[ -f /etc/samba/smb.conf ]]; then
    if systemctl is-active --quiet "$SAMBA_UNIT" 2>/dev/null && [[ $MODE_FORCE -eq 0 ]]; then
        ok "Samba AD DC ($SAMBA_UNIT): en ejecución."
    else
        if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
            info "Iniciando $SAMBA_UNIT..."
            systemctl restart "$SAMBA_UNIT" 2>/dev/null || systemctl start "$SAMBA_UNIT"
            
            # Esperar hasta 15 segundos a que abran los puertos clave de AD
            local_attempts=0
            while [[ $local_attempts -lt 15 ]]; do
                if ss -Htlun '( sport = :53 or sport = :389 or sport = :88 )' 2>/dev/null | grep -q .; then
                    break
                fi
                sleep 1
                local_attempts=$((local_attempts + 1))
            done

            if systemctl is-active --quiet "$SAMBA_UNIT"; then
                ok "Samba AD DC ($SAMBA_UNIT): iniciado correctamente."
            else
                err "Samba AD DC falló al iniciar."
                record_fail "$SAMBA_UNIT" "Fallo de inicio" "journalctl -u $SAMBA_UNIT -n 50"
            fi
        else
            err "Samba AD DC ($SAMBA_UNIT) está detenido."
            record_fail "$SAMBA_UNIT" "Servicio inactivo" "sudo systemctl start $SAMBA_UNIT"
        fi
    fi
else
    warn "No existe /etc/samba/smb.conf (AD DC no parece estar provisionado)."
fi

# 3. Firewall nftables
if command -v nft >/dev/null 2>&1; then
    NFT_OK=0
    if nft list table inet filter >/dev/null 2>&1; then
        NFT_OK=1
        ok "Firewall nftables: tabla 'inet filter' cargada y activa."
    else
        warn "Firewall nftables: tabla 'inet filter' no encontrada."
        if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
            if [[ -f /etc/nftables.conf ]]; then
                info "Cargando reglas desde /etc/nftables.conf..."
                if nft -f /etc/nftables.conf 2>/dev/null; then
                    ok "Reglas de firewall aplicadas exitosamente."
                    systemctl enable nftables >/dev/null 2>&1 || true
                else
                    err "Error al cargar /etc/nftables.conf"
                    record_fail "nftables" "Error de sintaxis o carga" "sudo nft -c -f /etc/nftables.conf"
                fi
            fi
        else
            record_fail "nftables" "Tabla inet filter no cargada" "sudo nft -f /etc/nftables.conf"
        fi
    fi
fi

# 4. FreeRADIUS (WiFi 802.1X WPA2-Enterprise)
if command -v freeradius >/dev/null 2>&1; then
    if systemctl is-active --quiet freeradius 2>/dev/null; then
        ok "FreeRADIUS: en ejecución (1812/udp)."
    else
        warn "FreeRADIUS está detenido."
        if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
            info "Iniciando FreeRADIUS..."
            systemctl restart freeradius 2>/dev/null || systemctl start freeradius
            sleep 1
            if systemctl is-active --quiet freeradius; then
                ok "FreeRADIUS: iniciado exitosamente."
            else
                err "FreeRADIUS falló al iniciar."
                record_fail "freeradius" "Error al arrancar" "sudo journalctl -u freeradius -n 50"
            fi
        else
            record_fail "freeradius" "Inactivo" "sudo systemctl start freeradius"
        fi
    fi
fi

# 5. Suricata (IDS / IPS)
if command -v suricata >/dev/null 2>&1; then
    if systemctl is-active --quiet suricata 2>/dev/null; then
        # Verificar si está en modo IPS
        if [[ -f /etc/default/suricata ]] && grep -qE '^SURICATA_OPTS=.*-q ' /etc/default/suricata; then
            ok "Suricata: ACTIVO en modo IPS (Prevención en línea - NFQUEUE)."
            # Asegurar regla en nftables
            if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
                if ! nft list chain inet filter input 2>/dev/null | grep -q "queue num 0"; then
                    nft insert rule inet filter input queue num 0 bypass 2>/dev/null || true
                    info "Regla NFQUEUE reinyectada en nftables para modo IPS."
                fi
            fi
        else
            ok "Suricata: ACTIVO en modo IDS (Detección pasiva)."
        fi
    else
        warn "Suricata está detenido."
        if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
            info "Iniciando Suricata..."
            systemctl restart suricata 2>/dev/null || systemctl start suricata
            sleep 1
            if systemctl is-active --quiet suricata; then
                ok "Suricata iniciado."
            else
                err "No se pudo iniciar Suricata."
                record_fail "suricata" "Error al arrancar" "sudo journalctl -u suricata -n 50"
            fi
        else
            record_fail "suricata" "Inactivo" "sudo systemctl start suricata"
        fi
    fi
fi

# ─── PASO 5: Docker y Stack de Contenedores ───────────────────────────────────
header "Paso 5: Docker Daemon y Stack Compose"

if command -v docker >/dev/null 2>&1; then
    if ! systemctl is-active --quiet docker; then
        warn "Docker daemon está inactivo."
        if [[ $MODE_CHECK -eq 0 && $EUID -eq 0 ]]; then
            systemctl start docker
            sleep 2
        fi
    fi

    if systemctl is-active --quiet docker; then
        ok "Docker daemon: activo y respondiendo."
        
        # Verificar o iniciar los contenedores declarados en docker-compose.yml
        if [[ -f "$ROOT/docker-compose.yml" ]]; then
            if [[ $MODE_CHECK -eq 0 ]]; then
                info "Sincronizando estado de contenedores con docker compose..."
                (cd "$ROOT" && docker compose up -d 2>/dev/null) || {
                    err "docker compose up -d reportó advertencias o errores."
                }
            fi

            # Atención especial a Kea DHCP (tso-dhcp)
            # Como Kea corre en network_mode: host, si inició antes de que la IP física estuviera
            # lista, puede haber fallado enlazando el socket de broadcast.
            if [[ $MODE_CHECK -eq 0 ]]; then
                if ! docker ps --format '{{.Names}}' | grep -q '^tso-dhcp$'; then
                    info "Reiniciando tso-dhcp para reanudar bind en socket 67/udp..."
                    docker restart tso-dhcp >/dev/null 2>&1 || docker compose -f "$ROOT/docker-compose.yml" up -d dhcp >/dev/null 2>&1
                fi
            fi
        else
            warn "No se encontró $ROOT/docker-compose.yml"
        fi
    else
        err "Docker daemon NO está en ejecución."
        record_fail "docker" "Daemon inactivo" "sudo systemctl restart docker"
    fi
else
    err "Docker no está instalado en este sistema."
    record_fail "docker" "Binario docker no encontrado" "Instalar docker.io o docker-ce"
fi

# ─── PASO 6: Diagnóstico de Contenedores y Puertos ────────────────────────────
header "Paso 6: Diagnóstico y Salud de Servicios"

# Lista de contenedores del proyecto
COMPOSE_CONTAINERS=(
    "tso-dhcp:DHCP Kea (host network)"
    "tso-web:Nginx Reverse Proxy / Portal"
    "tso-mail:Postfix + Dovecot (Mail)"
    "tso-webmail:Roundcube Webmail"
    "tso-files:Filebrowser (Gestor Web Shares)"
    "tso-firma:Firma Digital PAdES (UPDS)"
    "tso-db:PostgreSQL Base de Datos"
    "tso-print:CUPS Servidor Impresión"
    "tso-portainer:Portainer Docker Panel"
    "tso-prometheus:Prometheus Métricas"
    "tso-alertmanager:Alertmanager Notificaciones"
    "tso-grafana:Grafana Dashboards"
    "tso-node-exporter:Node Exporter Métricas Host"
    "tso-cadvisor:cAdvisor Métricas Contenedores"
    "tso-blackbox:Blackbox Sondas de Red"
)

info "Chequeo de Contenedores Docker:"
for item in "${COMPOSE_CONTAINERS[@]}"; do
    c_name="${item%%:*}"
    c_desc="${item#*:}"
    
    # Comprobar si el contenedor existe y está 'Up'
    c_status="$(docker ps -a --filter "name=^/${c_name}$" --format '{{.Status}}' 2>/dev/null || true)"
    if [[ -z "$c_status" ]]; then
        printf "    ${C_YELLOW}!${C_RESET} %-18s %-32s [ ${C_YELLOW}NO CREADO${C_RESET} ]\n" "$c_name" "$c_desc"
        printf "[%s] [WARN]     Contenedor %s (%s) no creado o desactivado\n" "$(ts)" "$c_name" "$c_desc" >> "$LOG_FILE" 2>/dev/null || true
        record_warn "$c_name" "No existe en docker ps -a"
    elif [[ "$c_status" =~ ^Up ]]; then
        printf "    ${C_GREEN}✔${C_RESET} %-18s %-32s [ ${C_GREEN}UP${C_RESET} ]\n" "$c_name" "$c_desc"
        printf "[%s] [OK]       Contenedor %s (%s) UP\n" "$(ts)" "$c_name" "$c_desc" >> "$LOG_FILE" 2>/dev/null || true
    else
        printf "    ${C_RED}✘${C_RESET} %-18s %-32s [ ${C_RED}%s${C_RESET} ]\n" "$c_name" "$c_desc" "$c_status"
        printf "[%s] [ERROR]    Contenedor %s (%s) %s\n" "$(ts)" "$c_name" "$c_desc" "$c_status" >> "$LOG_FILE" 2>/dev/null || true
        record_fail "$c_name" "Estado: $c_status" "docker restart $c_name && docker logs $c_name --tail 30"
    fi
done

# Chequeo de Puertos Clave
info "Chequeo de Puertos de Red:"
PORTS_PROBES=(
    "53:DNS (Samba AD DC)"
    "67:DHCP (Kea)"
    "88:Kerberos (Samba AD DC)"
    "389:LDAP (Samba AD DC)"
    "445:SMB / Shares (Samba AD DC)"
    "80:HTTP (Nginx)"
    "443:HTTPS (Nginx)"
    "25:SMTP (Mail)"
    "143:IMAP (Mail)"
    "993:IMAPS (Mail)"
    "1631:CUPS Impresión"
    "1812:FreeRADIUS (WiFi 802.1X)"
    "9443:Portainer Web"
    "3000:Grafana Web"
    "9090:Prometheus Interno"
)

for item in "${PORTS_PROBES[@]}"; do
    p="${item%%:*}"
    label="${item#*:}"
    if ss -Htuln "sport = :$p" 2>/dev/null | grep -q .; then
        printf "    ${C_GREEN}✔${C_RESET} Puerto %-5s %-30s [ ${C_GREEN}OK${C_RESET} ]\n" "$p" "$label"
    else
        # FreeRADIUS es opcional si no está instalado
        if [[ "$p" == "1812" ]] && ! command -v freeradius >/dev/null 2>&1; then
            printf "    ${C_GRAY}○${C_RESET} Puerto %-5s %-30s [ ${C_GRAY}NO INSTALADO${C_RESET} ]\n" "$p" "$label"
        else
            printf "    ${C_RED}✘${C_RESET} Puerto %-5s %-30s [ ${C_RED}CERRADO / INACTIVO${C_RESET} ]\n" "$p" "$label"
            record_fail "Puerto $p" "$label cerrado" "Verificar logs del servicio asociado al puerto $p"
        fi
    fi
done

# Pruebas Funcionales Activas
info "Pruebas Funcionales:"

# 1. DNS Query
if command -v dig >/dev/null 2>&1; then
    if dig @127.0.0.1 "dc1.$DOMAIN" +short +time=2 >/dev/null 2>&1; then
        ok "Resolución DNS interna (@127.0.0.1 dc1.$DOMAIN): funcional."
    else
        err "Resolución DNS interna falló (@127.0.0.1 dc1.$DOMAIN no responde)."
        record_fail "DNS Query" "Sin respuesta de Samba DNS" "sudo systemctl restart $SAMBA_UNIT"
    fi
elif command -v host >/dev/null 2>&1; then
    if host "dc1.$DOMAIN" 127.0.0.1 >/dev/null 2>&1; then
        ok "Resolución DNS interna (@127.0.0.1 dc1.$DOMAIN): funcional."
    else
        err "Resolución DNS interna falló."
        record_fail "DNS Query" "Sin respuesta de Samba DNS" "sudo systemctl restart $SAMBA_UNIT"
    fi
fi

# 2. Portal Web HTTP/HTTPS
if command -v curl >/dev/null 2>&1; then
    HTTP_CODE="$(curl -k -s -o /dev/null -w "%{http_code}" https://127.0.0.1/ 2>/dev/null || true)"
    if [[ "$HTTP_CODE" =~ ^(200|301|302|401|403)$ ]]; then
        ok "Portal Web Nginx (HTTPS localhost): respondiendo con código $HTTP_CODE."
    else
        HTTP_CODE_80="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ 2>/dev/null || true)"
        if [[ "$HTTP_CODE_80" =~ ^(200|301|302)$ ]]; then
            ok "Portal Web Nginx (HTTP localhost): respondiendo con código $HTTP_CODE_80."
        else
            warn "Portal Web Nginx: sin respuesta adecuada en HTTP/HTTPS."
            record_warn "Web Nginx" "curl localhost no respondió 200/301"
        fi
    fi

    # 3. Healthcheck de Firma Digital PAdES
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^tso-firma$'; then
        FIRMA_HEALTH="$(curl -k -s -H 'Host: firma.sudoers.lan' https://127.0.0.1/api/health 2>/dev/null || true)"
        if echo "$FIRMA_HEALTH" | grep -q '"status":"ok"'; then
            ok "Firma Digital PAdES (https://firma.sudoers.lan/api/health): respondiendo OK."
        else
            # Intento directo al contenedor
            FIRMA_HEALTH_DIR="$(docker exec tso-firma curl -s http://127.0.0.1:5000/api/health 2>/dev/null || true)"
            if echo "$FIRMA_HEALTH_DIR" | grep -q '"status":"ok"'; then
                ok "Firma Digital PAdES (contenedor interno tso-firma:5000): respondiendo OK."
            else
                warn "Firma Digital PAdES: sin respuesta en /api/health."
                record_warn "Firma Digital" "Healthcheck de API firma no respondió status ok"
            fi
        fi
    fi
fi

# ─── PASO 7: Resumen Final y Sugerencias de Solución ───────────────────────────
header "Resumen Final de Arranque y Estado"

SUMMARY_TEXT=""
if [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -eq 0 ]]; then
    SUMMARY_TEXT="ESTADO: INFRAESTRUCTURA IT 100% OPERATIVA"
    printf "\n${C_GREEN}${C_BOLD}========================================================================${C_RESET}\n"
    printf "${C_GREEN}${C_BOLD}   ✔  %s${C_RESET}\n" "$SUMMARY_TEXT"
    printf "${C_GREEN}${C_BOLD}========================================================================${C_RESET}\n"
    info "Todos los servicios nativos, contenedores y puertos están funcionando."
elif [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -gt 0 ]]; then
    SUMMARY_TEXT="ESTADO: OPERATIVO CON $WARN_COUNT ADVERTENCIA(S)"
    printf "\n${C_YELLOW}${C_BOLD}========================================================================${C_RESET}\n"
    printf "${C_YELLOW}${C_BOLD}   !  %s${C_RESET}\n" "$SUMMARY_TEXT"
    printf "${C_YELLOW}${C_BOLD}========================================================================${C_RESET}\n"
else
    SUMMARY_TEXT="ESTADO: $FAIL_COUNT FALLO(S) DETECTADO(S) EN EL ARRANQUE"
    printf "\n${C_RED}${C_BOLD}========================================================================${C_RESET}\n"
    printf "${C_RED}${C_BOLD}   ✘  %s${C_RESET}\n" "$SUMMARY_TEXT"
    printf "${C_RED}${C_BOLD}========================================================================${C_RESET}\n"
    
    printf "\n${C_RED}${C_BOLD}Detalle de Fallos:${C_RESET}\n"
    for e in "${ERRORS_LIST[@]}"; do
        printf "  ${C_RED}• %s${C_RESET}\n" "$e"
    done

    printf "\n${C_CYAN}${C_BOLD}Comandos recomendados para resolver los problemas:${C_RESET}\n"
    for s in "${FIX_SUGGESTIONS[@]}"; do
        printf "  ${C_YELLOW}→ %s${C_RESET}\n" "$s"
    done
fi

# Guardar resumen en archivo para consultas posteriores
cat <<EOF > "$SUMMARY_FILE" 2>/dev/null || true
================================================================================
             RESUMEN DE ESTADO DE INFRAESTRUCTURA IT (dc1)
================================================================================
Fecha de evaluación : $(date '+%Y-%m-%d %H:%M:%S %Z')
Host físico         : $(hostname -f 2>/dev/null || hostname) ($HOST_IP)
Resultado           : $SUMMARY_TEXT
Fallos críticos     : $FAIL_COUNT
Advertencias        : $WARN_COUNT

$(if [[ ${#ERRORS_LIST[@]} -gt 0 ]]; then
    echo "FALLOS DETECTADOS:"
    for e in "${ERRORS_LIST[@]}"; do
        echo " - $e"
    done
    echo ""
    echo "ACCIONES RECOMENDADAS:"
    for s in "${FIX_SUGGESTIONS[@]}"; do
        echo " - $s"
    done
fi)
================================================================================
EOF

info "Registro guardado en: $LOG_FILE"
info "Último resumen en   : $SUMMARY_FILE"

printf "\n${C_BOLD}Comandos rápidos para identificar y seguir errores:${C_RESET}\n"
printf "  ${C_CYAN}• Ver resumen de estado:${C_RESET}      cat %s\n" "$SUMMARY_FILE"
printf "  ${C_CYAN}• Ver log completo con hora:${C_RESET}   tail -n 80 %s\n" "$LOG_FILE"
printf "  ${C_CYAN}• Ver traza del boot systemd:${C_RESET}  journalctl -u tso-it-startup.service -b --no-pager\n"
printf "  ${C_CYAN}• Reevaluar diagnóstico:${C_RESET}      sudo tso-start --check\n"
echo

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
