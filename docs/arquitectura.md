# Infraestructura IT — Organización (todo Linux)

> Documento de **diseño y entendimiento**. Acá se explica cómo está montado
> y cómo se montará todo el IT de la organización, antes de aplicarlo.
> Es la evolución "empresarial" del laboratorio [`../TSO-II`](../../TSO-II).
>
> Índice de documentación: [`docs/README.md`](README.md).

---

## 1. Visión

Una infraestructura **100% Linux** (servidor y clientes, con unas pocas
máquinas Windows solo donde el software lo exige: contabilidad / marketing),
montada sobre **una sola máquina física** estilo "laptop siempre encendida"
(igual que el laboratorio), con:

| Pilar | Tecnología |
| --- | --- |
| Identidad (AD DC) | **Samba 4** como controlador de dominio (`dc/`) |
| Virtualización de servicios | **Docker + docker-compose** (heredado del lab) |
| Clientes | **Linux** (autentican contra AD con SSSD) + **Windows** puntuales |

El corazón de todo es el **controlador de dominio de Samba**: provee
autenticación (Kerberos), directorio (LDAP), DNS autoritativo del dominio y
recursos de archivos (SMB), y es la cuenta central de usuarios, grupos y
equipos. Sobre esa base se montan los contenedores del lab (DHCP, correo,
web/proxy, base de datos, impresión, Portainer) más servicios nuevos.

---

## 2. Principios de diseño

1. **Todo Linux, contenedores a full.** El DC de Samba corre **nativo** sobre
   Debian (no en contenedor); el resto de servicios, en contenedores.
2. **El DC no vive en un contenedor.** Un DC de Samba en Docker es frágil
   (red, DNS y hostname fijos; estado in-memory de Kerberos/LDAP). Es la misma
   conclusión que quedó documentada en el lab (`services/domain/README.md`).
3. **DNS lo manda el DC.** En un AD, el controlador de dominio DEBE ser
   autoritativo de la zona del dominio. El Bind9 del lab se reacomoda: el DC
   toma la zona activa y Bind9 queda como caché/reenvío o se retira.
4. **Un solo `docker-compose.yml` por máquina.** Mismo flujo colaborativo y de
   versionado que el lab; cada servicio en su carpeta `services/<nombre>`.
5. **Sin secretos en el repo.** Contraseñas/tokens en `.env` (ignorado);
   en el repo solo `.env.example`.
6. **Escalable sin rediseño.** El modelo admite sumar un segundo DC o pasar el
   host de contenedores a otra máquina sin tocar la arquitectura.
7. **Seguridad por defecto:** firewall con política *drop*, SSH sin contraseña,
   TLS con CA interna, backups automáticos.

---

## 3. Arquitectura general

```text
                       ┌──────────────────────────────────────────────────┐
       INTERNET        │          MAQUINA SERVICIO (una sola)            │
         │             │                                                │
       ROUTER          │   ┌────────────────────────────────────────┐   │
         │             │   │  DOCKER  (red interna tso-net)         │   │
         │             │   │                                        │   │
         ║             │   │  ┌───────────┐  ┌───────────────┐   │   │
   ┌────────────┐      │   │  │ nginx     │  │ postfix+dovecot│   │   │
   │ LAN ÚNICA  │      │   │  │ (proxy    │  │ (correo)      │   │   │
   │192.168.0.0/24│◄───IP .10 (la cara del DC) │             │   │   │
   │            │      │   │  └───────────┘  └───────────────┘   │   │
   │ - abmins   │      │   │  ┌───────────────┐  ┌──────────────┐│   │
   │ - usuarios │      │   │  │ kea (DHCP)    │  │ postgres/maria│   │
   │ - clientes │      │   │  │  (host net)   │  └──────────────┘│   │
   └────────────┘      │   │  └───────────────┘  ┌────────────┐ │   │
         │             │   │  ┌───────────────┐  │ cups - print│ │   │
    CLIENTES           │   │  │ roundcube,    │  └────────────┘ │   │
    (Linux y Windows   │   │  │ apps,         │                 │   │
     se unen al        │   │  │ monitoreo,    │                 │   │
     dominio)          │   │  │ portainer     │                 │   │
         │             │   │  └───────────────┘                 │   │
         │             │   └──────────────────────────────────────────┘ │
         │             │   ┌──────────────────────────────────────────┐ │
         │             │   │  NATIVO (fuera de Docker)                │ │
         │             │   │  ┌────────────────────────────────────┐ │ │
         │             │   │  │ SAMBA 4 AD DC (dc1.sudoers.lan)   │ │ │
         │             │   │  │  - Kerberos KDC                   │ │ │
         │             │   │  │  - LDAP (directorio)              │ │ │
         │             │   │  │  - DNS autoritativo (zona AD)     │ │ │
         │             │   │  │  - Recursos SMB (archivos)        │ │ │
         │             │   │  └────────────────────────────────────┘ │ │
         │             │   │  chrony (NTP) · nftables · ssh ·        │ │
         │             │   │  unattended-upgrades                    │ │
         │             │   └─────────────────────────────────────┘    │ │
         │             │                                                │
                       └──────────────────────────────────────────────────┘
```

