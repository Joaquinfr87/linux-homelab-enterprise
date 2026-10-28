#!/bin/bash
set -euo pipefail

# ===================================================================
# deploy.sh — Aplica la configuración de servidor versionada en el repo.
#
# Uso (EN EL SERVIDOR, dentro del repo clonado):
#   git pull
#   sudo bash server/deploy.sh
#
# Aplica config nativa (firewall, ssh, ntp, FreeRADIUS/WiFi 802.1X) y
# luego levanta/actualiza los contenedores (docker compose) con su
# configuración versionada.
# Hace validaciones antes de aplicar para no dejar el server sin acceso.
# ===================================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

# ─── [0/7] Paquetes base (idempotente) ──────────────────────────────
# Sin nftables no se puede aplicar el firewall; sin chrony el paso 5
# fallaba y abortaba el deploy (set -e). Se instalan solo si faltan.
NEED_PKGS=()
command -v nft     >/dev/null 2>&1 || NEED_PKGS+=(nftables)
command -v chronyd >/dev/null 2>&1 || NEED_PKGS+=(chrony)
if [ "${#NEED_PKGS[@]}" -gt 0 ]; then
    echo "==> [0/7] Instalando paquetes base: ${NEED_PKGS[*]} ..."
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${NEED_PKGS[@]}"
    # chrony y systemd-timesyncd se pelean por el reloj y por el puerto 123.
    if systemctl is-enabled systemd-timesyncd >/dev/null 2>&1; then
        sudo systemctl disable --now systemd-timesyncd || true
        echo "    systemd-timesyncd deshabilitado (chrony es el NTP del dominio)"
    fi
else
    echo "==> [0/7] Paquetes base OK (nftables, chrony)"
fi

echo "==> [1/7] Validando sintaxis de nftables.conf ..."
# Se aplica una copia con las IPs extra de administración (ADMIN_IPS_EXTRA
# en .env): sin esto, si estás conectado por SSH desde una IP que no está
# en admin_ips (.50–.52), el firewall te deja afuera al aplicarse.
# Se insertan dentro del bloque `elements = {` del set (y no con
# `add element`) para que `systemctl reload nftables` siga funcionando.
NFT_TMP="$(mktemp)"
EXTRA_ADMIN_IPS=""
if [ -f "$ROOT/.env" ]; then
    EXTRA_ADMIN_IPS="$(grep -E '^ADMIN_IPS_EXTRA=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" || true)"
fi
ADDED_IPS=""
VALID_IPS=""
for _ip in $EXTRA_ADMIN_IPS; do
    printf '%s' "$_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue
    grep -qE "^[[:space:]]*${_ip//./\\.},?[[:space:]]*$" "$DIR/nftables.conf" && continue  # ya está
    VALID_IPS="$VALID_IPS $_ip"
    ADDED_IPS="$ADDED_IPS $_ip"
