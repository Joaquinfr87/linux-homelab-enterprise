# server/ — Configuración del host (fuera de Docker)

Acá vive la configuración del **sistema operativo** del servidor físico: lo
que corre nativo (firewall, SSH, NTP) más el `deploy.sh`. Todo se versiona y
se aplica desde el repo; nadie toca el server a mano.

## Estructura

```text
server/
├── README.md        ← este archivo
├── start-it.sh      ← orquestador de arranque, autorrecuperación y diagnóstico al boot
├── tso-it-startup.service ← servicio systemd para iniciar la infraestructura en el boot
├── bootstrap.sh     ← deja dc1 operativo de punta a punta (idempotente)
├── set-ip.sh        ← fija la IP de dc1 (192.168.0.2) con rollback automático
├── gen-env.sh       ← crea/completa .env con secretos aleatorios
├── nftables.conf    ← firewall red única 192.168.0.0/24 (política drop)
├── sshd_config      ← SSH endurecido (solo claves, solo admins)
├── chrony.conf      ← NTP de la red (los clientes sincronizan contra el DC)
├── backup.sh        ← backup con restic (cron diario)
├── restore.sh       ← restaurar desde el repo de restic
├── radius/          ← FreeRADIUS nativo (WiFi WPA2-Enterprise / 802.1X)
│   ├── clients.conf     ← clientes RADIUS (router + localhost)
│   ├── mod-mschap       ← MSCHAPv2 contra el AD vía ntlm_auth
│   ├── tls-gen.sh       ← CA + cert EAP (PEAP)
│   ├── radius-check.sh  ← sonda → radius.prom (Prometheus)
│   └── README.md
└── deploy.sh        ← valida y aplica los configs de forma segura
```

## Puesta en marcha desde cero

```bash
git pull
sudo bash server/set-ip.sh --yes --commit   # IP fija .2 (reconectar SSH a .2)
# APAGAR el DHCP del router TP-Link antes del paso siguiente
sudo bash server/bootstrap.sh               # paquetes + AD + DNS + NTP + RADIUS + contenedores
```

`bootstrap.sh` es idempotente y hace: preflight → hostname `dc1`/`/etc/hosts`/
timezone → paquetes → chrony → `.env` con secretos → Samba AD
(`dc/provision.sh` + usuarios + política) → `/etc/resolv.conf` al DC →
permisos de shares → certs TLS → `deploy.sh`. Admite `--check` (solo
diagnóstico) y `--skip-ad` (AD ya provisionado).

## Flujo de trabajo

```bash
# en el server (repo clonado):
git pull
sudo bash server/deploy.sh
```

`deploy.sh` aplica, en orden:

1. **Firewall** nftables (valida con `nft -c`, respalda y recarga).
2. **SSH** endurecido (respalda, valida con `sshd -t` y reinicia).
3. **NTP** chrony (respalda, habilita y reinicia).
4. **FreeRADIUS** WiFi 802.1X (instala si falta, `ntlm auth` en smb.conf,
   configs con `RADIUS_SECRET`, certs EAP, valida con `freeradius -XC`,
   arranca en 1812/udp e instala la sonda `radius-check.sh`).
5. **Contenedores**: valida `services/web/nginx.conf` (con `nginx -t` en
   contenedor) y hace `docker compose up -d --build` desde la raíz del repo.
   Así el proxy web y el resto de servicios quedan al día.

El script **valida la sintaxis** antes de aplicar (`nft -c`, `sshd -t`,
`nginx -t`), **respalda** los configs previos y si algo falla no deja el server
sin conexión.

### DNS (registros de nombres publicados)

Los cambios de config (nginx/compose) se aplican solos con el deploy. Los
**registros A** que exponen servicios (ej. `david`/`nicolas`) se crean una vez
en el DC, con ticket de administrador:

```bash
sudo kinit administrator
sudo bash dc/dns-records.sh    # idempotente: solo agrega lo que falta
```

### Rollback

```bash
sudo nft flush table inet filter && sudo nft -f /etc/nftables.conf   # firewall
sudo cp /etc/ssh/sshd_config.bak.<ts> /etc/ssh/sshd_config && sudo systemctl restart ssh
sudo cp /etc/chrony/chrony.conf.bak.<ts> /etc/chrony/chrony.conf && sudo systemctl restart chrony
```

## Arranque y Recuperación Automática en el Boot (`start-it.sh`)

Al reiniciar el servidor físico, pueden surgir problemas de orden (la red física tarda en levantar, Samba colisiona con smbd/nmbd huérfanos, Kea DHCP falla al enlazar el socket antes de tener IP, o nftables rompe las cadenas NAT de Docker).

Para orquestar el inicio correcto y diagnosticar cualquier falla:

```bash
# Iniciar y diagnosticar todo manualmente
sudo bash server/start-it.sh          # o sudo bash start-it.sh

# Solo diagnóstico (sin reiniciar nada)
sudo bash server/start-it.sh --check

# Habilitar para que corra SIEMPRE de forma automática en cada inicio del sistema
sudo bash server/start-it.sh --install-service
```

Una vez instalado el servicio:
- Se ejecuta automáticamente tras `network-online.target` y `docker.service`.
- Guarda el log completo en `/var/log/tso-startup.log`.
- Guarda el último reporte resumen en `/var/log/tso-startup-summary.txt`.
- Registra logs en systemd consultables con: `journalctl -u tso-it-startup.service -f`.
- Habilita el comando global rápido: `sudo tso-start`.

## Notas

1. El firewall es para **una sola red** `192.168.0.0/24`. Los puertos de
   administración (22, 9443, 5432) se restringen a `admin_ips` (completar en
   `nftables.conf`).
2. Kea (DHCP) usa `network_mode: host` → entra por el puerto 67/udp directo.
3. No usar `flush ruleset` global: rompe las cadenas de Docker.
4. **Antes** de activar SSH sin password: subir las claves con `ssh-copy-id`.
5. Sin secretos en el repo: claves privadas, tokens o passwords nunca acá.

## Interacción con el DC

- El host y el DC son la **misma máquina** (`dc1.sudoers.lan` / 192.168.0.2).
- Chrony del host = NTP que sirve el DC (Kerberos exige reloj sincronizado).
- Puertos del DC nativo (53, 88, 389, 445, 139) quedan abiertos solo a la LAN
  en este firewall; los contenedores no los re-publican.