**Flujo simple:** los clientes arrancan, piden IP al **Kea (DHCP)**, que les
entrega como DNS la IP del DC. Cualquier login pasa por **Kerberos/LDAP del
DC**; los archivos se guardan en el **Samba del DC**; la web y apps entran por
el **proxy reverso nginx**; el correo es **Postfix+Dovecot** autenticando
contra LDAP del DC.

---

## 4. Red y direccionamiento (plan IP)

### Red única

Todo vive en **una sola red plana** `192.168.0.0/24` (la que sí está bajo
control). Queda descartada la `192.168.20.0/24` del lab porque sobre esa red
no hay control del acceso.

| Red | Uso | IP del server (fija) |
| --- | --- | --- |
| `192.168.0.0/24` | Admin + usuarios + clientes (todo) | `192.168.0.2` |

El router (TP-Link **TL-WR850N**) es la puerta de enlace en `192.168.0.1` y
maneja la red. La IP `192.168.0.2` es la del DC (server conectado **por
cable** al router) y la que reciben los clientes como DNS por DHCP. Todo
hostname del DC apunta a esa IP de LAN (nunca a `127.0.0.1`) — requisito de
Samba AD.

### Rango de DHCP (Kea, modo host network)

| Zona | Rango | Destino |
| --- | --- | --- |
| Fija | `192.168.0.1 – .49` | Infraestructura, impresoras, servidores (reservas) |
| Reservas | `192.168.0.50 – .99` | Equipos fijos (PC contabilidad, marketing, cajas) |
| Pool dinámico | `192.168.0.100 – .199` | Resto de clientes |

Opciones DHCP entregadas: **gateway = 192.168.0.1** (router TP-Link),
**DNS = 192.168.0.2**, **dominio = sudoers.lan**, **NTP = 192.168.0.2**.

### Reservas DHCP por MAC (Kea)

Se declaran en `.env` → `DHCP_RESERVATIONS` con el formato
`"MAC=IP=hostname;…"` (los admins ocupan `.50–.52` para coincidir con
`admin_ips` del firewall). El entrypoint de Kea convierte esa variable al
array `reservations` del subnet. Cuando Kea toma el servicio, **se apaga el
DHCP del router** para no duplicar concesiones.

> **Ojo (lección del lab):** Kea recibe el pool *host network* en Docker
> (`network_mode: host`). BOOTP/DHCP usa *broadcast* en `67/udp`, que no
> funciona mapeando puerto a través de un bridge. Es de los pocos servicios
> que escapa de la red interna.

### Nombres (AD)

| Qué | Nombre |
| --- | --- |
| Dominio/realm AD | `SUDOERS.LAN` (Kerberos realm: `SUDOERS.LAN`) |
| DC / host del server | `dc1.sudoers.lan` (NetBIOS `DC1`) |
| Proveedor de correo | `mail.sudoers.lan` |
| Proxy/web interna | `proxy.sudoers.lan` / `*.sudoers.lan` |
| Bases de datos | `db.sudoers.lan` |

---

## 5. Servicios: roles y dónde corren