done
if [ -n "$VALID_IPS" ]; then
    awk -v ips="$VALID_IPS" '
        { print }
        /set admin_ips/ { inset = 1 }
        inset && /elements = \{/ && !done {
            n = split(ips, a, " ")
            for (i = 1; i <= n; i++) printf "            %s,\n", a[i]
            done = 1
        }
    ' "$DIR/nftables.conf" > "$NFT_TMP"
    echo "    + admin extra:$ADDED_IPS"
else
    cp "$DIR/nftables.conf" "$NFT_TMP"
fi
if sudo nft -c -f "$NFT_TMP" 2>/dev/null; then
    echo "    sintaxis OK"
else
    echo "    ERROR: sintaxis inválida en el firewall"
    echo "    No se aplica NADA para no perder conectividad."
    rm -f "$NFT_TMP"
    exit 1
fi

echo "==> [2/7] Aplicando firewall ..."
sudo cp "$NFT_TMP" /etc/nftables.conf
rm -f "$NFT_TMP"
# Borra SOLO nuestra tabla (inet filter) para no arrastrar las cadenas
# internas de Docker. Un "flush ruleset" global rompería el NAT de los
# contenedores (error "No chain/target/match by that name").
sudo nft delete table inet filter 2>/dev/null || true
sudo nft -f /etc/nftables.conf
sudo systemctl enable nftables >/dev/null 2>&1 || true
echo "    firewall activo (tabla inet filter)"

echo "==> [3/7] Respaldo y validación de sshd_config ..."
BACKUP="${BACKUP:-}"
if [ -f /etc/ssh/sshd_config ]; then
    BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
    sudo cp /etc/ssh/sshd_config "$BACKUP"
    echo "    respaldo en $BACKUP"
fi
# sshd NO arranca si un ListenAddress no existe en ninguna interfaz, y
# sshd -t no lo detecta (queda el server sin SSH). Se omiten (comentadas)
# las direcciones que no estén configuradas en esta máquina.
SSHD_TMP="$(mktemp)"
trap 'rm -f "$SSHD_TMP"' EXIT
LOCAL_IPS="$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)"
while IFS= read -r LINE; do
    if [[ "$LINE" =~ ^[[:space:]]*ListenAddress[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        LIP="${BASH_REMATCH[1]}"
        if printf '%s\n' "$LOCAL_IPS" | grep -Fxq "$LIP"; then
            printf '%s\n' "$LINE"
        else
            printf '# [deploy] omitida: %s no existe en este host\n# %s\n' "$LIP" "$LINE"
            echo "    AVISO: ListenAddress $LIP omitida (no existe en este host)"
        fi
    else
        printf '%s\n' "$LINE"
    fi
done < "$DIR/sshd_config" > "$SSHD_TMP"
sudo cp "$SSHD_TMP" /etc/ssh/sshd_config

echo "==> [4/7] Verificando y reiniciando ssh ..."
if sudo sshd -t; then
    sudo systemctl restart ssh
    echo "    ssh reiniciado correctamente"
else
    echo "    ERROR: sshd -t falló. No se reinicia ssh."
    echo "    Restaurar respaldo:"
    echo "      sudo cp $BACKUP /etc/ssh/sshd_config && sudo systemctl restart ssh"
    exit 1
fi

echo "==> [5/7] Chrony (NTP) ..."
if [ -f /etc/chrony/chrony.conf ]; then
    BACKUP_CHRONY="/etc/chrony/chrony.conf.bak.$(date +%Y%m%d%H%M%S)"
    sudo cp /etc/chrony/chrony.conf "$BACKUP_CHRONY"
    echo "    respaldo en $BACKUP_CHRONY"
fi
sudo cp "$DIR/chrony.conf" /etc/chrony/chrony.conf
sudo systemctl enable --now chrony
sudo systemctl restart chrony
echo "    chrony reiniciado (servidor NTP de la LAN)"

echo "==> [6/7] FreeRADIUS (WiFi WPA2-Enterprise / 802.1X) ..."
RAD_SRC="$DIR/radius"
RADD_DIR=/etc/freeradius/3.0

# --- RADIUS_SECRET desde .env (secreto compartido con el router) ---
RAD_SECRET=""
AD_NB="SUDOERS"
if [ -f "$ROOT/.env" ]; then
    RAD_SECRET="$(grep -E '^RADIUS_SECRET=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" | xargs)"
    AD_NB="$(grep -E '^AD_NETBIOS=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" | xargs)"
fi
AD_NB="${AD_NB:-SUDOERS}"
if [ -z "$RAD_SECRET" ]; then
    echo "    ERROR: falta RADIUS_SECRET en $ROOT/.env (secreto RADIUS del router)."
    echo "      echo \"RADIUS_SECRET=\$(openssl rand -hex 16)\" >> $ROOT/.env"
    exit 1
fi
if ! printf '%s' "$RAD_SECRET" | grep -qE '^[A-Za-z0-9]{16,64}$'; then
    echo "    ERROR: RADIUS_SECRET debe ser alfanumérico, 16-64 caracteres."
    echo "      echo \"RADIUS_SECRET=\$(openssl rand -hex 16)\" >> $ROOT/.env"
    exit 1
fi

# --- paquetes: freeradius + utilidades + ntlm_auth ---
RAD_PKGS=()
command -v freeradius >/dev/null 2>&1 || RAD_PKGS+=(freeradius)
command -v radclient >/dev/null 2>&1 || RAD_PKGS+=(freeradius-utils)
command -v ntlm_auth >/dev/null 2>&1 || RAD_PKGS+=(samba-common-bin)
if [ "${#RAD_PKGS[@]}" -gt 0 ]; then
    echo "    instalando: ${RAD_PKGS[*]}"
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${RAD_PKGS[@]}"
fi

# --- smb.conf (DC): habilita MSCHAPv2 para ntlm_auth (DEBE quedar en [global]; si la
# línea cae en una sección de share, Samba la ignora y avisa "found in service section") ---
if command -v testparm >/dev/null 2>&1; then
    if TP_OUT="$(sudo testparm -s 2>/dev/null)"; then
        # ¿en qué sección quedó 'ntlm auth' según testparm?
        NTL_SEC="$(awk '/^\[/{sec=$0} /ntlm auth/{print sec}' <<<"$TP_OUT" | tail -1)"
        if [ "$NTL_SEC" = "[global]" ] && grep -qi 'mschapv2-and-ntlmv2-only' <<<"$TP_OUT"; then
            echo "    smb.conf: ntlm auth = mschapv2-and-ntlmv2-only (correcto en [global])"
        else
            sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak-tso-radius
            # borra la línea vieja y su comentario (aunque estén mal ubicados en un
            # share) y reinserta recién después de [global]
            sudo sed -i -E -e '/^[[:space:]]*ntlm auth[[:space:]]*=/d' \
                -e '/Habilita MSCHAPv2 para FreeRADIUS/d' /etc/samba/smb.conf
            sudo sed -i '0,/^\[global\]/{
/^\[global\]/a\
# Habilita MSCHAPv2 para FreeRADIUS (WiFi 802.1X) — server/deploy.sh\
ntlm auth = mschapv2-and-ntlmv2-only
}' /etc/samba/smb.conf
            TP_OUT="$(sudo testparm -s 2>/dev/null)" || true
            NTL_SEC="$(awk '/^\[/{sec=$0} /ntlm auth/{print sec}' <<<"$TP_OUT" | tail -1)"
            if [ "$NTL_SEC" != "[global]" ]; then
                sudo cp -a /etc/samba/smb.conf.bak-tso-radius /etc/samba/smb.conf
                echo "    ERROR: no pude ubicar 'ntlm auth' en [global]; smb.conf restaurado."
                exit 1
            fi
            echo "    smb.conf: ntlm auth = mschapv2-and-ntlmv2-only → reiniciando el DC (~5s de corte AD)"
            sudo systemctl restart samba-ad-dc 2>/dev/null || sudo systemctl restart samba
        fi
    else
        echo "    ERROR: testparm falló → smb.conf inválido; NO se toca ni se reinicia el DC."
        exit 1
    fi
else
    echo "    ATENCIÓN: testparm no disponible → no se verifica 'ntlm auth' en smb.conf."
fi

# --- usuario de FreeRADIUS vs grupo winbindd_priv del DC ---
FR_USER="$(getent passwd freerad | cut -d: -f1 || true)"
FR_USER="${FR_USER:-$(getent passwd radiusd | cut -d: -f1 || true)}"
if [ -z "$FR_USER" ]; then
    echo "    ATENCIÓN: no encontré el usuario freerad/radiusd (¿se instaló freeradius?)."
elif getent group winbindd_priv >/dev/null 2>&1; then
    if id -nG "$FR_USER" | grep -qw winbindd_priv; then
        echo "    $FR_USER ya está en winbindd_priv"
    else
        sudo usermod -aG winbindd_priv "$FR_USER"
        echo "    $FR_USER agregado al grupo winbindd_priv (acceso a ntlm_auth/winbind)"
    fi
else
    echo "    ATENCIÓN: no existe el grupo winbindd_priv (¿corre winbindd en el DC?)."
    echo "      Verificar en dc1:  ls -ld /run/samba/*winbind*  y  ps aux | grep winbind"
fi

# --- configs versionados (secreto y realm inyectados) ---
echo "    aplicando clients.conf + mods-enabled/mschap"
sudo sed "s|@RADIUS_SECRET@|${RAD_SECRET}|g" "$RAD_SRC/clients.conf" \
    | sudo tee "$RADD_DIR/clients.conf" >/dev/null
# En Debian mods-enabled/mschap es un symlink a mods-available: se retira
# para dejar un archivo regular con nuestra config (mods-available queda
# intacto como conffile del paquete).
sudo rm -f "$RADD_DIR/mods-enabled/mschap"
sudo sed "s|@AD_NETBIOS@|${AD_NB}|g" "$RAD_SRC/mod-mschap" \
    | sudo tee "$RADD_DIR/mods-enabled/mschap" >/dev/null
# PEAP por defecto (los clientes WiFi usan PEAP/MSCHAPv2). OJO: la línea va
# indentada con tab dentro del bloque `eap { }` → el patrón tolera espacios.
EAP_FILES=("$RADD_DIR/mods-available/eap")
if [ -e "$RADD_DIR/mods-enabled/eap" ] && [ ! -L "$RADD_DIR/mods-enabled/eap" ]; then
    EAP_FILES+=("$RADD_DIR/mods-enabled/eap")
fi
for _eap in "${EAP_FILES[@]}"; do
    [ -f "$_eap" ] || continue
    if ! sudo grep -qE '^[[:space:]]*default_eap_type[[:space:]]*=[[:space:]]*peap' "$_eap" 2>/dev/null; then
        sudo sed -i -E 's/^([[:space:]]*)default_eap_type[[:space:]]*=.*/\1default_eap_type = peap/' "$_eap"
        if sudo grep -qE '^[[:space:]]*default_eap_type[[:space:]]*=[[:space:]]*peap' "$_eap" 2>/dev/null; then
            echo "    eap: default_eap_type = peap ($_eap)"
        else
            echo "    ATENCIÓN: no pude setear default_eap_type = peap en $_eap (revisar a mano)."
        fi
    fi
done

# --- certs EAP (CA interna + server.pem) ---
if [ ! -s "$RADD_DIR/certs/ca.pem" ] || [ ! -s "$RADD_DIR/certs/server.pem" ]; then
    echo "    generando certs EAP (CA RADIUS + server.pem) ..."
    sudo bash "$RAD_SRC/tls-gen.sh"
else
    echo "    certs EAP ya existentes ($RADD_DIR/certs/)"
fi

# --- validar config y (re)arrancar ---
echo "    validando freeradius -XC ..."
if FR_CHECK="$(sudo freeradius -XC 2>&1)"; then
    echo "    config de FreeRADIUS OK"
else
    echo "    ERROR: freeradius -XC falló:"
    printf '%s\n' "$FR_CHECK" | tail -n 15
    echo "    NO se reinicia FreeRADIUS."
    exit 1
fi
sudo systemctl enable freeradius >/dev/null 2>&1 || true
sudo systemctl restart freeradius
sleep 1
if sudo ss -Hlnu | grep -qE ':1812[[:space:]]'; then
    echo "    freeradius activo (1812/udp)"
else
    echo "    ERROR: freeradius no está escuchando en 1812/udp. Revisar:"
    echo "      journalctl -u freeradius -n 50"
    exit 1
fi

# --- sonda para Prometheus (radius.prom + cron cada 5 min) ---
sudo mkdir -p /var/lib/tso-backup
sudo tee /etc/cron.d/tso-radius >/dev/null <<EOF
# Generado por server/deploy.sh — sonda de FreeRADIUS para Prometheus
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root
*/5 * * * * root $RAD_SRC/radius-check.sh
EOF
sudo chmod 644 /etc/cron.d/tso-radius
sudo bash "$RAD_SRC/radius-check.sh"
echo "    sonda RADIUS instalada (/etc/cron.d/tso-radius → radius.prom)"

# --- Suricata IDS/IPS (si está instalado en dc1) ---
if command -v suricata >/dev/null 2>&1; then
    echo "==> [Suricata IDS/IPS] Sincronizando reglas de seguridad..."
    sudo mkdir -p /etc/suricata/rules
    sudo cp "$DIR/suricata/rules/homelab.rules" /etc/suricata/rules/homelab.rules
    if systemctl is-active --quiet suricata; then
        sudo systemctl reload-or-restart suricata 2>/dev/null || true
        echo "    Suricata activo y reglas sincronizadas (/etc/suricata/rules/homelab.rules)"
    else
        echo "    Suricata instalado (inactivo o en configuración manual)"
    fi
fi

echo "    Prueba manual de autenticación (en dc1):"
echo "      sudo radtest -t mschap <usuario> '<clave AD>' 127.0.0.1:1812 0 testing123"
echo "    Router (UI): Wireless → Security → WPA/WPA2-Enterprise →"
echo "      IP 192.168.0.2, puerto 1812, password = RADIUS_SECRET (.env)"

echo "==> [7/7] Contenedores (docker compose) ..."
if [ ! -f "$ROOT/docker-compose.yml" ]; then
    echo "    ERROR: no se encontró $ROOT/docker-compose.yml"
    exit 1
fi
# Valida la configuración de nginx (services/web/nginx.conf) sin tocar nada.
# OJO: montar tls/ (certs) porque el conf declara ssl_certificate; sin esa
# ruta nginx -t falla con "cannot load certificate" aunque el conf es válido.
echo "    validando services/web/nginx.conf ..."
if [ ! -f "$ROOT/services/web/tls/server.crt" ]; then
    echo "    generando certificados TLS (CA interna y wildcard *.sudoers.lan)..."
    bash "$ROOT/services/web/tls-gen.sh"
fi
NGINX_TEST_OUT="$(sudo docker run --rm \
        -v "$ROOT/services/web/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$ROOT/services/web/tls:/etc/nginx/tls:ro" \
        -v "$ROOT/services/web/tls:/etc/ssl/banco:ro" \
        nginx:1.27-alpine nginx -t 2>&1)" || {
    echo "    ERROR: nginx.conf inválido → NO se tocan los contenedores."
    echo "    Detalle del error de Nginx:"
    echo "$NGINX_TEST_OUT" | sed 's/^/      /'
    exit 1
}
echo "    nginx.conf OK"
# Valida las configs del stack de monitoreo (services/monitoring).
echo "    validando services/monitoring/ ..."
if sudo docker run --rm --entrypoint promtool \
        -v "$ROOT/services/monitoring/prometheus:/etc/prometheus:ro" \
        "prom/prometheus:${PROMETHEUS_TAG:-v3.15.0}" \
        check config /etc/prometheus/prometheus.yml >/dev/null; then
    echo "    prometheus.yml + reglas OK"
else
    echo "    ERROR: configuración de Prometheus inválida → NO se tocan los contenedores."
    exit 1
fi
if sudo docker run --rm --entrypoint amtool \
        -v "$ROOT/services/monitoring/alertmanager:/etc/alertmanager:ro" \
        "prom/alertmanager:${ALERTMANAGER_TAG:-v0.34.1}" \
        check-config /etc/alertmanager/alertmanager.yml >/dev/null; then
    echo "    alertmanager.yml OK"
else
    echo "    ERROR: configuración de Alertmanager inválida → NO se tocan los contenedores."
    exit 1
fi
if sudo docker run --rm --entrypoint blackbox_exporter \
        -v "$ROOT/services/monitoring/blackbox:/etc/blackbox:ro" \
        "prom/blackbox-exporter:${BLACKBOX_TAG:-v0.28.0}" \
        --config.check --config.file=/etc/blackbox/blackbox.yml >/dev/null; then
    echo "    blackbox.yml OK"
else
    echo "    ERROR: configuración de blackbox inválida → NO se tocan los contenedores."
    exit 1
fi
if [ ! -f "$ROOT/.env" ]; then
    echo "    ATENCIÓN: falta $ROOT/.env (copiar de .env.example) → compose usa defaults."
else
    # El webmail (Roundcube) declara ROUNDCUBE_DES_KEY como obligatoria:
    # sin ella la interpolación de compose aborta TODO el deploy.
    if ! grep -qE '^ROUNDCUBE_DES_KEY=[^[:space:]#]+' "$ROOT/.env"; then
        echo "    ERROR: falta ROUNDCUBE_DES_KEY en $ROOT/.env → docker compose aborta."
        echo "      echo \"ROUNDCUBE_DES_KEY=\$(openssl rand -hex 32)\" >> $ROOT/.env"
        exit 1
    fi
    if grep -qE '^ROUNDCUBE_DES_KEY=CambiarEstaClave' "$ROOT/.env"; then
        echo "    ATENCIÓN: ROUNDCUBE_DES_KEY sigue con el valor de ejemplo del repo."
    fi
    # Sin cuentas de correo no hay nadie que pueda entrar al webmail.
    MAIL_USERS="$(grep -E '^MAIL_USERS=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" | xargs)"
    if [ -z "$MAIL_USERS" ]; then
        echo "    ATENCIÓN: MAIL_USERS vacío en $ROOT/.env → el webmail no tendrá cuentas."
        echo "      MAIL_USERS=\"joaquin:Pass1! david:Pass2!\"   (formato user:pass user2:pass2)"
    elif printf '%s' "$MAIL_USERS" | grep -q "CambiarMe"; then
        echo "    ATENCIÓN: MAIL_USERS sigue con las claves de ejemplo del repo (.env.example)."
    fi
    # El gestor de archivos (Filebrowser) declara FILES_ADMIN_PASS obligatoria.
    if ! grep -qE '^FILES_ADMIN_PASS=[^[:space:]#]+' "$ROOT/.env"; then
        echo "    ERROR: falta FILES_ADMIN_PASS en .env → docker compose aborta."
        echo "      echo 'FILES_ADMIN_PASS=Admin2026!' >> $ROOT/.env"
        exit 1
    fi
    if grep -qE '^FILES_ADMIN_PASS=CambiarMeFiles' "$ROOT/.env"; then
        echo "    ATENCIÓN: FILES_ADMIN_PASS sigue con el valor de ejemplo del repo."
    fi
    # Grafana declara GRAFANA_ADMIN_PASSWORD y GF_SECRET_KEY como obligatorias.
    for v in GRAFANA_ADMIN_PASSWORD GF_SECRET_KEY; do
        if ! grep -qE "^${v}=[^[:space:]#]+" "$ROOT/.env"; then
            echo "    ERROR: falta $v en .env → docker compose aborta."
            echo "      echo \"$v=\$(openssl rand -hex 32)\" >> $ROOT/.env"
            exit 1
        fi
        if grep -qE "^${v}=Cambiar" "$ROOT/.env"; then
            echo "    ATENCIÓN: $v sigue con el valor de ejemplo del repo."
        fi
    done
    # gid del grupo dueño de los shares: sin él, los archivos creados desde
    # la web quedan root:root y nadie puede escribirlos por SMB.
    if ! grep -qE '^FILES_GID=[0-9]+' "$ROOT/.env"; then
        FG="$(stat -c %g /srv/samba/departamentos 2>/dev/null || true)"
        if [ -n "$FG" ]; then
            echo "    ATENCIÓN: FILES_GID vacío en .env (gid de los shares = $FG):"
            echo "      echo \"FILES_GID=$FG\" >> $ROOT/.env"
        else
            echo "    ATENCIÓN: FILES_GID vacío y todavía no existe /srv/samba/departamentos."
        fi
    fi
