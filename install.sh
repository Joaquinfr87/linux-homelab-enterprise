#!/bin/bash
# ===================================================================
# install.sh — INSTALACIÓN UNIFICADA del servidor (dc1) en Debian 12/13
#
# Este es el ÚNICO comando que hay que ejecutar en una máquina nueva.
# Une en un solo flujo todos los scripts del repo:
#
#   server/set-ip.sh · server/gen-env.sh · dc/provision.sh ·
#   dc/add-users-groups.sh · dc/password-policy.sh · dc/dns-records.sh ·
#   services/web/tls-gen.sh · server/deploy.sh (nftables + sshd +
#   chrony + FreeRADIUS + docker compose) · server/backup.sh
#   (+ opcional: services/zabbix/install-agent.sh dc1)
#
# CARACTERÍSTICAS
# ---------------
#   * Idempotente: se puede volver a correr sin romper lo ya hecho.
#   * Cada fase tiene su log y un estado PASS / FAIL / SKIP / WARN.
#   * Si una fase crítica falla, se detiene y muestra las últimas líneas
#     del log, el comando para reintentar y el diagnóstico.
#   * Al final muestra:
#       - accesos y contraseñas de TODOS los servicios (AD, web, correo,
#         archivos, Grafana, CUPS, PostgreSQL, RADIUS/WiFi, restic…)
#       - tabla de estado de cada servicio (systemd, contenedores,
#         puertos, DNS y URLs)
#       - errores/avisos y pendientes manuales
#   * Guarda las credenciales en <log>/credenciales.txt (chmod 600).
#
# USO RÁPIDO
# ----------
#   sudo bash install.sh --check          # solo diagnóstico, no cambia nada
#   sudo bash install.sh                  # instalación completa (interactiva)
#   sudo bash install.sh --yes            # desatendida (genera secretos)
#
# DESDE CERO (la IP del server todavía no es 192.168.0.2)
# ------------------------------------------------------
#   sudo bash install.sh --set-ip --yes   # fija .2 y CORTA la sesión SSH
#   # reconectarse a 192.168.0.2 y volver a correr:
#   sudo bash install.sh
#
# REQUISITOS
# ----------
#   * Debian 12 o 13, systemd, acceso a Internet (apt/Docker).
#   * Repo clonado en la máquina; ejecutar desde la raíz del repo.
#   * El DHCP del router debe quedar APAGADO antes de levantar Kea.
#
# OPCIONES
# --------
#   --check, --dry-run     Diagnóstico: no instala ni modifica nada.
#   --yes                  Sin confirmaciones. Genera claves si faltan.
#   --set-ip               Aplica la IP fija con server/set-ip.sh --commit.
#                          Requiere --yes. Si se corre por SSH, la sesión
#                          se corta: reconectarse y volver a ejecutar.
#   --host-ip IP           IP del server (default 192.168.0.2).
#   --gateway IP           Gateway/router (default 192.168.0.1).
#   --domain DOMINIO       Dominio interno (default sudoers.lan).
#   --realm REALM          Realm Kerberos (default SUDOERS.LAN).
#   --netbios NOMBRE       NetBIOS (default SUDOERS).
#   --dc-name NOMBRE       Hostname corto del DC (default dc1).
#   --admin-pass CLAVE     Clave de administrator del AD. También se puede
#                          pasar por entorno: ADMIN_PASS=... (más seguro).
#   --ad-user-pass CLAVE   Clave inicial para usuarios AD nuevos.
#   --skip-ad              No provisiona el AD (ya existe).
#   --skip-dns             No crea registros DNS.
#   --skip-backup          No instala el backup con restic.
#   --with-zabbix-agent    Instala zabbix-agent2 en dc1 (server .3).
#   --no-secrets           Muestra las claves enmascaradas (para compartir
#                          la salida). El archivo de credenciales también
#                          queda enmascarado.
#   --verbose              Muestra en vivo la salida de cada fase.
#   -h, --help             Esta ayuda.
#
# LOGS Y CREDENCIALES
# -------------------
#   /var/log/tso-install/<fecha-hora>/          (root)
#     ├── <NN>-<fase>.log  (uno por fase, p. ej. 01-preflight.log)
#     ├── servicios.status   (tabla usada en el resumen)
#     └── credenciales.txt   (chmod 600; secretos)
#
# EJEMPLOS
# --------
#   sudo bash install.sh --check --no-secrets
#   sudo bash install.sh --yes --admin-pass 'ClaveSegura!2026'
#   sudo bash install.sh --skip-ad --skip-backup
# ===================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT/.env"
EXAMPLE_FILE="$ROOT/.env.example"

HOST_IP_DEFAULT="192.168.0.2"
GATEWAY_DEFAULT="192.168.0.1"
DOMAIN_DEFAULT="sudoers.lan"
REALM_DEFAULT="SUDOERS.LAN"
NETBIOS_DEFAULT="SUDOERS"
DC_NAME_DEFAULT="dc1"
ZABBIX_IP_DEFAULT="192.168.0.3"

HOST_IP=""
GATEWAY_IP=""
DNS_DOMAIN=""
AD_REALM=""
AD_NETBIOS=""
DC_NAME=""
DC_FQDN=""
ZABBIX_IP=""

ARG_HOST_IP=""
ARG_GATEWAY=""
ARG_DOMAIN=""
ARG_REALM=""
ARG_NETBIOS=""
ARG_DC_NAME=""
ARG_ADMIN_PASS="${ADMIN_PASS:-}"
ARG_AD_USER_PASS="${AD_INITIAL_PASSWORD:-}"

CHECK_ONLY=0
ASSUME_YES=0
SET_IP=0
SKIP_AD=0
SKIP_DNS=0
SKIP_BACKUP=0
WITH_ZABBIX_AGENT=0
NO_SECRETS=0
VERBOSE=0
FINALIZED=0
ADMIN_PASS=""
AD_INITIAL_PASSWORD=""

STEP_NUM=0
STEP_NAMES=()
STEP_STATUSES=()
STEP_LOGS=()

LOG_DIR=""
LOG_ROOT=""
NOTES_FILE=""
STATUS_FILE=""
CRED_FILE=""

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

usage() {
    awk 'f && /^# =====/{exit} f{sub(/^# ?/,""); print} /^# =====/{f=1}' "$0"
}

die() {
    printf '\n%sERROR: %s%s\n' "$RED" "$*" "$RESET" >&2
    FINALIZED=1
    exit 1
}

cancel() {
    printf '\n%s%s%s\n' "$YELLOW" "$*" "$RESET"
    FINALIZED=1
    exit 0
}

note() {
    printf '%s\n' "$*" >>"$NOTES_FILE" 2>/dev/null || true
    printf 'AVISO: %s\n' "$*"
}

env_get() {
    local key="$1" val=""
    [ -r "$ENV_FILE" ] || { printf ''; return 0; }
    val="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    case "$val" in
        \"*\"|\'*\') ;;
        *) val="${val%%[[:space:]]#*}" ;;
    esac
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf '%s' "$val"
}

env_set() {
    local key="$1" val="$2" tmp
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    if grep -qE "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null; then
        tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
        awk -v k="$key" -v v="$val" '
            $0 ~ "^[[:space:]]*" k "=" { if (!done) { print k "=" v; done=1 } next }
            { print }
        ' "$ENV_FILE" >"$tmp"
        cat "$tmp" >"$ENV_FILE"
        rm -f "$tmp"
    else
        printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE" 2>/dev/null || true
}

load_config() {
    HOST_IP="${ARG_HOST_IP:-$(env_get HOST_IP)}"
    HOST_IP="${HOST_IP:-$HOST_IP_DEFAULT}"
    GATEWAY_IP="${ARG_GATEWAY:-$(env_get GATEWAY_IP)}"
    GATEWAY_IP="${GATEWAY_IP:-$GATEWAY_DEFAULT}"
    DNS_DOMAIN="${ARG_DOMAIN:-$(env_get DNS_DOMAIN)}"
    DNS_DOMAIN="${DNS_DOMAIN:-$DOMAIN_DEFAULT}"
    AD_REALM="${ARG_REALM:-$(env_get AD_REALM)}"
    AD_REALM="${AD_REALM:-$REALM_DEFAULT}"
    AD_NETBIOS="${ARG_NETBIOS:-$(env_get AD_NETBIOS)}"
    AD_NETBIOS="${AD_NETBIOS:-$NETBIOS_DEFAULT}"
    DC_NAME="${ARG_DC_NAME:-$DC_NAME_DEFAULT}"
    DC_FQDN="${DC_NAME}.${DNS_DOMAIN}"
    ZABBIX_IP="$(env_get ZABBIX_IP)"
    ZABBIX_IP="${ZABBIX_IP:-$ZABBIX_IP_DEFAULT}"
}