| Servicio | Rol / Tecnología | Dónde corre | Origen |
| --- | --- | --- | --- |
| **AD DC** | Identidad: Kerberos + LDAP + SMB | NATIVO (`samba` / `smbd` en el DC) | decisión del lab |
| **DNS autoritativo AD** | Zona `sudoers.lan` + registros SRV/TXT del DC | NATIVO (interno del DC) | adaptación del `services/dns` |
| **DHCP** | Kea DHCP4 | CONTENEDOR (`network_mode: host`) | `services/dhcp` (lab) |
| **NTP** | chrony (fuente de tiempo de la red) | NATIVO | nuevo |
| **Correo** | Postfix + Dovecot (SMTP/IMAP/POP) | CONTENEDOR | `services/mail` (lab) |
| **Webmail** | Roundcube (correo por navegador) | CONTENEDOR | nuevo |
| **Archivos** | Recursos SMB del DC (permisos por grupos AD) | NATIVO (`dc/shares.conf` del DC) | `services/files` reubicado |
| **Web / Proxy inverso** | Nginx: TLS + ruteo `*.sudoers.lan` | CONTENEDOR | `services/web` (lab), rol ampliado |
| **Base de datos** | PostgreSQL (+ MariaDB según app) | CONTENEDOR | `services/database` (lab) |
| **Impresión** | CUPS (+ impresora PDF) | CONTENEDOR | `services/print` (lab) |
| **Gestión Docker** | Portainer | CONTENEDOR | lab |
| **Apps internas** | wiki, gestor de tareas, vault, etc. | CONTENEDOR | nuevo |
| **Monitoreo** | Netdata / Grafana+Prometheus | CONTENEDOR | nuevo |
| **Backup** | restic/borg (+ dump DB, backup del AD) | NATIVO (cron) | nuevo |
| **Firewall** | nftables (política *drop*) | NATIVO | `server/nftables.conf` (lab) |
| **SSH** | endurecido, solo claves | NATIVO | `server/sshd_config` (lab) |

---

## 6. Identidad y autenticación (el DC)

El **DC de Samba** es la fuente de verdad:

- **Kerberos** (KDC): tickets para login y SMB. Es el porqué de todo lo demás.
- **LDAP** (`389`): directorio de usuarios, grupos y equipos.
- **DNS interno**: zona AD con los registros `_sites`, `_tcp`, `_kerberos`, `_ldap`.
- **SMB** (`445`): archivos y también sirve de "login" de recursos.

### Usuarios y grupos (modelo)

| Grupo AD | Uso |
| --- | --- |
| `admins` | Gestión del server, sudo, SSH |
| `sistemas` | Soporte/mantenimiento |
| `contabilidad` | PCs Windows con software contable |
| `marketing` | PCs Windows / edición |
| `oficina` | Resto de usuarios Linux |
| `srv-dba` | Acceso a DB |
| `srv-mail` | Acceso a buzones |
| `srv-files` | Recursos de archivo por departamento |

El **sudo** de las máquinas Linux se gobierna con grupos AD vía **SSSD**.

### Clientes

- **Clientes Linux (mayoría).** Unirse con `realm join` + **SSSD**:
  - Auth Kerberos + LDAP contra el DC.
  - `sudo` desde grupos AD (`admins`, `sistemas`).
  - Montar home/recursos Samba con `pam_mkhomedir`.
  - Time sync vía NTP del DC.
  - Distros: Debian/Ubuntu (y/o Fedora) según preferencia del usuario.
- **Windows (contabilidad / marketing, pocas).** Unirse al dominio `SUDOERS`
  como equipos estándar (auth + SMB + Kerberos).
  - GPO: soporte limitado en Samba; no es un AD de Windows, lo anotamos a
    efectos de alcance.

---

## 7. Archivos

El **DC ya es servidor de archivos** (Samba tiene los dos roles). En el
`smb.conf` del DC se definen los recursos:

| Recurso | Contenido |
| --- | --- |
| `[departamentos]` | Carpetas por grupo/departamento con ACL sobre grupos AD |
| `[homes]` | Home de cada usuario sobre Samba (creado por `pam_mkhomedir`) |
| `[respaldo]` | Cuota compartida con el sistema de backup |

> Los permisos se dan a **grupos AD**, nunca a usuarios individuales.
> El `services/files` del lab (Samba contenedor + NFS) puede quedar como
> recurso secundario/miembro si se necesita NFS o un share aislado.

---

## 8. Correo

- **Postfix** (MTA) + **Dovecot** (IMAP/POP) en contenedor, heredado del lab.
- **Cuentas = usuarios AD.** Autenticación de SMTP/IMAP contra LDAP del DC
  (bind) con contraseña Kerberos; no se duplican usuarios.
