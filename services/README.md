# services/ — Servicios en contenedores (heredados y adaptados del lab)

Cada servicio tiene su carpeta con su configuración; algunos usan una imagen oficial. El
`docker-compose.yml` de la raíz es la fuente de verdad que los declara.

| Carpeta | Servicio | Estado |
| --- | --- | --- |
| [`dhcp/`](dhcp/README.md) | Kea DHCP (host network) | listo (adaptado del lab) |
| [`web/`](web/README.md) | Nginx proxy inverso `*.sudoers.lan` | listo (adaptado) |
| [`mail/`](mail/README.md) | Postfix + Dovecot | listo (auth LDAP pendiente) |
| [`database/`](database/README.md) | PostgreSQL | listo (heredado) |
| [`print/`](print/README.md) | CUPS + PDF virtual | listo (heredado) |
| [`dns/`](dns/README.md) | Bind9 — **RETIRADO**: el DNS lo da el DC | documentado |
| [`zabbix/`](zabbix/README.md) | Zabbix (monitoreo) — **server Debian físico `192.168.0.3`, compose propio** | nuevo |
| [`webmail/`](webmail/README.md) | Roundcube | listo (webmail local) |
| [`filemanager/`](filemanager/README.md) | Filebrowser — gestor web de los shares del DC | listo |
| [`firma/`](firma/README.md) | Firma Digital PAdES (UPDS) — Identidad Criptográfica, CA y firmado PDF | nuevo |
| [`monitoring/`](monitoring/README.md) | Prometheus + Grafana + Alertmanager (en dc1) — alertas por correo | nuevo |
| [`apps/`](apps/README.md) | Apps internas (Fase 5) | **pendiente (vacío)** |

> Los **datos** de los archivos viven en el DC nativo (`/srv/samba`, ver
> `dc/shares.conf`); `filemanager/` es solo la puerta web sobre esos mismos
> directorios. NFS/share aislado se suma dentro de `apps/` si hace falta.

## Cómo agregar un servicio nuevo

1. Crear `services/<nombre>/` con `Dockerfile` (+ config) y `README.md`.
2. Agregar el bloque en el `docker-compose.yml` raíz.
3. Si expone web por nombre, agregar el server block en `services/web/nginx.conf`.
4. Documentar en `docs/` y en este índice.

## Reglas

- Ningún puerto del DC nativo se publica: `53, 88, 389, 445, 139, 636`.
- Sin secretos: contraseñas en `.env`, nunca en el repo.
- Kea es el único servicio con `network_mode: host`.