validate_config() {
    [[ "$HOST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "IP inválida: $HOST_IP"
    [[ "$GATEWAY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "gateway inválido: $GATEWAY_IP"
    [[ "$DNS_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || die "dominio inválido: $DNS_DOMAIN"
    [[ "$AD_REALM" =~ ^[A-Z0-9.-]+$ ]] || die "realm inválido: $AD_REALM"
    [[ "$AD_NETBIOS" =~ ^[A-Za-z0-9-]+$ ]] || die "NetBIOS inválido: $AD_NETBIOS"
    [[ "$DC_NAME" =~ ^[a-zA-Z0-9-]+$ ]] || die "hostname inválido: $DC_NAME"
}

setup_logging() {
    if [ "$(id -u)" -eq 0 ]; then
        LOG_ROOT="/var/log/tso-install"
    else
        LOG_ROOT="${TMPDIR:-/tmp}/tso-install"
    fi
    LOG_DIR="$LOG_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$LOG_DIR" 2>/dev/null || die "no se pudo crear $LOG_DIR"
    chmod 700 "$LOG_ROOT" "$LOG_DIR" 2>/dev/null || true
    NOTES_FILE="$LOG_DIR/avisos.txt"
    STATUS_FILE="$LOG_DIR/servicios.status"
    CRED_FILE="$LOG_DIR/credenciales.txt"
    : >"$NOTES_FILE"
    : >"$STATUS_FILE"
    : >"$CRED_FILE"
    chmod 600 "$NOTES_FILE" "$STATUS_FILE" "$CRED_FILE" 2>/dev/null || true
    {
        echo "install.sh — $(date -Is)"
        echo "Host: $(hostname -f 2>/dev/null || hostname)"
        if [ "$CHECK_ONLY" -eq 1 ]; then echo "Modo: --check (diagnóstico)"; else echo "Modo: instalación"; fi
        echo "IP objetivo: $HOST_IP"
        echo "Dominio: $DNS_DOMAIN  Realm: $AD_REALM"
    } >"$LOG_DIR/info.txt"
    chmod 600 "$LOG_DIR/info.txt" 2>/dev/null || true
}

banner() {
    printf '\n%s================================================================%s\n' "$BOLD" "$RESET"
    printf '%s  INSTALACIÓN UNIFICADA — %s / %s%s\n' "$BOLD" "$DC_NAME" "$DNS_DOMAIN" "$RESET"
    printf '%s================================================================%s\n' "$BOLD" "$RESET"
    printf '  Repo:       %s\n' "$ROOT"
    printf '  Host:       %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf '  IP objetivo:%s  (gateway %s)\n' "$HOST_IP" "$GATEWAY_IP"
    printf '  AD:         %s  (NetBIOS %s)\n' "$AD_REALM" "$AD_NETBIOS"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        printf '  Modo:       %sDIAGNÓSTICO (no modifica nada)%s\n' "$YELLOW" "$RESET"
    else
        printf '  Modo:       %sINSTALACIÓN%s\n' "$GREEN" "$RESET"
    fi
    printf '  Log:        %s\n' "$LOG_DIR"
    printf '%s================================================================%s\n\n' "$BOLD" "$RESET"
}

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$FINALIZED" -eq 0 ]; then
        printf '\n%sERROR inesperado (rc=%s). Revisá el log: %s%s\n' "$RED" "$rc" "${LOG_DIR:-?}" "$RESET" >&2
    fi
}
trap on_exit EXIT

# -------------------------------------------------------------------
# Ejecutor de fases
# -------------------------------------------------------------------
run_step() {
    local name="$1" critical="$2" fn="$3"
    local slug log rc status tail_pid=""

    STEP_NUM=$((STEP_NUM + 1))
    slug="$(printf '%02d-%s' "$STEP_NUM" \
        "$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')")"
    log="$LOG_DIR/${slug}.log"
    STEP_NAMES+=("$name")
    STEP_LOGS+=("$log")

    printf '\n%s==> [%d] %s%s\n' "$BOLD" "$STEP_NUM" "$name" "$RESET"
    printf '    %slog: %s%s\n' "$DIM" "$log" "$RESET"
    : >"$log"

    if [ "$VERBOSE" -eq 1 ]; then
        tail -n +1 -f "$log" &
        tail_pid=$!
    fi

    set +e
    ( set -euo pipefail; "$fn" ) >>"$log" 2>&1
    rc=$?
    set -e

    if [ -n "$tail_pid" ]; then
        sleep 0.2
        kill "$tail_pid" 2>/dev/null || true
        wait "$tail_pid" 2>/dev/null || true
    fi

    case "$rc" in
        0)
            status=PASS
            printf '    %s✔ OK%s\n' "$GREEN" "$RESET"
            ;;
        42)
            status=SKIP
            printf '    %s· SKIP%s\n' "$YELLOW" "$RESET"
            tail -n 5 "$log" | sed 's/^/    /' || true
            ;;
        43)
            status=WARN
            printf '    %s! AVISO%s\n' "$YELLOW" "$RESET"
            tail -n 8 "$log" | sed 's/^/    /' || true
            ;;
        *)
            status=FAIL
            printf '    %s✘ FALLÓ (rc=%s)%s\n' "$RED" "$rc" "$RESET"
            printf '    %sÚltimas líneas del log:%s\n' "$DIM" "$RESET"
            tail -n 40 "$log" | sed 's/^/    /' || true
            ;;
    esac
    STEP_STATUSES+=("$status")

    if [ "$CHECK_ONLY" -eq 1 ] && [ "$VERBOSE" -eq 0 ] && [ "$status" != FAIL ]; then
        sed 's/^/    /' "$log"
    fi

    if [ "$status" = FAIL ] && [ "$critical" -eq 1 ]; then
        printf '\n%sFase crítica fallida: %s%s\n' "$RED" "$name" "$RESET"
        finish
    fi
    return 0
}

# -------------------------------------------------------------------
# Tabla de estado de servicios (la llena la fase de verificación)
# -------------------------------------------------------------------
report_services() {
    [ -s "$STATUS_FILE" ] || {
        printf '\n%sESTADO DE SERVICIOS%s\n' "$BOLD" "$RESET"
        printf '  (no se llegó a la verificación; revisá los logs de las fases)\n'
        return 0
    }

    local st name detail icon color fails warns
    fails="$(awk -F'|' '$1=="FAIL"{n++} END{print n+0}' "$STATUS_FILE" 2>/dev/null || echo 0)"
    warns="$(awk -F'|' '$1=="WARN"{n++} END{print n+0}' "$STATUS_FILE" 2>/dev/null || echo 0)"

    printf '\n%s================================================================%s\n' "$BOLD" "$RESET"
    printf '%s  ESTADO DE SERVICIOS%s  (%s fallas, %s avisos)\n' "$BOLD" "$RESET" "${fails:-0}" "${warns:-0}"
    printf '%s================================================================%s\n' "$BOLD" "$RESET"
    while IFS='|' read -r st name detail; do
        case "$st" in
            SECTION)
                printf '\n  %s── %s ──%s\n' "$BLUE" "$name" "$RESET"
                ;;
            OK)
                printf '  %s✔%s %-38s %s\n' "$GREEN" "$RESET" "$name" "$detail"
                ;;
            FAIL)
                printf '  %s✘%s %-38s %s\n' "$RED" "$RESET" "$name" "$detail"
                ;;
            WARN)
                printf '  %s!%s %-38s %s\n' "$YELLOW" "$RESET" "$name" "$detail"
                ;;
            SKIP)
                printf '  %s·%s %-38s %s\n' "$DIM" "$RESET" "$name" "$detail"
                ;;
        esac
    done <"$STATUS_FILE"
    printf '\n'
}

# -------------------------------------------------------------------
# Reporte de accesos y credenciales (consola + archivo 600)
# -------------------------------------------------------------------
cred() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" >>"$CRED_FILE" 2>/dev/null || true
}

cred_secret() {
    local label="$1" value="$2" shown
    if [ -z "$value" ]; then
        cred "  $(printf '%-30s' "$label") (no definido / revisar .env)"
        return 0
    fi
    if [ "$NO_SECRETS" -eq 1 ]; then
        shown='******** (oculto por --no-secrets)'
    else
        shown="$value"
    fi
    cred "  $(printf '%-30s' "$label") $shown"
}

show_pairs() {
    local pairs="$1" entry u p
    if [ -z "$pairs" ]; then
        cred "    (sin cuentas definidas)"
        return 0
    fi
    for entry in $pairs; do
        u="${entry%%:*}"
        p="${entry#*:}"
        [ -n "$u" ] || continue
        cred_secret "    $u" "$p"
    done
}