- Entrega local a buzones en volumen (Maildir).
- **Webmail Roundcube** publicado por el proxy (correo desde el navegador).
- DNS interno: `MX sudoers.lan → mail.sudoers.lan`; SPF/DKIM si en algún
  momento el correo sale a Internet (en la LAN aislada es correo interno).

---

## 9. Proxy inverso y web

Nginx en contenedor es **la única puerta hacia los servicios web por nombre**:

| Nombre | Backend |
| --- | --- |
| `portainer.sudoers.lan` | Portainer (también directo `:9443`) |
| `webmail.sudoers.lan` | Roundcube |
| `wiki.sudoers.lan`, `apps.sudoers.lan`, … | Apps internas en contenedores |
| `dashboard.sudoers.lan` | Monitoreo |

- **TLS** con **CA interna** (el DC emite certificados; para Linux también se
  puede drop una CA propia con OpenSSL/step-ca). El proxy termina TLS y
  reenvía por la red interna `tso-net`. Los clientes confían en la CA raíz.
- SSH/e infraestructura **no** se exponen por el proxy.

---

## 10. Base de datos

- **PostgreSQL** (y **MariaDB** si una app lo pide) en contenedor, heredado
  del lab, como backend de: wikis/apps, webmail, logs del proxy y monitoreo.
- Acceso limitado a grupos AD (`srv-dba`) por firewall (solo IPs admin).
  Copias diarias vía backup.

---

## 11. Contenedores: relación con el lab

El `docker-compose.yml` del lab es la base; se reutiliza y adapta:

| Servicio lab | En esta arquitectura |
| --- | --- |
| `dns` (Bind9) | **Retirado** de DNS del dominio: el DC toma la zona AD. (Queda Bind9 como caché/reenvío opcional o se elimina.) |
| `dhcp` (Kea) | Se mantiene, con `network_mode: host` para el broadcast. |
| `files` (Samba cont.) | Reubicado: los recursos los sirve el DC nativo; el contenedor queda solo si hace falta NFS/share aislado. |
| `web` (Nginx) | Se mantiene y **pasa a proxy inverso** (`*.sudoers.lan`). |
| `mail` (Postfix+Dovecot) | Se mantiene; se conecta la auth a LDAP del DC. |
| `database` (PostgreSQL) | Se mantiene. |
| `print` (CUPS) | Se mantiene. |
| `portainer` | Se mantiene. |
| — nuevos — | Roundcube, apps, monitoreo, backup (volúmenes y bloques nuevos en el compose). |

**Puertos en conflicto con el DC nativo** (no se re-publican en contenedor):
`53`, `88`, `389`, `445`, `139`, `636` (cifrado LDAP opcional) → son del DC.

---

## 12. Seguridad

Al ser **una sola red plana sin segmentación**, la seguridad se apoya en el
firewall del host y en la autenticación AD:

1. **Firewall nftables** (lab, adaptado): `drop` por defecto en INPUT.
   - Para clientes: HTTP/HTTPS (proxy), SMTP/IMAP/POP, DNS, DHCP, CUPS,
     LDAP/Kerberos, SMB y NTP hacia el DC.
   - Solo IPs admin (o red de admins): SSH (22), Portainer (9443),
     PostgreSQL (5432) y monitoreo.
2. **SSH endurecido** (lab): solo claves, sin root, solo usuarios `admins`.
3. **TLS**: certificados internos firmados por CA interna; el proxy expone
   solo HTTPS.
4. **Password policy** en AD (`samba-tool domain passwordsettings`).
5. **Actualizaciones**: `unattended-upgrades` en el host + rebuild de
   imágenes cuando cambian.
6. **Sin secretos en git**: `.env` ignorado.

---

## 13. Backups y monitoreo

- **Backup (nativo, cron):**
  - Dumps de PostgreSQL/MariaDB diarios.
  - `restic/borg` de los volúmenes Docker + `/var/lib/samba` y configs.
  - Respaldo del AD con `samba-tool domain backup` (estado completo del DC).
  - Destino: disco/red auxiliar; idealmente una copia fuera del sitio.
- **Monitoreo (contenedor):**
  - Netdata (rápido, host + contenedores) y/o Grafana+Prometheus.
  - Alertas por correo interno.
  - Vistas: CPU/RAM/disco/red, estado de cada contenedor y del DC.

---

## 14. Plan de implementación (fases)