fi
cd "$ROOT"
sudo docker compose up -d --build
echo "    contenedores levantados/actualizados"

# Habilitar orquestador de arranque en el boot (tso-it-startup.service)
if [ -f "$DIR/start-it.sh" ]; then
    echo "==> [Boot] Configurando servicio de arranque automático (tso-it-startup)..."
    sudo bash "$DIR/start-it.sh" --install-service >/dev/null 2>&1 || true
    echo "    tso-it-startup.service habilitado (orquestará servicios en cada inicio)"
fi

# Sincronizar registros DNS en Samba AD DC (firma, webmail, etc.)
if [ -f "$ROOT/dc/dns-records.sh" ] && command -v samba-tool >/dev/null 2>&1; then
    echo "==> [DNS] Sincronizando registros A en Samba AD DC (firma, webmail, etc.)..."
    if ! klist -s 2>/dev/null && [ -f "$ROOT/.env" ]; then
        AD_PASS="$(grep -E '^AD_ADMIN_PASSWORD=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d "\"'" || true)"
        if [ -n "$AD_PASS" ]; then
            printf '%s\n' "$AD_PASS" | kinit administrator >/dev/null 2>&1 || true
        fi
    fi
    sudo bash "$ROOT/dc/dns-records.sh" || true
fi

echo
echo "===================================================================="
echo "  Deploy completado."
echo "  * Firewall nftables: tabla inet filter aplicada y habilitada"
echo "  * SSH: config endurecida (claves, sin root, solo admins)"
echo "  * Chrony: sirviendo hora a 192.168.0.0/24"
echo "  * FreeRADIUS: 1812/udp (WiFi 802.1X; sonda cada 5 min → Prometheus)"
echo "  * Contenedores: docker compose up -d --build (proxy web + firma actualizados)"
echo "  * Orquestador boot: tso-it-startup.service activo (comando: sudo tso-start)"
echo "  * DNS: registros de servicios (firma/webmail/etc) en dc/dns-records.sh"
echo "  * Probar en OTRA terminal: ssh joaquin@192.168.0.2"
echo
echo "  Si los contenedores pierden red tras aplicar el firewall,"
echo "  reiniciar Docker (recrea sus cadenas):"
echo "    sudo systemctl restart docker"
echo "===================================================================="