report_credentials() {
    local ad_pass initial_pass mail_users files_users
    local grafana_user grafana_pass cups_user cups_pass files_admin_user files_admin_pass
    local pg_user pg_pass pg_db db_port cups_port portainer_port
    local radius_secret restic_repo restic_pass ssh_allowed ssh_user
    local admin_extra ca_file
    local -A ugroups=()
    local g u members all_users

    [ -f "$ENV_FILE" ] || {
        printf '\n%sACCESOS%s\n  (no existe .env; todavía no se generaron credenciales)\n' "$BOLD" "$RESET"
        return 0
    }

    ad_pass="$(env_get AD_ADMIN_PASSWORD)"
    [ -n "$ad_pass" ] || ad_pass="$ADMIN_PASS"
    initial_pass="$(env_get AD_INITIAL_PASSWORD)"
    [ -n "$initial_pass" ] || initial_pass="$AD_INITIAL_PASSWORD"
    mail_users="$(env_get MAIL_USERS)"
    files_users="$(env_get FILES_USERS)"
    grafana_user="$(env_get GRAFANA_ADMIN_USER)"; grafana_user="${grafana_user:-admin}"
    grafana_pass="$(env_get GRAFANA_ADMIN_PASSWORD)"
    cups_user="$(env_get CUPS_ADMIN_USER)"; cups_user="${cups_user:-admin}"
    cups_pass="$(env_get CUPS_ADMIN_PASS)"
    files_admin_user="$(env_get FILES_ADMIN_USER)"; files_admin_user="${files_admin_user:-admin}"
    files_admin_pass="$(env_get FILES_ADMIN_PASS)"
    pg_user="$(env_get POSTGRES_USER)"; pg_user="${pg_user:-tso}"
    pg_pass="$(env_get POSTGRES_PASSWORD)"
    pg_db="$(env_get POSTGRES_DB)"; pg_db="${pg_db:-tso}"
    db_port="$(env_get DB_PORT)"; db_port="${db_port:-5432}"
    cups_port="$(env_get CUPS_PORT)"; cups_port="${cups_port:-1631}"
    portainer_port="$(env_get PORTAINER_PORT)"; portainer_port="${portainer_port:-9443}"
    radius_secret="$(env_get RADIUS_SECRET)"
    restic_repo="$(env_get RESTIC_REPOSITORY)"; restic_repo="${restic_repo:-/srv/backup/repos/dc1}"
    restic_pass="$(env_get RESTIC_PASSWORD)"
    admin_extra="$(env_get ADMIN_IPS_EXTRA)"
    ca_file="$ROOT/services/web/tls/ca.crt"

    ssh_allowed="$(awk '/^[[:space:]]*AllowUsers[[:space:]]/{for(i=2;i<=NF;i++) printf "%s ", $i}' "$ROOT/server/sshd_config" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    ssh_user="${SUDO_USER:-}"
    if [ -z "$ssh_user" ] || [ "$ssh_user" = root ]; then
        for u in $ssh_allowed; do
            if getent passwd "$u" >/dev/null 2>&1; then ssh_user="$u"; break; fi
        done
    fi
    [ -n "$ssh_user" ] || ssh_user="${USER:-joaquin}"

    if command -v samba-tool >/dev/null 2>&1; then
        for g in admins sistemas contabilidad marketing oficina srv-dba srv-mail srv-files; do
            members="$(timeout 8 samba-tool group listmembers "$g" 2>/dev/null || true)"
            for u in $members; do
                if [ -n "${ugroups[$u]:-}" ]; then
                    ugroups["$u"]="${ugroups[$u]}, $g"
                else
                    ugroups["$u"]="$g"
                fi
            done
        done
        all_users="$(timeout 10 samba-tool user list 2>/dev/null || true)"
        for u in $all_users; do
            case "$u" in
                Administrator|Guest|krbtgt|dns-*|samba-*|*\$|'') continue ;;
            esac
            [ -n "${ugroups[$u]:-}" ] || ugroups["$u"]="(sin grupo listado)"
        done
    fi

    cred ""
    cred "=================================================================="
    cred "  ACCESOS DEL SERVIDOR — $DC_FQDN ($HOST_IP)"
    cred "  Generado: $(date -Is)"
    cred "=================================================================="
    cred "  ATENCIÓN: esta salida contiene contraseñas. No la compartas."
    cred "  Copia segura: $CRED_FILE (chmod 600)"
    if [ "$NO_SECRETS" -eq 1 ]; then
        cred "  (claves enmascaradas por --no-secrets)"
    fi

    cred ""
    cred "  ── Active Directory (Samba 4 nativo) ──"
    cred "  Dominio: $AD_REALM   NetBIOS: $AD_NETBIOS   DC: $DC_FQDN"
    cred_secret "  administrator (dominio)" "$ad_pass"
    if [ -n "$initial_pass" ]; then
        cred_secret "  usuarios AD (clave inicial)" "$initial_pass"
        cred "    (cambio obligatorio en el primer login; los usuarios ya"
        cred "     existentes pueden tener otra clave)"
    else
        cred "  usuarios AD (clave inicial)   (no registrada; la definiste al"
        cred "                                crear los usuarios)"
    fi
    if [ "${#ugroups[@]}" -gt 0 ]; then
        cred "  Usuarios del dominio:"
        while IFS= read -r u; do
            cred "    $(printf '%-12s' "$u") ${ugroups[$u]}"
        done < <(printf '%s\n' "${!ugroups[@]}" | sort)
    else
        cred "  Usuarios del dominio: (no se pudo consultar el AD con samba-tool)"
    fi
    cred "  Reset de clave AD:"
    cred "    sudo samba-tool user setpassword administrator"

    cred ""
    cred "  ── Acceso al servidor ──"
    cred "  SSH: ssh $ssh_user@$HOST_IP"
    cred "       usuarios permitidos: ${ssh_allowed:-joaquin david nicolas}"
    cred "       origen permitido: admin_ips (.50-.52) + ADMIN_IPS_EXTRA"
    cred "       ADMIN_IPS_EXTRA actual: ${admin_extra:-(vacío)}"
    cred "       autenticación: contraseña del usuario LOCAL del server"
    cred "  SMB: //$HOST_IP/departamentos  (o \\\\$HOST_IP\\departamentos)"
    cred "       usuario: $AD_NETBIOS\\<usuario AD>  /  clave del AD"

    cred ""
    cred "  ── Web (CA interna: $ca_file) ──"
    cred "  Portal:      https://$DNS_DOMAIN"
    cred "  Webmail:     https://webmail.$DNS_DOMAIN"
    cred "  Archivos:    https://archivos.$DNS_DOMAIN"
    cred "  Grafana:     https://grafana.$DNS_DOMAIN"
    cred "  Impresión:   https://print.$DNS_DOMAIN"
    cred "  Portainer:   https://portainer.$DNS_DOMAIN"
    cred "               (el admin de Portainer se crea en el primer acceso)"
    cred "  Instalar la CA en los clientes para evitar advertencias TLS."

    cred ""
    cred "  ── Webmail / correo ──"
    cred "  Servidor: mail.$DNS_DOMAIN  (SMTP 25/587, IMAP 143/993, POP3 110/995)"
    cred "  Cuentas (usuario / clave):"
    show_pairs "$mail_users"

    cred ""
    cred "  ── Gestor de archivos web (Filebrowser) ──"
    cred_secret "  admin: $files_admin_user" "$files_admin_pass"
    cred "  Usuarios adicionales:"
    show_pairs "$files_users"

    cred ""
    cred "  ── Grafana ──"
    cred_secret "  $grafana_user" "$grafana_pass"

    cred ""
    cred "  ── CUPS (impresión) ──"
    cred "  URL: https://print.$DNS_DOMAIN  (directo: https://$HOST_IP:$cups_port)"
    cred_secret "  $cups_user" "$cups_pass"

    cred ""
    cred "  ── PostgreSQL ──"
    cred "  Host: $HOST_IP:$db_port   base: $pg_db   usuario: $pg_user"
    cred_secret "  clave" "$pg_pass"
    cred "  (solo accesible desde admin_ips; ver server/nftables.conf)"

    cred ""
    cred "  ── WiFi 802.1X / FreeRADIUS ──"
    cred "  SSID: sudoers   (WPA2-Enterprise, PEAP/MSCHAPv2)"
    cred "  Usuario/clave: los del AD"
    cred_secret "  RADIUS_SECRET (router)" "$radius_secret"
    cred "  Router: RADIUS $HOST_IP:1812, mismo secreto."

    cred ""
    cred "  ── DHCP (Kea) ──"
    cred "  Subred: $(env_get DHCP_SUBNET)   pool: $(env_get DHCP_POOL)"
    cred "  DNS: $(env_get DHCP_DNS)   gateway: $(env_get DHCP_GATEWAY)   NTP: $(env_get DHCP_NTP)"

    cred ""
    cred "  ── Backup restic ──"
    cred "  Repo: $restic_repo"
    cred_secret "  RESTIC_PASSWORD" "$restic_pass"
    cred "  (guardá esta clave: sin ella no se puede restaurar)"

    cred ""
    cred "  ── Monitoreo ──"
    cred "  Prometheus:   http://127.0.0.1:9090  (túnel SSH)"
    cred "  Alertmanager: http://127.0.0.1:9093  (túnel SSH)"
    cred "    ssh -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 $ssh_user@$HOST_IP"
    cred "  Zabbix (server aparte $ZABBIX_IP): http://zabbix.$DNS_DOMAIN"
    cred "    login inicial: Admin / zabbix   ← CAMBIAR"

    cred ""
    cred "  ── Puertos de administración ──"
    cred "  Portainer: https://$HOST_IP:$portainer_port (autofirmado)"
    cred "    primer acceso: definir el usuario/clave de administrador"
    cred "  PostgreSQL: $HOST_IP:$db_port"
    cred "  CUPS: http://$HOST_IP:$cups_port"
    cred ""
}

# -------------------------------------------------------------------
# Resumen final
# -------------------------------------------------------------------
print_summary() {
    local i st icon color pfails=0 sfails=0
    local -a failed_logs=()

    for i in "${!STEP_NAMES[@]}"; do
        st="${STEP_STATUSES[$i]:-?}"
        [ "$st" = FAIL ] && { pfails=$((pfails + 1)); failed_logs+=("${STEP_NAMES[$i]}|${STEP_LOGS[$i]}"); }
    done
    if [ -s "$STATUS_FILE" ]; then
        sfails="$(awk -F'|' '$1=="FAIL"{n++} END{print n+0}' "$STATUS_FILE" 2>/dev/null || echo 0)"
    fi

    printf '\n%s================================================================%s\n' "$BOLD" "$RESET"
    printf '%s  RESUMEN DE LA INSTALACIÓN%s\n' "$BOLD" "$RESET"
    printf '%s================================================================%s\n' "$BOLD" "$RESET"
    for i in "${!STEP_NAMES[@]}"; do
        st="${STEP_STATUSES[$i]:-?}"
        case "$st" in
            PASS) icon="✔"; color="$GREEN" ;;
            SKIP) icon="·"; color="$YELLOW" ;;
            WARN) icon="!"; color="$YELLOW" ;;
            *)    icon="✘"; color="$RED" ;;
        esac
        printf '  %s%s%s %-8s %s\n' "$color" "$icon" "$RESET" "$st" "${STEP_NAMES[$i]}"
    done

    if [ -s "$NOTES_FILE" ]; then
        printf '\n  %sAVISOS / NOTAS:%s\n' "$YELLOW" "$RESET"
        awk '!seen[$0]++' "$NOTES_FILE" | sed 's/^/    - /'
    fi

    if [ "${#failed_logs[@]}" -gt 0 ]; then
        printf '\n  %sLOGS DE FASES FALLIDAS:%s\n' "$RED" "$RESET"
        for i in "${failed_logs[@]}"; do
            printf '    - %s\n      %s\n' "${i%%|*}" "${i#*|}"
        done
    fi

    printf '\n  %sPENDIENTE (manual):%s\n' "$BOLD" "$RESET"
    printf '    - Router: desactivar el DHCP (Kea es el único DHCP de la LAN).\n'
    printf '    - WiFi: poner el router en WPA2-Enterprise (RADIUS %s:1812).\n' "$HOST_IP"
    printf '    - Clientes: instalar la CA y unirlos al dominio:\n'
    printf '        clients/linux.md · clients/windows.md · clients/wifi.md\n'
    printf '    - Zabbix (server %s): cambiar Admin/zabbix y revisar el envío\n' "$ZABBIX_IP"
    printf '      de alertas por mail (pendiente documentado en AGENTS.md).\n'
    printf '    - Backup: si no se instaló, montar el disco en /srv/backup y\n'
    printf '      correr: sudo bash server/backup.sh install\n'

    printf '\n  Log completo: %s\n' "$LOG_DIR"
    printf '  Credenciales: %s (chmod 600)\n' "$CRED_FILE"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        printf '  Modo diagnóstico: no se modificó nada.\n'
    fi

    if [ "$pfails" -gt 0 ] || [ "${sfails:-0}" -gt 0 ]; then
        printf '\n  %sESTADO: CON ERRORES%s (%s fases, %s servicios)\n' "$RED" "$RESET" "$pfails" "${sfails:-0}"
        printf '  Reintentar (idempotente): sudo bash install.sh\n'
        printf '  Diagnóstico sin cambios:  sudo bash install.sh --check --no-secrets\n'
    else
        printf '\n  %sESTADO: OK — servicios verificados%s\n' "$GREEN" "$RESET"
    fi
    printf '%s================================================================%s\n\n' "$BOLD" "$RESET"
}

finish() {
    local rc=0
    if [ "$FINALIZED" -eq 0 ]; then
        FINALIZED=1
        report_services || true
        report_credentials || true
        print_summary || true
    fi
    local st
    for st in "${STEP_STATUSES[@]:-}"; do
        [ "$st" = FAIL ] && rc=1
    done
    if [ -s "$STATUS_FILE" ]; then
        local sf
        sf="$(awk -F'|' '$1=="FAIL"{n++} END{print n+0}' "$STATUS_FILE" 2>/dev/null || echo 0)"
        [ "${sf:-0}" -gt 0 ] && rc=1
    fi
    exit "$rc"
}