**Fase 0 — Base del server.** Debian instalado, hostname `dc1`, IP fija
`192.168.0.2` (cable al router TP-Link `192.168.0.1`), `sshd` endurecido,
nftables, chrony, `unattended-upgrades`. Repo `TSO-II-final` clonado.

**Fase 1 — Controlador de dominio.** `samba-tool domain provision` (realm
`SUDOERS.LAN`), DNS interno AD funcionando, zona `sudoers.lan` resolviendo.
Los admins se unen y verifican login Kerberos.

**Fase 2 — Red y clientes.** Kea (host network) sirviendo `192.168.0.0/24`
con reservas. Clientes Linux con `realm join` + SSSD. Las Windows de
contabilidad/marketing se unen al dominio.

**Fase 3 — Archivos.** Recursos `[departamentos]`, `[homes]`, `[respaldo]` en
el DC; permisos por grupos AD; homes automáticos en clientes.

**Fase 4 — Correo.** Postfix+Dovecot con auth LDAP, MX interno,
Roundcube por webmail.

**Fase 5 — Web/proxy + datos.** Nginx como proxy inverso `*.sudoers.lan`,
CA interna, PostgreSQL/MariaDB, apps internas en contenedores.

**Fase 6 — Consolidación.** Monitoreo, backups automáticos, password policy,
prueba de DR (restaurar desde backup), documentación final.

---

## 15. Estructura del repo (TSO-II-final)

```text
TSO-II-final/
├── AGENTS.md                  ← contexto resumido para agentes de IA
├── docker-compose.yml        ← todos los servicios contenedor (adaptado del lab)
├── .env.example
├── README.md                 ← índice corto → apunta a docs/
├── dc/                       ← Samba AD DC (NATIVO)
│   ├── provision.sh          ← provision + arranque del DC
│   ├── shares.conf           ← recursos de archivo ([departamentos], [homes], [respaldo])
│   ├── krb5.conf             ← archivo de ejemplo (lo genera provision.sh)
│   ├── add-users-groups.sh   ← grupos/usuarios de la org (idempotente)
│   ├── password-policy.sh    ← hardening de contraseñas del dominio
│   └── README.md
├── server/                   ← config del host (firewall, ssh, ntp, deploy)
│   ├── nftables.conf
│   ├── sshd_config
│   ├── chrony.conf
│   └── deploy.sh
├── clients/                  ← guías para unir clientes al dominio (pendiente)
│   └── README.md
├── services/                 ← por servicio contenedor (heredado del lab)
│   ├── dhcp/                 ← Kea (host network)
│   ├── mail/                 ← Postfix + Dovecot (auth LDAP pendiente)
│   ├── web/                  ← Nginx proxy inverso
│   ├── database/             ← PostgreSQL / MariaDB
│   ├── print/                ← CUPS
│   ├── dns/                  ← retirado (el DNS lo da el DC) — README
│   ├── webmail/              ← Roundcube (nuevo, pendiente)
│   ├── monitoring/           ← Netdata / Grafana (nuevo, pendiente)
│   └── apps/                 ← apps internas (nuevo, pendiente)
└── docs/
    ├── README.md             ← índice de documentación
    └── arquitectura.md       ← este documento (diseño completo)
```

---

## 16. Notas y limitaciones honestas

1. **Un solo punto de falla.** Toda la organización depende de una máquina.
   El diseño lo asume (estilo lab). Mitigación mínima: backups buenos + plan
   de restauración documentado. Escalar es: sumar un 2º DC y separar el host
   de contenedores — sin cambiar arquitectura.
2. **Red plana sin segmentación.** Todo está en `192.168.0.0/24`; la
   separación de tráfico se compensa con firewall por host + auth AD. Si más
   adelante se quiere aislar (guest/wifi/iot), se puede VLANizar sin rediseñar.
3. **Samba AD ≠ AD de Windows.** Cubre auth, LDAP, Kerberos, SMB y DNS, pero
   **no** GPO completas ni Exchange. Para las pocas Windows alcanza con
   unirse al dominio; si algún día se exige Exchange/AD real, se suma una VM
   Windows (no cambia el resto del diseño).
4. **Correo**. En LAN aislada es correo interno (`MX` interno). Para salida a
   Internet real haría falta SPF/DKIM/relay autorizado (se documenta cuando
   aplique).
5. **Puertos críticos del DC** quedan fuera de Docker a propósito (lección
   documentada en el lab).