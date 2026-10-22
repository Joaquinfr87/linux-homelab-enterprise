# Instalación unificada (dc1)

`install.sh` es **el único comando** que hay que ejecutar en una máquina
Debian nueva. Orquesta todos los scripts del repo en un solo flujo, detecta
errores fase por fase y deja un resumen con los accesos y el estado real de
cada servicio.

> Probado en Debian 12/13. El server debe ser **`dc1` / `192.168.0.2`**,
> conectado por cable al router `192.168.0.1`.

## 1. Diagnóstico (no modifica nada)

```bash
cd linux-homelab-enterprise
sudo bash install.sh --check
```

Muestra el estado actual: SO, IP, Docker, AD, DNS, firewall, contenedores,
puertos y URLs. Es la forma recomendada de ver qué falta antes de instalar.
También se puede correr sin root (`bash install.sh --check --no-secrets`),
aunque algunos chequeos quedan limitados.

## 2. Máquina nueva: primero la IP fija

Si la máquina todavía no tiene `192.168.0.2`:

```bash
sudo bash install.sh --set-ip --yes
# La sesión SSH se corta: reconectarse a 192.168.0.2
ssh joaquin@192.168.0.2
cd linux-homelab-enterprise
sudo bash install.sh
```

`--set-ip` usa `server/set-ip.sh --yes --commit` (con rollback automático).
Si se ejecuta desde la consola, sigue con la instalación sin cortar nada.

## 3. Instalación completa

```bash
sudo bash install.sh
```

Pide confirmación y, si el AD todavía no existe, permite definir la clave de
`administrator`. En modo desatendido:

```bash
sudo bash install.sh --yes
```

En ese caso genera claves aleatorias para `administrator` y para los usuarios
AD nuevos, y las guarda en `.env` (`AD_ADMIN_PASSWORD`, `AD_INITIAL_PASSWORD`)
para mostrarlas al final. También se pueden pasar explícitamente:

```bash
sudo bash install.sh --yes --admin-pass 'ClaveSegura!2026'
# o por entorno (no queda en el historial de bash):
ADMIN_PASS='ClaveSegura!2026' sudo -E bash install.sh --yes
```

## Fases

| # | Fase | Qué hace |
| --- | --- | --- |
| 0 | Preflight | Root, Debian, sistema de archivos, red/DNS, Docker, AD, `.env`, usuarios SSH. |
| 1 | Identidad | Hostname `dc1`, `/etc/hosts` sin `127.0.1.1`, TZ Buenos Aires, DNS temporal. |
| 2 | Paquetes + Docker | Samba AD, Kerberos, chrony, FreeRADIUS, nftables, restic, Docker/Compose. |
| 3 | NTP | `server/chrony.conf`, `systemd-timesyncd` deshabilitado. |
| 4 | `.env` | `server/gen-env.sh`; secretos, `ADMIN_IPS_EXTRA` y valores de red. |
| 5 | AD | `dc/provision.sh` (si falta), usuarios/grupos, política, permisos de shares. |
| 6 | DNS | `/etc/resolv.conf` al DC + `dc/dns-records.sh` (mail, web, webmail, archivos, Grafana, Portainer, Zabbix…). |
| 7 | TLS | CA interna + wildcard `*.sudoers.lan` (`services/web/tls-gen.sh`). |
| 8 | Deploy | `server/deploy.sh`: nftables, SSH, chrony, FreeRADIUS y `docker compose up -d --build`. |
| 9 | Backup | Opcional: `server/backup.sh install` si hay un disco montado en `/srv/backup`. |
| 10 | Zabbix agent | Opcional (`--with-zabbix-agent`). |
| 11 | Verificación | AD, DNS, firewall, SSH, NTP, DHCP, RADIUS, contenedores, puertos, HTTPS, backup y disco. |

Cada fase tiene su log en `/var/log/tso-install/<fecha-hora>/` (o en
`/tmp/tso-install/...` si se corre sin root). El resumen final muestra
`PASS / FAIL / SKIP / WARN` por fase y una tabla de servicios.

## Opciones