# -------------------------------------------------------------------
# Fase 0: preflight (solo lectura)
# -------------------------------------------------------------------
phase_preflight() {
    local fail=0 missing=0 avail mem route allowed found u svc current_ips mode
    p_ok()   { printf '[OK]     %s\n' "$*"; }
    p_warn() { printf '[AVISO]  %s\n' "$*"; note "$*"; }
    p_bad()  { printf '[ERROR]  %s\n' "$*"; fail=$((fail + 1)); }
    p_info() { printf '[INFO]   %s\n' "$*"; }

    if [ "$(id -u)" -eq 0 ]; then
        p_ok "ejecutando como root"
    elif [ "$CHECK_ONLY" -eq 1 ]; then
        p_warn "sin root: algunos chequeos pueden faltar (diagnóstico)"
    else
        p_bad "se requiere root: sudo bash install.sh"
    fi

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ "${ID:-}" = debian ]; then
            p_ok "SO: ${PRETTY_NAME:-Debian}"
        else
            p_bad "SO ${PRETTY_NAME:-desconocido}: se requiere Debian 12/13"
        fi
        case "${VERSION_ID:-}" in
            12|13) p_ok "versión Debian ${VERSION_ID}" ;;
            *)     p_warn "probado en Debian 12/13; esta es ${VERSION_ID:-?}" ;;
        esac
    else
        p_bad "no existe /etc/os-release"
    fi

    [ -d /run/systemd/system ] && p_ok "systemd presente" || p_bad "systemd no está corriendo (¿contenedor?)"
    command -v apt-get >/dev/null 2>&1 && p_ok "apt-get presente" || p_bad "falta apt-get"

    for f in docker-compose.yml .env.example dc/provision.sh dc/add-users-groups.sh \
             dc/dns-records.sh server/deploy.sh services/web/tls-gen.sh services/web/nginx.conf; do
        if [ -f "$ROOT/$f" ]; then
            :
        else
            p_bad "falta $f (¿repo incompleto?)"
            missing=$((missing + 1))
        fi
    done
    [ "$missing" -eq 0 ] && p_ok "archivos del repo presentes"

    avail="$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}' || true)"
    avail="${avail:-0}"
    if [ "$avail" -lt 5242880 ]; then
        p_warn "poco espacio libre en /: $((avail / 1024)) MB (se recomiendan 5 GB)"
    else
        p_ok "espacio libre en /: $((avail / 1024 / 1024)) GB"
    fi
    mem="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if [ "${mem:-0}" -lt 1800 ]; then
        p_warn "RAM: ${mem} MB (se recomiendan 2 GB+)"
    else
        p_ok "RAM: ${mem} MB"
    fi

    route="$(ip route show default 2>/dev/null | head -n1 || true)"
    if [ -n "$route" ]; then
        p_ok "ruta por defecto: $route"
    else
        p_bad "no hay ruta por defecto (sin red no se puede instalar)"
    fi
    if getent hosts deb.debian.org >/dev/null 2>&1; then
        p_ok "resolución DNS externa (deb.debian.org)"
    else
        p_warn "no resuelve deb.debian.org; revisá DNS/Internet antes de continuar"
    fi

    current_ips="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    if printf '%s\n' "$current_ips" | grep -Fxq "$HOST_IP"; then
        p_ok "IP objetivo $HOST_IP ya configurada"
    else
        p_warn "la IP objetivo $HOST_IP NO está configurada (usá --set-ip --yes o server/set-ip.sh)"
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            p_ok "docker + docker compose presentes"
        else
            p_warn "docker presente pero falta docker compose (se instalará)"
        fi
        if docker info >/dev/null 2>&1; then
            p_ok "daemon Docker responde"
        else
            p_warn "daemon Docker no responde (se intentará iniciar)"
        fi
    else
        p_warn "Docker no está instalado (se instalará)"
    fi

    if [ -f /var/lib/samba/private/sam.ldb ]; then
        p_ok "AD ya provisionado (no se vuelve a provisionar)"
    else
        p_info "AD sin provisionar: se creará el dominio $AD_REALM"
    fi

    if [ -f "$ENV_FILE" ]; then
        mode="$(stat -c %a "$ENV_FILE" 2>/dev/null || echo '?')"
        if [ "$mode" = "600" ]; then p_ok ".env existe con permisos 600"; else p_warn ".env con permisos $mode (debería ser 600)"; fi
    else
        p_info ".env no existe: se generará con server/gen-env.sh"
    fi

    allowed="$(awk '/^[[:space:]]*AllowUsers[[:space:]]/{for(i=2;i<=NF;i++) printf "%s ", $i}' "$ROOT/server/sshd_config" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    found=0
    for u in $allowed; do
        getent passwd "$u" >/dev/null 2>&1 && found=1
    done
    if [ "$found" -eq 1 ]; then
        p_ok "usuarios SSH permitidos existen localmente: $allowed"
    else
        p_warn "ninguno de los usuarios SSH ($allowed) existe en esta máquina: creá uno ANTES del deploy"
    fi

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        p_warn "systemd-resolved activo: se desactivará (Samba DNS necesita el puerto 53)"
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        p_warn "NetworkManager activo: set-ip.sh no lo soporta; si la IP ya es $HOST_IP se continúa"
    fi
    for svc in apache2 nginx postfix dovecot dnsmasq bind9 named ufw firewalld; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            p_warn "servicio del host activo: $svc (puede chocar con los contenedores)"
        fi
    done

    if [ "$fail" -gt 0 ]; then
        printf '\n[ERROR] preflight con %s error(es) crítico(s)\n' "$fail"
        exit 1
    fi
    printf '\n[OK] preflight completado\n'
}

# -------------------------------------------------------------------
# Fase 1: identidad del host (hostname, /etc/hosts, DNS temporal, TZ)
# -------------------------------------------------------------------
phase_host() {
    if [ "$(hostname -s)" = "$DC_NAME" ]; then
        echo "hostname OK: $DC_NAME"
    else
        hostnamectl set-hostname "$DC_NAME"
        echo "hostname -> $DC_NAME"
    fi
    hostnamectl set-location "$DNS_DOMAIN" 2>/dev/null || true

    if ! grep -qE "^${HOST_IP//./\\.}[[:space:]]+${DC_FQDN//./\\.}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
        sed -i "\|${DC_FQDN}|d" /etc/hosts
        sed -i "1i ${HOST_IP} ${DC_FQDN} ${DC_NAME}" /etc/hosts
        echo "/etc/hosts: agregado $HOST_IP $DC_FQDN $DC_NAME"
    fi
    sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
    if getent hosts "$DC_FQDN" 2>/dev/null | grep -q "$HOST_IP"; then
        echo "resolución local OK: $DC_FQDN -> $HOST_IP"
    else
        echo "ERROR: $DC_FQDN no resuelve a $HOST_IP en /etc/hosts"
        exit 1
    fi

    timedatectl set-timezone America/Argentina/Buenos_Aires 2>/dev/null || true

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "Desactivando systemd-resolved (Samba DNS usa el puerto 53)..."
        systemctl disable --now systemd-resolved 2>/dev/null || true
    fi
    if [ -L /etc/resolv.conf ]; then
        cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        rm -f /etc/resolv.conf
    fi
    if ! grep -qE '^nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null \
       || grep -qE '^nameserver[[:space:]]+127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
        [ -f /etc/resolv.conf ] && cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        printf 'nameserver %s\nnameserver 1.1.1.1\nsearch %s\n' "$GATEWAY_IP" "$DNS_DOMAIN" > /etc/resolv.conf
        chmod 644 /etc/resolv.conf
        echo "/etc/resolv.conf temporal: $GATEWAY_IP + 1.1.1.1"
    fi
    if getent hosts deb.debian.org >/dev/null 2>&1; then
        echo "DNS externo OK"
    else
        echo "AVISO: sin DNS externo; apt/Docker pueden fallar"
    fi
}

# -------------------------------------------------------------------
# Fase 2: paquetes base + Docker
# -------------------------------------------------------------------
ensure_docker() {
    if docker compose version >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        echo "docker compose ya instalado: $(docker compose version 2>/dev/null | head -n1)"
        return 0
    fi

    echo "Instalando Docker desde Debian (docker.io + docker-compose)..."
    if apt-get install -y --no-install-recommends docker.io docker-compose; then
        :
    else
        echo "AVISO: falló la instalación desde Debian; se probará el repo oficial"
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true

    if docker compose version >/dev/null 2>&1; then
        echo "docker compose OK (paquete Debian)"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        mkdir -p /usr/local/lib/docker/cli-plugins
        ln -sf "$(command -v docker-compose)" /usr/local/lib/docker/cli-plugins/docker-compose
        if docker compose version >/dev/null 2>&1; then
            echo "docker compose OK (plugin enlazado)"
            return 0
        fi
    fi

    echo "Instalando Docker CE desde el repo oficial..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
        "$(dpkg --print-architecture)" "${VERSION_CODENAME:-bookworm}" \
        >/etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker

    local i
    for i in $(seq 1 30); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
    if ! docker info >/dev/null 2>&1; then
        systemctl status docker --no-pager 2>/dev/null || true
        echo "ERROR: el daemon Docker no arranca"
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo "ERROR: docker compose no quedó disponible"
        return 1
    fi
    echo "docker compose OK (repo oficial)"
}

phase_packages() {
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    echo "==> apt-get update"
    apt-get update

    local pkgs=(
        samba samba-ad-dc samba-ad-provision krb5-user krb5-config
        chrony dnsutils acl attr smbclient samba-common-bin
        restic freeradius freeradius-utils nftables
        curl openssl sudo ca-certificates git iproute2 iputils-ping
    )
    echo "==> instalando paquetes base: ${pkgs[*]}"
    apt-get install -y --no-install-recommends "${pkgs[@]}"

    # El paquete samba arranca smbd/nmbd/winbind standalone; el DC nativo
    # los maneja. Se paran para que no peleen por los puertos.
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true

    ensure_docker
    echo "paquetes base y Docker listos"
}

# -------------------------------------------------------------------
# Fase 3: NTP (chrony)
# -------------------------------------------------------------------
phase_ntp() {
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        systemctl disable --now systemd-timesyncd 2>/dev/null || true
    fi
    [ -f /etc/chrony/chrony.conf ] && \
        cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    cp "$ROOT/server/chrony.conf" /etc/chrony/chrony.conf
    systemctl enable --now chrony
    systemctl restart chrony
    sleep 1
    if ! systemctl is-active --quiet chrony; then
        journalctl -u chrony -n 30 --no-pager 2>/dev/null || true
        echo "ERROR: chrony no está activo"
        exit 1
    fi
    chronyc tracking 2>/dev/null || true
    echo "chrony activo (NTP para la LAN en el puerto 123/udp)"
}

