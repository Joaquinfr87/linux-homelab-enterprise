# AGENTS.md — Contexto para agentes de IA

> Resumen ejecutivo del proyecto. Si necesitás profundizar, leé
> [`docs/arquitectura.md`](docs/arquitectura.md) — es la fuente de verdad.

## Qué es este repo

Infraestructura IT de una organización, **100% Linux**, sobre una **sola
máquina Debian** ("laptop siempre encendida", estilo lab). Es la evolución
"empresarial" del laboratorio del repo hermano `../TSO-II`.

- **AD DC = Samba 4, NATIVO** (fuera de Docker) → carpeta `dc/`.
- **Resto de servicios = contenedores Docker** (docker-compose), heredados y
  adaptados del lab → `services/` + `docker-compose.yml`.
- **Clientes**: Linux (mayoría) + unas pocas **Windows** solo para
  contabilidad/marketing. Todos unidos al dominio AD.

## Datos de red (IMPORTANTE)

- **UNA sola red plana:** `192.168.0.0/24`. La antigua `192.168.20.0/24` del
  lab quedó **descartada** (no hay control sobre esa red).
- **Router:** TP-Link **TL-WR850N v3** (Hardware Ver. `00000002`, firmware
  3.16.0), IP `192.168.0.1`, maneja la red y es la puerta de enlace. Su DHCP
  **se desactiva** cuando Kea tome el servicio (evita DHCP doble).
- **Server / DC:** ip fija **`192.168.0.2`** (conectado **por cable** al
  router), hostname `dc1` → `dc1.sudoers.lan`. La IP `192.168.0.10` del
  diseño original quedó descartada.
- **DHCP (Kea):** pool dinámico `192.168.0.100–199`; reservas `.1–.49`
  infraestructura, `.50–.99` equipos fijos (impresoras, PCs admin, cajas).
  Entrega como **DNS = 192.168.0.2**, dominio `sudoers.lan`, gateway
  `192.168.0.1`, NTP `192.168.0.2`.
- **Reservas por MAC:** se configuran en `.env` → `DHCP_RESERVATIONS`
  (formato `"MAC=IP=hostname;…"`), que el entrypoint de Kea convierte a
  reservas del subnet. Los PCs de los admins ocupan `.50–.52` (coincide con
  `admin_ips` del firewall); el server Zabbix `zabbix` ocupa `.3`
  (infraestructura).
- **AD:** dominio/realm `SUDOERS.LAN`, NetBIOS `SUDOERS`, Kerberos realm `SUDOERS.LAN`.

## Máquinas

- **dc1** = `192.168.0.2` — el host físico principal (DC Samba + Docker +
  resto de servicios). Es la máquina "siempre encendida".
- **zabbix** = `192.168.0.3` — **server Debian FÍSICO dedicado** (Debian 13)
  que corre **solo Zabbix**: server + web + Postgres vía `services/zabbix`
  (compose propio). **No es una VM** (se descartó la idea de la
  VM/laptop). Alcanzable de forma directa por toda la LAN (sin NAT). Web
  publicada directamente como `zabbix.sudoers.lan` → `192.168.0.3:80`
  (login `Admin/zabbix` — **cambiar**). El server consulta agents en
  **modo pasivo** (`10050`, origen `192.168.0.3`). Reserva por MAC en
  `.1–.49` (infraestructura); hostname `zabbix`.
- **Equipos de admins:** `pc-joaquin .50`, `pc-david .51`, `pc-nicolas .52`
  (fijos, `.50–.99`); usuarios dinámicos en `.100–.199`.

## Usuarios (AD)

- **Admins:** `joaquin`, `nicolas`, `david` (grupo `admins` + `sistemas`).
- **Usuarios de prueba:** `grupo2`, `grupo3`, …, `grupo9` (grupo `oficina`).
  Se crean con `dc/add-users-groups.sh`, idempotente.
- **`tsoII`:** usuario nuevo para pruebas de logon script en Windows — cambia
  el wallpaper vía `scriptPath` de AD (script `tsoII-wallpaper.cmd` en netlogon).

## Reglas técnicas que NO se negocian

1. **El DC de Samba corre NATIVO, nunca en contenedor** (frágil; decisión ya
   documentada en el lab `services/domain/README.md`).
2. **DNS autoritativo del dominio lo maneja el DC** (zona AD + SRV). El
   Bind9 del lab se retira/adapta; no compite con la zona `sudoers.lan`.
3. **Kea requiere `network_mode: host`** en Docker: BOOTP/DHCP usa broadcast
   `67/udp` y no funciona mapeado a través de un bridge.
4. **Puertos del DC NO se re-publican en contenedores:** `53`, `88`, `389`,
   `445`, `139` (+ `636` LDAPS opcional). Son del DC nativo.
5. **Sin secretos en git:** `.env` ignorado; en el repo solo `.env.example`.
6. **Un solo `docker-compose.yml`** en la raíz declara todos los servicios.
7. **FreeRADIUS corre NATIVO en dc1** (necesita `ntlm_auth`/winbind local
   del DC; mismo argumento de fragilidad que el DC, nunca en contenedor).

## Servicios (resumen)