```text
--check, --dry-run      Solo diagnóstico; no modifica nada.
--yes                   Sin confirmaciones (genera secretos si faltan).
--set-ip                Fija 192.168.0.2 con server/set-ip.sh (requiere --yes).
--host-ip IP            IP del server (default 192.168.0.2).
--gateway IP            Gateway/router (default 192.168.0.1).
--domain DOMINIO        Dominio interno (default sudoers.lan).
--realm REALM           Realm Kerberos (default SUDOERS.LAN).
--netbios NOMBRE        NetBIOS (default SUDOERS).
--dc-name NOMBRE        Hostname corto del DC (default dc1).
--admin-pass CLAVE      Clave de administrator del AD.
--ad-user-pass CLAVE    Clave inicial para usuarios AD nuevos.
--skip-ad               No provisiona el AD (ya existe).
--skip-dns              No crea registros DNS.
--skip-backup           No instala el backup con restic.
--with-zabbix-agent     Instala zabbix-agent2 en dc1 (server 192.168.0.3).
--no-secrets            Enmascara las claves en la salida y en el archivo.
--verbose               Muestra la salida de cada fase en vivo.
-h, --help              Ayuda.
```

## Credenciales y accesos

Al terminar se imprime un panel con:

- `administrator` del AD y la clave inicial de los usuarios.
- Usuarios del dominio y sus grupos (`samba-tool group listmembers`).
- SSH (usuarios permitidos y origen).
- Web: `https://sudoers.lan`, webmail, archivos, Grafana, impresión y Portainer.
- Cuentas de correo (`MAIL_USERS`) y del gestor de archivos (`FILES_USERS`).
- Grafana, CUPS, PostgreSQL, RADIUS/WiFi, Kea y restic.

Todo queda también en `<log>/credenciales.txt` con permisos `600`. **Ese
archivo contiene secretos**: no se comparte ni se versiona. Con
`--no-secrets` se imprime y se guarda enmascarado (útil para pegar la salida
en un issue).

## Después de instalar (manual)

1. **Router**: apagar su DHCP. Kea es el único DHCP de la LAN
   (`192.168.0.100–199`).
2. **WiFi**: WPA/WPA2-Enterprise, RADIUS `192.168.0.2:1812`, secreto
   `RADIUS_SECRET` de `.env` (ver `clients/wifi.md`).
3. **Clientes**: instalar `services/web/tls/ca.crt` y unirlos al dominio
   (`clients/linux.md`, `clients/windows.md`).
4. **Zabbix** (`192.168.0.3`): cambiar `Admin/zabbix` y terminar el envío de
   alertas por mail (pendiente en `AGENTS.md`).
5. **Backup**: si no se instaló, montar el disco en `/srv/backup` y correr
   `sudo bash server/backup.sh install`.

## Problemas frecuentes

- **Ya existe AD y no hay clave de administrator**: la instalación sigue,
  pero no puede crear/actualizar los registros DNS. Ejecutar:
  `sudo kinit administrator && sudo bash dc/dns-records.sh`.
- **El firewall puede cortar SSH**: `install.sh` agrega la IP de origen a
  `ADMIN_IPS_EXTRA`. Si te conectás desde otra IP, agregala en `.env` antes
  de `server/deploy.sh`.
- **Docker compose no aparece**: el instalador prueba el paquete Debian,
  el plugin `docker-compose` y, como último recurso, el repo oficial de
  Docker.
- **Kea no arranca**: el DHCP del router sigue activo. Apagalo y volver a
  correr `sudo bash install.sh`.
- **`samba-ad-dc` no arranca**: revisar `journalctl -u samba-ad-dc -n 80`.
  El instalador no vuelve a provisionar si `/var/lib/samba/private/sam.ldb`
  existe.
- **Reintentar**: el proceso es idempotente. Correr de nuevo
  `sudo bash install.sh` (o `--check` para diagnóstico).

## Comandos útiles de verificación

```bash
sudo bash install.sh --check --no-secrets
systemctl status samba-ad-dc chrony freeradius nftables
docker compose ps
sudo samba-tool domain level show
dig +short dc1.sudoers.lan @127.0.0.1
sudo radtest -t mschap <usuario> '<clave AD>' 127.0.0.1:1812 0 testing123
```