# -------------------------------------------------------------------
# Fase 4: .env y secretos
# -------------------------------------------------------------------
phase_env() {
    echo "==> server/gen-env.sh (salida de secretos descartada)"
    # gen-env imprime los secretos generados por stdout; no queremos que
    # queden en el log. El resumen final los lee de .env.
    bash "$ROOT/server/gen-env.sh" >/dev/null

    [ -f "$ENV_FILE" ] || { echo "ERROR: gen-env.sh no creó .env"; exit 1; }
    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE" 2>/dev/null || true

    [ -n "$ARG_HOST_IP" ]  && env_set HOST_IP "$ARG_HOST_IP"
    [ -n "$ARG_GATEWAY" ]  && env_set GATEWAY_IP "$ARG_GATEWAY"
    [ -n "$ARG_DOMAIN" ]   && env_set DNS_DOMAIN "$ARG_DOMAIN"
    [ -n "$ARG_REALM" ]    && env_set AD_REALM "$ARG_REALM"
    [ -n "$ARG_NETBIOS" ]  && env_set AD_NETBIOS "$ARG_NETBIOS"
    [ -n "$(env_get HOST_IP)" ]     || env_set HOST_IP "$HOST_IP"
    [ -n "$(env_get GATEWAY_IP)" ]  || env_set GATEWAY_IP "$GATEWAY_IP"
    [ -n "$(env_get DNS_DOMAIN)" ]  || env_set DNS_DOMAIN "$DNS_DOMAIN"
    [ -n "$(env_get AD_REALM)" ]    || env_set AD_REALM "$AD_REALM"
    [ -n "$(env_get AD_NETBIOS)" ]  || env_set AD_NETBIOS "$AD_NETBIOS"

    # Mantener el acceso SSH actual: la IP de origen se agrega a admin_ips
    # extra (server/deploy.sh la inyecta en nftables). Sin esto, aplicar el
    # firewall podría cortar la sesión.
    local ssh_ips existing all
    ssh_ips=""
    [ -n "${SSH_CONNECTION:-}" ] && ssh_ips="${SSH_CONNECTION%% *}"
    ssh_ips="$ssh_ips
$(who 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p' || true)"
    existing="$(env_get ADMIN_IPS_EXTRA)"
    all="$(printf '%s\n%s\n' "$ssh_ips" "$existing" \
        | tr ' ' '\n' \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    if [ -n "$all" ]; then
        env_set ADMIN_IPS_EXTRA "\"$all\""
        echo "ADMIN_IPS_EXTRA=$all"
    fi

    local missing="" k
    for k in RADIUS_SECRET ROUNDCUBE_DES_KEY GF_SECRET_KEY GRAFANA_ADMIN_PASSWORD \
             RESTIC_PASSWORD POSTGRES_PASSWORD CUPS_ADMIN_PASS FILES_ADMIN_PASS; do
        if [ -z "$(env_get "$k")" ]; then
            missing="$missing $k"
        fi
        case "$(env_get "$k")" in
            *Cambiar*) missing="$missing $k(placeholder)" ;;
        esac
    done
    if ! printf '%s' "$(env_get MAIL_USERS)" | grep -q ':'; then
        missing="$missing MAIL_USERS"
    fi
    if ! printf '%s' "$(env_get FILES_USERS)" | grep -q ':'; then
        missing="$missing FILES_USERS"
    fi
    if [ -n "$missing" ]; then
        echo "ERROR: faltan valores válidos en .env:$missing"
        echo "Revisá .env o ejecutá: bash server/gen-env.sh"
        exit 1
    fi
    if ! [[ "$(env_get RADIUS_SECRET)" =~ ^[A-Za-z0-9]{16,64}$ ]]; then
        echo "ERROR: RADIUS_SECRET debe ser alfanumérico de 16 a 64 caracteres"
        exit 1
    fi
    echo ".env listo (permisos 600); secretos obligatorios presentes"
}

# -------------------------------------------------------------------
# Credenciales de AD: se preparan ANTES de provisionar para no perderlas
# -------------------------------------------------------------------
ad_ready() { [ -f /var/lib/samba/private/sam.ldb ]; }

generate_admin_pass() { printf 'Admin!%s' "$(openssl rand -hex 8)"; }
generate_user_pass()  { printf 'User!%s'  "$(openssl rand -hex 6)"; }

prepare_ad_credentials() {
    local ready=0 tty=0 _p2=""
    ad_ready && ready=1
    [ -t 0 ] && tty=1

    if [ "$SKIP_AD" -eq 1 ] && [ "$ready" -eq 0 ]; then
        die "--skip-ad pedido pero el AD no está provisionado (falta /var/lib/samba/private/sam.ldb)"
    fi

    ADMIN_PASS="${ARG_ADMIN_PASS:-${ADMIN_PASS:-}}"
    [ -n "$ADMIN_PASS" ] || ADMIN_PASS="$(env_get AD_ADMIN_PASSWORD)"

    if [ "$ready" -eq 0 ]; then
        if [ -z "$ADMIN_PASS" ]; then
            if [ "$ASSUME_YES" -eq 1 ] || [ "$tty" -eq 0 ]; then
                ADMIN_PASS="$(generate_admin_pass)"
                printf 'Se generó una clave para administrator del AD.\n'
            else
                printf 'Clave para administrator del dominio %s\n' "$AD_REALM"
                read -r -s -p '  Clave: ' ADMIN_PASS; echo
                read -r -s -p '  Repetir: ' _p2; echo
                [ "$ADMIN_PASS" = "$_p2" ] || die "las claves no coinciden"
                [ -n "$ADMIN_PASS" ] || die "la clave no puede quedar vacía"
            fi
        fi
        # Guardar ANTES de provisionar: si algo falla después, la clave
        # queda recuperable en .env.
        env_set AD_ADMIN_PASSWORD "$ADMIN_PASS"
        printf 'Clave de administrator guardada en .env (se muestra al final).\n'
    elif [ -z "$ADMIN_PASS" ] && [ "$SKIP_DNS" -eq 0 ]; then
        if [ "$ASSUME_YES" -eq 0 ] && [ "$tty" -eq 1 ]; then
            printf 'Clave de administrator para crear registros DNS (Enter = omitir): '
            read -r -s ADMIN_PASS; echo
        fi
        if [ -z "$ADMIN_PASS" ]; then
            note "Sin clave de administrator: los registros DNS de servicios no se pudieron crear/actualizar"
        fi
    fi

    AD_INITIAL_PASSWORD="${ARG_AD_USER_PASS:-${AD_INITIAL_PASSWORD:-}}"
    [ -n "$AD_INITIAL_PASSWORD" ] || AD_INITIAL_PASSWORD="$(env_get AD_INITIAL_PASSWORD)"

    if [ -z "$AD_INITIAL_PASSWORD" ] && [ "$ready" -eq 0 ]; then
        if [ "$ASSUME_YES" -eq 1 ] || [ "$tty" -eq 0 ]; then
            AD_INITIAL_PASSWORD="$(generate_user_pass)"
            printf 'Se generó la clave inicial de los usuarios AD.\n'
        else
            printf 'Clave inicial para los usuarios AD (Enter = generar): '
            read -r -s AD_INITIAL_PASSWORD; echo
            [ -n "$AD_INITIAL_PASSWORD" ] || AD_INITIAL_PASSWORD="$(generate_user_pass)"
        fi
    fi
    # Si el AD ya existía y no tenemos la clave inicial, no inventamos una:
    # el panel final dirá "no registrada".
    [ -n "$AD_INITIAL_PASSWORD" ] && env_set AD_INITIAL_PASSWORD "$AD_INITIAL_PASSWORD"
    export ADMIN_PASS AD_INITIAL_PASSWORD
    printf 'Credenciales de AD listas (se muestran en el resumen final).\n'
}

# -------------------------------------------------------------------
# Fase 5: Active Directory (Samba 4 nativo)
# -------------------------------------------------------------------
phase_ad() {
    if [ "$SKIP_AD" -eq 1 ]; then
        ad_ready || { echo "ERROR: --skip-ad pero no hay AD provisionado"; exit 1; }
        echo "AD existente; --skip-ad: no se provisiona ni se tocan usuarios"
    else
        if ad_ready; then
            echo "AD ya provisionado: no se vuelve a provisionar"
        else
            [ -n "$ADMIN_PASS" ] || { echo "ERROR: falta ADMIN_PASS"; exit 1; }
            echo "==> dc/provision.sh (dominio $AD_REALM)"
            REALM="$AD_REALM" DOMAIN="$DNS_DOMAIN" NETBIOS="$AD_NETBIOS" \
            DC_FQDN="$DC_NAME" IP_SERVER="$HOST_IP" DNS_FORWARDER="$GATEWAY_IP" \
                bash "$ROOT/dc/provision.sh"
        fi
    fi

    local unit="samba"
    systemctl cat samba-ad-dc.service >/dev/null 2>&1 && unit="samba-ad-dc"
    systemctl enable --now "$unit" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 30); do
        systemctl is-active --quiet "$unit" && break
        sleep 1
    done
    if ! systemctl is-active --quiet "$unit"; then
        journalctl -u "$unit" -n 40 --no-pager 2>/dev/null || true
        echo "ERROR: el servicio $unit no está activo"
        exit 1
    fi
    echo "servicio $unit activo"

    if [ "$SKIP_AD" -eq 0 ]; then
        local before after
        before="$(timeout 20 samba-tool user list 2>/dev/null | sort || true)"
        echo "==> dc/add-users-groups.sh"
        AD_INITIAL_PASSWORD="$AD_INITIAL_PASSWORD" bash "$ROOT/dc/add-users-groups.sh"
        after="$(timeout 20 samba-tool user list 2>/dev/null | sort || true)"
        if [ "$before" != "$after" ]; then
            env_set AD_INITIAL_PASSWORD "$AD_INITIAL_PASSWORD"
            echo "usuarios nuevos creados; clave inicial guardada en .env"
        fi
        echo "==> dc/password-policy.sh"
        bash "$ROOT/dc/password-policy.sh"
    fi

    # Permisos de los shares: grupo AD srv-files si NSS lo resuelve.
    local grp="${AD_NETBIOS}\\srv-files" d gid gsrc
    if getent group "$grp" >/dev/null 2>&1; then
        for d in /srv/samba/departamentos /srv/samba/respaldo; do
            [ -d "$d" ] || continue
            chgrp "$grp" "$d"
            chmod 2770 "$d"
        done
        echo "shares con grupo $grp (2770)"
    else
        note "No se pudo resolver el grupo AD '$grp' por NSS: los shares quedan root:root (revisá winbind/NSS)"
    fi
    gid="$(stat -c %g /srv/samba/departamentos 2>/dev/null || echo 0)"
    gsrc="$(stat -c %G /srv/samba/departamentos 2>/dev/null || echo '?')"
    env_set FILES_GID "$gid"
    echo "FILES_GID=$gid ($gsrc)"

    local users groups
    users="$(timeout 20 samba-tool user list 2>/dev/null | wc -l || echo 0)"
    groups="$(timeout 20 samba-tool group list 2>/dev/null | wc -l || echo 0)"
    echo "AD listo: $users usuarios, $groups grupos"
}