| Servicio | Cómo | Dónde |
| --- | --- | --- |
| AD DC (identidad: Kerberos+LDAP+DNS+SMB) | Samba 4 | NATIVO (`dc/`) |
| NTP | chrony | NATIVO |
| Firewall / SSH | nftables / sshd endurecido | NATIVO (`server/`) |
| DHCP | Kea | CONTENEDOR (`services/dhcp`, host network) |
| Correo | Postfix + Dovecot (auth local; LDAP AD pendiente) | CONTENEDOR (`services/mail`) |
| Webmail | Roundcube | CONTENEDOR (`services/webmail`) |
| Archivos | Shares SMB del DC (perms por grupos AD) + gestor web | NATIVO (`smb.conf`) + CONTENEDOR (`services/filemanager`) |
| Firma Digital PAdES | PKI CA UPDS + API Criptográfica + Frontend Astro | CONTENEDOR (`services/firma`, `firma.sudoers.lan`) |
| Web/Proxy inverso | Nginx `*.sudoers.lan` + TLS | CONTENEDOR (`services/web`) |
| Base de datos | PostgreSQL (+MariaDB si hace falta) | CONTENEDOR (`services/database`) |
| Impresión | CUPS | CONTENEDOR (`services/print`) |
| Gestión Docker | Portainer | CONTENEDOR |
| Monitoreo | Zabbix (server + web; agents en hosts) | Server Debian físico `zabbix` (`192.168.0.3`) — `services/zabbix` (compose propio) |
| Métricas + alertas por mail | Prometheus + Grafana + Alertmanager (Grafana en `grafana.sudoers.lan`) | CONTENEDOR (`services/monitoring`, dc1) |
| WiFi 802.1X (WPA2-Enterprise) | FreeRADIUS → `ntlm_auth` → AD (usuarios del dominio) | NATIVO (`server/radius/`) |
| IDS / IPS (Seguridad de red) | Suricata 7 (AF_PACKET pasivo / NFQUEUE en línea) | NATIVO (`server/suricata/`) |
| Backup | restic (`server/backup.sh` + `restore.sh`, cron) | NATIVO |

## Estructura del repo

```text
TSO-II-final/
├── AGENTS.md            ← este archivo (contexto para IA)
├── docker-compose.yml   ← servicios contenedor (fuente de verdad)
├── .env.example
├── README.md            ← índice corto → docs/
├── dc/                  ← Samba AD DC nativo (provision.sh, shares.conf, krb5, scripts)
├── server/              ← host: nftables, sshd, chrony, radius/ (WiFi 802.1X), suricata/ (IDS/IPS), deploy
├── clients/             ← guías de clientes (wifi.md ✓; linux/windows pendientes)
├── services/            ← por servicio contenedor (dhcp, web, mail, webmail, db, print, monitoring, snort)
└── docs/                ← TODA la documentación (ids-ips.md, arquitectura, futuro: red, seguridad, backup…)

Máquinas: dc1 (host físico, 192.168.0.2) + zabbix (server Debian físico dedicado, 192.168.0.3).
```

## Flujo de trabajo habitual

```bash
cp .env.example .env
docker compose up -d --build            # levantar/actualizar servicios
docker compose up -d <servicio>         # servicio puntual
```

- Documentación nueva va SIEMPRE en `docs/` (no inflar el `README.md`).
- Un servicio nuevo = carpeta `services/<nombre>` + bloque en el compose.
- En el server físico: `git pull && sudo bash server/deploy.sh` (no tocar a mano).

## Pendientes (próximos pasos)

1. **Monitoreo Zabbix → alertas por mail:** Zabbix ya corre y recolecta
   (hosts, templates propios y agents), pero **los triggers no mandan
   correos**: las acciones existen (`TSO - Servicio o contenedor caído
   (admins)` y `TSO - Servicio de Zabbix (re)iniciado (todos los usuarios)`)
   y los eventos se generan, pero `alert.get` queda en 0. Cerrar ese debug
   (condición tag/valor de la acción, `mediatypeid`, prueba E2E hasta ver el
   mail saliendo por Postfix de dc1) y sumar agents a los clientes.
   (Las alertas del stack Prometheus/Alertmanager **sí** mandan mail.)
2. **WiFi "sudoers" 802.1X — implementado, falta desplegar:** el repo ya
   trae FreeRADIUS nativo (`server/radius/` + deploy). Pendiente **en dc1**:
   `git pull && sudo bash server/deploy.sh`, poner el router en
   WPA/WPA2-Enterprise (Radius Server IP `192.168.0.2`, puerto `1812`,
   password = `RADIUS_SECRET` de `.env`) y probar un cliente real
   (ver `clients/wifi.md`; prueba previa: `radtest -t mschap` en dc1).
3. **Clientes al dominio:** `clients/linux.md` (SSSD/realm join) y
   `clients/windows.md` (unión de Windows al AD) — Fase 2.

## Documentación detallada

- [`docs/arquitectura.md`](docs/arquitectura.md) — diseño completo, plan IP,
  fases de implementación (Fase 0→6) y limitaciones.
- [`docs/README.md`](docs/README.md) — índice de documentación.
- Laboratorio original: `../TSO-II` (servicios base y decisiones).