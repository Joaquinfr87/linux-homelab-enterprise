# TSO-II-final — Infraestructura IT (Linux)

Infraestructura IT de la organización sobre **una sola máquina Debian**:
**AD DC con Samba 4** (nativo, fuera de Docker) + el resto de servicios en
**contenedores Docker** (heredados del lab `TSO-II`). Clientes Linux
(SSSD + AD) con unas pocas Windows para contabilidad/marketing.

Red: **una sola red `192.168.0.0/24`** — server `192.168.0.2`, gateway router `192.168.0.1`

## Documentación

**Toda la documentación vive en [`docs/`](docs/).**

- **[`docs/instalacion.md`](docs/instalacion.md)** — instalación unificada con `install.sh`.
- **[`docs/publicar-servicios-admin.md`](docs/publicar-servicios-admin.md)** — DNS/proxy de servicios internos.
- **[`AGENTS.md`](AGENTS.md)** — contexto resumido para agentes de IA.

## Arranque rápido

```bash
sudo bash install.sh --check     # diagnóstico: no modifica nada
sudo bash install.sh             # instalación completa (interactiva)
```

El instalador unifica IP fija, paquetes, AD, DNS, TLS, firewall, FreeRADIUS,
contenedores, backup y verificación. Deja los logs y las credenciales en
`/var/log/tso-install/<fecha>/` y muestra al final el estado de cada servicio.

- Guía completa: **[`docs/instalacion.md`](docs/instalacion.md)**.
- Para actualizar solo los servicios: `git pull && sudo bash server/deploy.sh`.

## Repos relacionados

- [`../TSO-II`](../TSO-II) — laboratorio original (servicios base: dhcp, mail, web, database, print, portainer).