# -------------------------------------------------------------------
# Fase 6: DNS del dominio + registros de servicios
# -------------------------------------------------------------------
phase_dns() {
    if [ "$SKIP_DNS" -eq 1 ]; then
        echo "SKIP: --skip-dns"
        exit 42
    fi

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl disable --now systemd-resolved 2>/dev/null || true
    fi

    local i ns="" got
    for i in $(seq 1 30); do
        ss -Huln 'sport = :53' 2>/dev/null | grep -q . && break
        sleep 1
    done
    if dig +short +time=1 +tries=1 @127.0.0.1 "$DNS_DOMAIN" SOA 2>/dev/null | grep -q .; then
        ns="127.0.0.1"
    elif dig +short +time=1 +tries=1 @"$HOST_IP" "$DNS_DOMAIN" SOA 2>/dev/null | grep -q .; then
        ns="$HOST_IP"
        note "El DNS del DC no responde en 127.0.0.1; se usa $HOST_IP"
    else
        echo "ERROR: el DNS de Samba no responde para la zona $DNS_DOMAIN"
        ss -Huln 'sport = :53' 2>/dev/null || true
        exit 1
    fi

    [ -f /etc/resolv.conf ] && cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    printf 'nameserver %s\nsearch %s\n' "$ns" "$DNS_DOMAIN" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    echo "/etc/resolv.conf -> nameserver $ns, search $DNS_DOMAIN"

    if dig +short +time=2 +tries=1 @"$ns" deb.debian.org A 2>/dev/null | grep -qE '^[0-9]+\.'; then
        echo "forwarder DNS externo OK"
    else
        note "El forwarder DNS ($GATEWAY_IP) no resuelve Internet; revisá el DNS del router"
    fi

    local names="dc1 mail webmail archivos grafana portainer web www" missing="" n
    for n in $names; do
        got="$(dig +short +time=1 +tries=1 @"$ns" "$n.$DNS_DOMAIN" A 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1 || true)"
        [ "$got" = "$HOST_IP" ] || missing="$missing $n.$DNS_DOMAIN"
    done
    if [ -z "$ADMIN_PASS" ]; then
        if [ -z "$missing" ]; then
            echo "registros DNS ya presentes (sin clave de administrator)"
            exit 0
        fi
        echo "ERROR: faltan registros DNS y no hay clave de administrator:$missing"
        echo "Ejecutá: sudo kinit administrator && sudo bash dc/dns-records.sh"
        exit 1
    fi

    echo "==> kinit administrator"
    got="$(printf '%s\n' "$ADMIN_PASS" | timeout 20 kinit administrator 2>&1)" || {
        printf '%s\n' "$got"
        echo "ERROR: kinit administrator falló (clave incorrecta o KDC caído)"
        exit 1
    }
    env_set AD_ADMIN_PASSWORD "$ADMIN_PASS"

    echo "==> dc/dns-records.sh"
    SERVER="$DC_FQDN" ZONE="$DNS_DOMAIN" PROXY_IP="$HOST_IP" ZABBIX_IP="$ZABBIX_IP" \
        bash "$ROOT/dc/dns-records.sh"
    kdestroy 2>/dev/null || true
    echo "registros DNS de servicios listos"
}

# -------------------------------------------------------------------
# Fase 7: TLS del proxy inverso
# -------------------------------------------------------------------
phase_tls() {
    local crt="$ROOT/services/web/tls/server.crt"
    if [ -s "$crt" ] && openssl x509 -checkend 604800 -noout -in "$crt" >/dev/null 2>&1; then
        echo "certificado existente y vigente: $crt"
        exit 0
    fi
    echo "==> services/web/tls-gen.sh"
    DOMAIN="$DNS_DOMAIN" HOST="$DC_NAME" bash "$ROOT/services/web/tls-gen.sh"
    [ -s "$crt" ] && [ -s "$ROOT/services/web/tls/server.key" ] || {
        echo "ERROR: no se generaron los certificados TLS"
        exit 1
    }
    echo "TLS wildcard generado para *.$DNS_DOMAIN"
}

# -------------------------------------------------------------------
# Fase 8: deploy (firewall + SSH + chrony + FreeRADIUS + contenedores)
# -------------------------------------------------------------------
phase_deploy() {
    local allowed found u src extra

    allowed="$(awk '/^[[:space:]]*AllowUsers[[:space:]]/{for(i=2;i<=NF;i++) printf "%s ", $i}' "$ROOT/server/sshd_config" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    found=0
    for u in $allowed; do
        getent passwd "$u" >/dev/null 2>&1 && found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "ERROR: ninguno de los usuarios SSH permitidos ($allowed) existe localmente."
        echo "El sshd_config del repo dejaría el server sin acceso SSH (root está deshabilitado)."
        echo "Creá uno antes de continuar, por ejemplo:"
        echo "  sudo adduser joaquin && sudo usermod -aG sudo joaquin"
        echo "o editá AllowUsers en server/sshd_config."
        exit 1
    fi

    src="${SSH_CONNECTION:-}"
    src="${src%% *}"
    if [ -n "$src" ]; then
        extra="$(env_get ADMIN_IPS_EXTRA)"
        if ! printf '%s\n' "$extra" | tr ' ' '\n' | grep -Fxq "$src" \
           && ! grep -qE "(^|[^0-9.])${src//./\\.}([^0-9.]|$)" "$ROOT/server/nftables.conf" 2>/dev/null; then
            echo "ERROR: la IP de origen SSH $src no está permitida en el firewall."
            echo "Agregala a ADMIN_IPS_EXTRA en .env antes de aplicar nftables."
            exit 1
        fi
        echo "origen SSH $src permitido por el firewall"
    fi

    echo "==> server/deploy.sh"
    bash "$ROOT/server/deploy.sh"
    echo "deploy completado (contenedores levantados)"
}

# Pregunta por el DHCP del router justo antes de levantar Kea.
confirm_router_dhcp() {
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx tso-dhcp; then
        printf '%sKea ya está corriendo; se asume el DHCP del router apagado.%s\n' "$YELLOW" "$RESET"
        return 0
    fi
    printf '\n%sATENCIÓN:%s Kea va a ser el DHCP de la LAN (192.168.0.100-199).\n' "$BOLD" "$RESET"
    printf 'El DHCP del router TP-Link DEBE estar apagado para no repartir IPs en paralelo.\n'
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf '%sModo --yes: continuando; verificá el router después.%s\n' "$YELLOW" "$RESET"
        return 0
    fi
    [ -t 0 ] || die "sin TTY: desactivá el DHCP del router y usá --yes"
    local ans
    read -r -p '¿Ya desactivaste el DHCP del router? [s/N] ' ans
    case "$ans" in
        s|S|si|SI|sí|SÍ) ;;
        *) die "desactivá el DHCP del router y volvé a correr install.sh" ;;
    esac
}

# -------------------------------------------------------------------
# Fase 9: backup restic (opcional; requiere disco montado)
# -------------------------------------------------------------------
phase_backup() {
    if [ "$SKIP_BACKUP" -eq 1 ]; then
        echo "SKIP: --skip-backup"
        exit 42
    fi
    local repo mp q
    repo="$(env_get RESTIC_REPOSITORY)"
    repo="${repo:-/srv/backup/repos/dc1}"
    mp=""
    q="$repo"
    while [ "$q" != "/" ]; do
        if [ -e "$q" ] && mountpoint -q "$q" 2>/dev/null; then
            mp="$q"
            break
        fi
        q="$(dirname "$q")"
    done
    if [ -z "$mp" ] || [ "$mp" = "/" ]; then
        echo "SKIP: $repo no está sobre un disco montado."
        echo "Montá el disco de backup en /srv/backup y ejecutá:"
        echo "  sudo bash server/backup.sh install"
        exit 42
    fi
    echo "disco de backup montado en $mp"
    echo "==> server/backup.sh install"
    bash "$ROOT/server/backup.sh" install
    echo "backup restic instalado (cron diario 02:30)"
}

# -------------------------------------------------------------------
# Fase 10: agente Zabbix (opcional)
# -------------------------------------------------------------------
phase_zabbix() {
    echo "==> services/zabbix/install-agent.sh dc1"
    if ! bash "$ROOT/services/zabbix/install-agent.sh" dc1; then
        echo "AVISO: no se pudo instalar zabbix-agent2 (repo externo o red)."
        echo "El resto del servidor no depende de esto."
        exit 43
    fi
    echo "zabbix-agent2 instalado (pasivo 10050, server $ZABBIX_IP)"
}

# -------------------------------------------------------------------
# Helpers de verificación (los usa phase_verify)
# -------------------------------------------------------------------
VERIFY_FAILS=0

v_add() {
    local st="$1" name="$2" detail="${3:-}"
    detail="${detail//|/ }"
    printf '%s|%s|%s\n' "$st" "$name" "$detail" >>"$STATUS_FILE"
}
v_section() { v_add SECTION "$1" ""; }
v_ok()      { v_add OK   "$1" "${2:-}"; printf '[OK]    %s: %s\n' "$1" "${2:-}"; }
v_warn()    { v_add WARN "$1" "${2:-}"; printf '[AVISO] %s: %s\n' "$1" "${2:-}"; }
v_skip()    { v_add SKIP "$1" "${2:-}"; printf '[SKIP]  %s: %s\n' "$1" "${2:-}"; }
v_fail()    {
    v_add FAIL "$1" "${2:-}"
    printf '[ERROR] %s: %s\n' "$1" "${2:-}"
    VERIFY_FAILS=$((VERIFY_FAILS + 1))
}

port_open() {
    local proto="$1" port="$2"
    case "$proto" in
        tcp) ss -Htln "sport = :$port" 2>/dev/null | grep -q . ;;
        udp) ss -Huln "sport = :$port" 2>/dev/null | grep -q . ;;
        *) return 1 ;;
    esac
}

check_ports() {
    local label="$1" proto="$2" ports="$3" mode="${4:-core}" p missing=""
    for p in $ports; do
        port_open "$proto" "$p" || missing="$missing $p"
    done
    if [ -z "$missing" ]; then
        v_ok "$label" "escuchando ($ports/$proto)"
    elif [ "$mode" = "warn" ]; then
        v_warn "$label" "faltan:$missing ($proto)"
    else
        v_fail "$label" "faltan:$missing ($proto)"
    fi
}

dns_check() {
    local name="$1" expected="$2" mode="${3:-core}" got ip
    got="$(dig +short +time=1 +tries=1 @"$DNS_SERVER" "$name" A 2>/dev/null || true)"
    ip="$(printf '%s\n' "$got" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1 || true)"
    if [ "$ip" = "$expected" ]; then
        v_ok "DNS $name" "$expected"
    elif [ -z "$ip" ]; then
        if [ "$mode" = "warn" ]; then
            v_warn "DNS $name" "sin respuesta (esperado $expected)"
        else
            v_fail "DNS $name" "sin respuesta (esperado $expected)"
        fi
    elif [ "$mode" = "warn" ]; then
        v_warn "DNS $name" "esperado $expected, obtenido $ip"
    else
        v_fail "DNS $name" "esperado $expected, obtenido $ip"
    fi
}

url_check() {
    local host="$1" mode="${2:-core}" code="" tries=1 i
    [ "$CHECK_ONLY" -eq 0 ] && tries=6
    for i in $(seq 1 "$tries"); do
        code="$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
            --resolve "$host:443:$HOST_IP" "https://$host/" 2>/dev/null || true)"
        case "$code" in
            2*|3*|401|403) break ;;
        esac
        [ "$i" -lt "$tries" ] && sleep 5
    done
    case "$code" in
        2*|3*|401|403) v_ok "https://$host" "HTTP $code" ;;
        *)
            if [ "$mode" = "warn" ]; then
                v_warn "https://$host" "HTTP ${code:-000}"
            else
                v_fail "https://$host" "HTTP ${code:-000}"
            fi
            ;;
    esac
}

# -------------------------------------------------------------------
# Fase 11: verificación de servicios
# -------------------------------------------------------------------
phase_verify() {
    : >"$STATUS_FILE"
    VERIFY_FAILS=0
    cd "$ROOT" || exit 1

    local unit ulist missing u glist g line svc state status
    local ps_data services total running i code out stratum
    local db_port cups_port portainer_port restic_repo src avail

    DNS_SERVER="127.0.0.1"
    if command -v dig >/dev/null 2>&1; then
        if ! dig +short +time=1 +tries=1 @127.0.0.1 "$DNS_DOMAIN" SOA 2>/dev/null | grep -q .; then
            DNS_SERVER="$HOST_IP"
        fi
    fi

    v_section "Active Directory (Samba 4 nativo)"
    unit="samba"
    systemctl cat samba-ad-dc.service >/dev/null 2>&1 && unit="samba-ad-dc"
    if systemctl is-active --quiet "$unit"; then
        v_ok "systemd $unit" "activo"
    else
        v_fail "systemd $unit" "NO activo"
    fi
    check_ports "AD · puertos TCP" tcp "53 88 389 445"
    check_ports "AD · puertos UDP" udp "53 88 389"
    check_ports "SMB 139 (opcional)" tcp "139" warn

    if command -v samba-tool >/dev/null 2>&1; then
        if timeout 15 samba-tool domain level show >/dev/null 2>&1; then
            v_ok "AD · dominio" "$AD_REALM"
        else
            v_fail "AD · dominio" "samba-tool domain level show falló"
        fi
        ulist="$(timeout 15 samba-tool user list 2>/dev/null || true)"
        missing=""
        for u in joaquin david nicolas; do
            printf '%s\n' "$ulist" | grep -qx "$u" || missing="$missing $u"
        done
        if [ -z "$missing" ]; then
            v_ok "AD · usuarios base" "joaquin david nicolas"
        else
            v_fail "AD · usuarios base" "faltan:$missing"
        fi
        glist="$(timeout 15 samba-tool group list 2>/dev/null || true)"
        missing=""
        for g in admins sistemas oficina srv-files; do
            printf '%s\n' "$glist" | grep -qx "$g" || missing="$missing $g"
        done
        if [ -z "$missing" ]; then
            v_ok "AD · grupos base" "admins sistemas oficina srv-files"
        else
            v_fail "AD · grupos base" "faltan:$missing"
        fi

        if [ -n "$ADMIN_PASS" ]; then
            local cc="/tmp/tso-verify-krb5cc.$$"
            if printf '%s\n' "$ADMIN_PASS" | KRB5CCNAME="$cc" timeout 20 kinit administrator >/dev/null 2>&1; then
                v_ok "AD · autenticación" "kinit administrator OK"
            else
                v_fail "AD · autenticación" "kinit administrator falló (clave?)"
            fi
            KRB5CCNAME="$cc" kdestroy >/dev/null 2>&1 || true
            rm -f "$cc"
        else
            v_skip "AD · autenticación" "sin clave de administrator"
        fi
    else
        v_warn "AD · samba-tool" "no instalado; chequeos de AD omitidos"
    fi

    v_section "DNS del dominio"
    if [ "$SKIP_DNS" -eq 1 ]; then
        v_skip "DNS" "omitido por --skip-dns"
    elif command -v dig >/dev/null 2>&1; then
        dns_check "dc1.$DNS_DOMAIN" "$HOST_IP"
        dns_check "mail.$DNS_DOMAIN" "$HOST_IP"
        dns_check "webmail.$DNS_DOMAIN" "$HOST_IP"
        dns_check "archivos.$DNS_DOMAIN" "$HOST_IP"
        dns_check "grafana.$DNS_DOMAIN" "$HOST_IP"
        dns_check "portainer.$DNS_DOMAIN" "$HOST_IP"
        dns_check "web.$DNS_DOMAIN" "$HOST_IP"
        dns_check "www.$DNS_DOMAIN" "$HOST_IP"
        dns_check "joaquin.$DNS_DOMAIN" "$HOST_IP" warn
        dns_check "david.$DNS_DOMAIN" "$HOST_IP" warn
        dns_check "nicolas.$DNS_DOMAIN" "$HOST_IP" warn
        dns_check "zabbix.$DNS_DOMAIN" "$ZABBIX_IP" warn
    else
        v_warn "DNS" "falta dig; no se verificaron registros"
    fi

    v_section "Firewall, SSH, NTP y red"
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet filter >/dev/null 2>&1; then
            if nft list chain inet filter input 2>/dev/null | grep -q 'policy drop'; then
                v_ok "nftables" "tabla inet filter con policy drop"
            else
                v_warn "nftables" "tabla presente pero sin policy drop"
            fi
        else
            v_fail "nftables" "tabla inet filter NO aplicada"
        fi
    else
        v_warn "nftables" "nft no instalado"
    fi
    if systemctl is-active --quiet ssh; then v_ok "SSH" "activo"; else v_fail "SSH" "NO activo"; fi
    check_ports "SSH · puerto" tcp "22"
    if systemctl is-active --quiet chrony; then v_ok "chrony" "activo"; else v_fail "chrony" "NO activo"; fi
    check_ports "NTP" udp "123"
    if command -v chronyc >/dev/null 2>&1; then
        stratum="$(chronyc tracking 2>/dev/null | awk -F: '/Stratum/{gsub(/ /,"",$2); print $2}' || true)"
        if [ -n "$stratum" ] && [ "${stratum:-0}" -gt 0 ]; then
            v_ok "NTP · sincronización" "stratum $stratum"
        else
            v_warn "NTP · sincronización" "sin fuente (stratum ${stratum:-?})"
        fi
    fi
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        v_warn "systemd-resolved" "activo (puede chocar con Samba DNS)"
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        v_warn "NetworkManager" "activo"
    fi
    src="${SSH_CONNECTION:-}"; src="${src%% *}"
    if [ -n "$src" ] && command -v nft >/dev/null 2>&1; then
        if nft list set inet filter admin_ips 2>/dev/null | grep -q "$src"; then
            v_ok "firewall · origen SSH" "$src permitido"
        else
            v_warn "firewall · origen SSH" "$src no está en admin_ips (podría cortar SSH)"
        fi
    fi

    v_section "DHCP (Kea)"
    check_ports "DHCP" udp "67"

    v_section "WiFi 802.1X (FreeRADIUS)"
    if systemctl is-active --quiet freeradius; then v_ok "FreeRADIUS" "activo"; else v_fail "FreeRADIUS" "NO activo"; fi
    check_ports "RADIUS" udp "1812"
    if command -v radclient >/dev/null 2>&1; then
        out="$(printf 'User-Name = "sonda-install"\nUser-Password = "no-valida"\n' \
            | timeout 10 radclient -r 1 -t 3 127.0.0.1:1812 auth testing123 2>&1 || true)"
        if printf '%s' "$out" | grep -qE 'Access-(Accept|Reject)'; then
            v_ok "RADIUS · respuesta" "Access-Reject (servidor vivo)"
        else
            v_fail "RADIUS · respuesta" "sin respuesta de 127.0.0.1:1812"
        fi
    else
        v_warn "RADIUS · respuesta" "falta radclient"
    fi
    if command -v ntlm_auth >/dev/null 2>&1; then v_ok "ntlm_auth" "presente"; else v_warn "ntlm_auth" "no instalado"; fi
    if getent group winbindd_priv >/dev/null 2>&1; then
        v_ok "winbindd_priv" "grupo presente"
    else
        v_warn "winbindd_priv" "no existe (¿winbindd del DC?)"
    fi

    v_section "Contenedores Docker"
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if [ "$CHECK_ONLY" -eq 0 ]; then
            for i in $(seq 1 24); do
                total="$(docker compose config --services 2>/dev/null | wc -l || echo 0)"
                running="$(docker compose ps --status running --services 2>/dev/null | wc -l || echo 0)"
                if [ "${total:-0}" -gt 0 ] && [ "${running:-0}" -ge "${total:-0}" ]; then break; fi
                sleep 5
            done
        fi
        services="$(docker compose config --services 2>/dev/null | sort || true)"
        ps_data="$(docker compose ps --all --format '{{.Service}}|{{.State}}|{{.Status}}' 2>/dev/null || true)"
        if [ -z "$services" ]; then
            v_fail "docker compose" "no se pudieron listar los servicios"
        else
            for svc in $services; do
                line="$(printf '%s\n' "$ps_data" | awk -F'|' -v s="$svc" '$1==s{print;exit}')"
                if [ -z "$line" ]; then
                    v_fail "contenedor $svc" "no creado"
                    continue
                fi
                state="$(printf '%s' "$line" | cut -d'|' -f2)"
                status="$(printf '%s' "$line" | cut -d'|' -f3-)"
                if [ "$state" = "running" ]; then
                    v_ok "contenedor $svc" "$status"
                else
                    v_fail "contenedor $svc" "estado: $state ($status)"
                fi
            done
        fi
    else
        if [ "$CHECK_ONLY" -eq 1 ]; then
            v_warn "Docker" "daemon no disponible; no se verificaron contenedores"
        else
            v_fail "Docker" "daemon no responde"
        fi
    fi

    db_port="$(env_get DB_PORT)"; db_port="${db_port:-5432}"
    cups_port="$(env_get CUPS_PORT)"; cups_port="${cups_port:-1631}"
    portainer_port="$(env_get PORTAINER_PORT)"; portainer_port="${portainer_port:-9443}"
    v_section "Puertos de servicios"
    check_ports "Web" tcp "80 443"
    check_ports "Correo" tcp "25 587 143 993"
    check_ports "Correo POP3 (opcional)" tcp "110 995" warn
    check_ports "CUPS" tcp "$cups_port"
    check_ports "PostgreSQL" tcp "$db_port"
    check_ports "Portainer" tcp "$portainer_port"
    check_ports "Portainer edge (opcional)" tcp "8000" warn
    check_ports "Grafana (localhost)" tcp "3000"
    check_ports "Prometheus (localhost)" tcp "9090"
    check_ports "Alertmanager (localhost)" tcp "9093"

    v_section "Accesos web (HTTPS)"
    if command -v curl >/dev/null 2>&1; then
        url_check "$DNS_DOMAIN"
        url_check "webmail.$DNS_DOMAIN"
        url_check "archivos.$DNS_DOMAIN"
        url_check "grafana.$DNS_DOMAIN"
        url_check "print.$DNS_DOMAIN"
        url_check "portainer.$DNS_DOMAIN"
    else
        v_warn "HTTPS" "falta curl; no se verificaron URLs"
    fi

    v_section "Backup, agentes y disco"
    restic_repo="$(env_get RESTIC_REPOSITORY)"; restic_repo="${restic_repo:-/srv/backup/repos/dc1}"
    if [ -f /etc/cron.d/tso-backup ]; then
        v_ok "backup · cron" "/etc/cron.d/tso-backup"
    elif [ "$SKIP_BACKUP" -eq 1 ]; then
        v_skip "backup · cron" "--skip-backup"
    else
        v_warn "backup · cron" "no instalado (montá /srv/backup y corré server/backup.sh install)"
    fi
    if [ -d "$restic_repo" ]; then v_ok "backup · repo" "$restic_repo"; else v_warn "backup · repo" "$restic_repo no existe"; fi
    if port_open tcp 10050; then
        v_ok "zabbix-agent" "10050 escuchando"
    else
        v_warn "zabbix-agent" "no instalado (opcional: --with-zabbix-agent)"
    fi
    if command -v curl >/dev/null 2>&1; then
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://$ZABBIX_IP/" 2>/dev/null || true)"
        case "$code" in
            2*|3*|401|403) v_ok "zabbix server $ZABBIX_IP" "HTTP $code" ;;
            *) v_warn "zabbix server $ZABBIX_IP" "sin respuesta (¿server aparte instalado?)" ;;
        esac
    else
        v_warn "zabbix server $ZABBIX_IP" "falta curl"
    fi
    avail="$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}' || true)"; avail="${avail:-0}"
    if [ "$avail" -lt 5242880 ]; then
        v_warn "disco /" "$((avail / 1024)) MB libres"
    else
        v_ok "disco /" "$((avail / 1024 / 1024)) GB libres"
    fi

    if [ "$VERIFY_FAILS" -gt 0 ]; then
        echo "Verificación terminada con $VERIFY_FAILS fallas"
        exit 1
    fi
    echo "Verificación OK: todos los chequeos críticos pasaron"
}

# -------------------------------------------------------------------
# IP fija (antes de instalar)
# -------------------------------------------------------------------
ensure_basic_packages() {
    local need=0
    command -v ifup >/dev/null 2>&1 || need=1
    command -v ifdown >/dev/null 2>&1 || need=1
    command -v dhcpcd >/dev/null 2>&1 || need=1
    command -v ping >/dev/null 2>&1 || need=1
    if [ "$need" -eq 1 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ifupdown dhcpcd5 iproute2 iputils-ping
    fi
}

handle_ip() {
    local current_ips iface
    current_ips="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    if printf '%s\n' "$current_ips" | grep -Fxq "$HOST_IP"; then
        printf '%sIP %s ya configurada.%s\n' "$GREEN" "$HOST_IP" "$RESET"
        return 0
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        printf '%sAVISO: la IP %s no está configurada (modo diagnóstico).%s\n' "$YELLOW" "$HOST_IP" "$RESET"
        return 0
    fi

    if [ "$SET_IP" -eq 1 ]; then
        [ "$ASSUME_YES" -eq 1 ] || die "--set-ip requiere --yes (cambia la IP y puede cortar SSH)"
        ensure_basic_packages
        iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
        [ -n "$iface" ] || die "no se pudo detectar la interfaz de la ruta por defecto"
        printf '\n%sATENCIÓN: se va a fijar %s/%s en %s (gateway %s).%s\n' \
            "$YELLOW" "$HOST_IP" "24" "$iface" "$GATEWAY_IP" "$RESET"
        printf 'Si estás por SSH, la sesión se va a cortar.\n\n'
        IFACE="$iface" IP="$HOST_IP" PREFIX=24 GATEWAY="$GATEWAY_IP" DNS="$GATEWAY_IP" \
            bash "$ROOT/server/set-ip.sh" --yes --commit || die "server/set-ip.sh falló"
        if [ -n "${SSH_CONNECTION:-}" ]; then
            printf '\n%sIP %s aplicada.%s\n' "$GREEN" "$HOST_IP" "$RESET"
            printf 'Reconectate y volvé a ejecutar la instalación:\n'
            printf '  ssh %s@%s\n' "${SUDO_USER:-$USER}" "$HOST_IP"
            printf '  cd %s\n  sudo bash install.sh\n' "$ROOT"
            FINALIZED=1
            exit 0
        fi
        printf '%sIP aplicada; continuando desde la consola.%s\n' "$GREEN" "$RESET"
        return 0
    fi

    die "la IP $HOST_IP no está configurada.
Opciones:
  A) sudo bash install.sh --set-ip --yes   (fija la IP; corta SSH)
  B) sudo bash server/set-ip.sh --yes --commit
     reconectate a $HOST_IP y volvé a correr: sudo bash install.sh
  C) sudo bash install.sh --check          (solo diagnóstico)"
}

# -------------------------------------------------------------------
# Confirmación inicial
# -------------------------------------------------------------------
confirm_continue() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf '%sModo --yes: sin confirmaciones.%s\n' "$YELLOW" "$RESET"
        return 0
    fi
    [ -t 0 ] || die "sin TTY para confirmar; usá --yes para modo desatendido"
    printf '\n%sEsto va a:%s\n' "$BOLD" "$RESET"
    printf '  - instalar paquetes (Samba AD, chrony, FreeRADIUS, Docker…)\n'
    printf '  - provisionar el dominio %s si no existe\n' "$AD_REALM"
    printf '  - aplicar firewall nftables y SSH endurecido\n'
    printf '  - levantar los contenedores y servir DHCP (Kea)\n'
    printf '\n  IP: %s   Dominio: %s   DC: %s\n' "$HOST_IP" "$DNS_DOMAIN" "$DC_FQDN"
    printf '  Log: %s\n\n' "$LOG_DIR"
    local ans
    read -r -p '¿Continuar? [s/N] ' ans
    case "$ans" in
        s|S|si|SI|sí|SÍ) ;;
        *) cancel "Instalación cancelada." ;;
    esac
}

# -------------------------------------------------------------------
# Argumentos
# -------------------------------------------------------------------
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) usage; FINALIZED=1; exit 0 ;;
            --check|--dry-run) CHECK_ONLY=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --set-ip) SET_IP=1; shift ;;
            --host-ip) ARG_HOST_IP="${2:-}"; [ -n "$ARG_HOST_IP" ] || die "--host-ip requiere un valor"; shift 2 ;;
            --gateway) ARG_GATEWAY="${2:-}"; [ -n "$ARG_GATEWAY" ] || die "--gateway requiere un valor"; shift 2 ;;
            --domain) ARG_DOMAIN="${2:-}"; [ -n "$ARG_DOMAIN" ] || die "--domain requiere un valor"; shift 2 ;;
            --realm) ARG_REALM="${2:-}"; [ -n "$ARG_REALM" ] || die "--realm requiere un valor"; shift 2 ;;
            --netbios) ARG_NETBIOS="${2:-}"; [ -n "$ARG_NETBIOS" ] || die "--netbios requiere un valor"; shift 2 ;;
            --dc-name) ARG_DC_NAME="${2:-}"; [ -n "$ARG_DC_NAME" ] || die "--dc-name requiere un valor"; shift 2 ;;
            --admin-pass) ARG_ADMIN_PASS="${2:-}"; [ -n "$ARG_ADMIN_PASS" ] || die "--admin-pass requiere un valor"; shift 2 ;;
            --ad-user-pass) ARG_AD_USER_PASS="${2:-}"; [ -n "$ARG_AD_USER_PASS" ] || die "--ad-user-pass requiere un valor"; shift 2 ;;
            --skip-ad) SKIP_AD=1; shift ;;
            --skip-dns) SKIP_DNS=1; shift ;;
            --skip-backup) SKIP_BACKUP=1; shift ;;
            --with-zabbix-agent) WITH_ZABBIX_AGENT=1; shift ;;
            --no-secrets) NO_SECRETS=1; shift ;;
            --verbose|-v) VERBOSE=1; shift ;;
            *)
                printf 'Opción desconocida: %s\n\n' "$1" >&2
                usage >&2
                FINALIZED=1
                exit 2
                ;;
        esac
    done
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "ejecutá con sudo: sudo bash install.sh [opciones]"
    fi
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
    parse_args "$@"
    load_config
    validate_config
    setup_logging
    banner

    if [ "$CHECK_ONLY" -eq 1 ]; then
        run_step "Preflight (diagnostico)" 1 phase_preflight
        run_step "Estado actual de servicios" 0 phase_verify
        finish
    fi

    require_root
    run_step "0. Preflight" 1 phase_preflight
    confirm_continue
    handle_ip

    run_step "1. Identidad del host (hostname, /etc/hosts, DNS)" 1 phase_host
    run_step "2. Paquetes base + Docker" 1 phase_packages
    run_step "3. NTP (chrony)" 1 phase_ntp
    run_step "4. .env y secretos" 1 phase_env

    prepare_ad_credentials
    run_step "5. Active Directory (Samba 4)" 1 phase_ad
    run_step "6. DNS del dominio y servicios" 0 phase_dns
    run_step "7. TLS del proxy inverso" 1 phase_tls

    confirm_router_dhcp
    run_step "8. Deploy (firewall, SSH, RADIUS, contenedores)" 1 phase_deploy
    run_step "9. Backup restic" 0 phase_backup
    if [ "$WITH_ZABBIX_AGENT" -eq 1 ]; then
        run_step "10. Agente Zabbix" 0 phase_zabbix
    fi
    run_step "11. Verificacion de servicios" 0 phase_verify
    finish
}

main "$@"
