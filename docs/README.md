# Documentación — TSO-II-final

Índice de la documentación del proyecto. El `README.md` de la raíz es solo un
acceso rápido; **toda la documentación vive acá** (`docs/`).

## Documentos

| Documento | Contenido |
| --- | --- |
| [`arquitectura.md`](arquitectura.md) | **Diseño completo de la infraestructura**: visión, principios, red/IP, servicios, identidad, archivos, correo, proxy, DB, seguridad, backups, plan por fases y limitaciones. Es el documento central. |
| [`auditoria-vulnerabilidades.md`](auditoria-vulnerabilidades.md) | **Auditoría de Vulnerabilidades y Arsenal Defensivo**: Escaneo Nmap NSE, OWASP ZAP, Suricata IDS/IPS, EveBox y plataforma de firma digital PAdES. |
| [`ids-ips.md`](ids-ips.md) | **Guía Técnica de IDS/IPS (Suricata)**: Modos pasivo vs en línea (NFQUEUE), reglas perimetrales y pruebas. |
| [`guia-uso-servicios.md`](guia-uso-servicios.md) | **Guía de Uso de Servicios**: Accesos, puertos y credenciales de los servicios web e infraestructura. |
| [`presentacion.md`](presentacion.md) | Guion de **pruebas en vivo de Samba** para la exposición (server vs cliente, comandos y justificación por etapa). |
| [`guia-demo-cliente.md`](guia-demo-cliente.md) | Secuencia de comandos **del lado cliente** para la presentación: DNS, descubrimiento, `getent`, Kerberos, SMB, DHCP + equivalencias Windows y troubleshooting. |
| [`latex/escaneo-vulnerabilidades/`](latex/escaneo-vulnerabilidades/) | **Informe Académico en LaTeX**: Detección y vigilancia de vulnerabilidades, evidencias, mitigación y plataforma de firma digital (57 págs, `main.pdf`). |

## Fuera de `docs/` (código y contexto)

| Ubicación | Contenido |
| --- | --- |
| [`../AGENTS.md`](../AGENTS.md) | Contexto resumido para agentes de IA (para entender el proyecto rápido). |
| [`../dc/`](../dc/) | Samba AD DC (nativo): provision, `shares.conf`, `krb5`, usuarios/grupos, password policy. |
| [`../server/`](../server/) | Config del host: firewall, ssh, chrony, deploy. |
| [`../services/`](../services/) | Servicios en contenedores (heredados del lab). |
| [`../clients/`](../clients/) | Guías para unir clientes Linux/Windows al dominio. |

## Próximos documentos a crear (cuando se avance)

- `docs/red.md` — plan IP detallado y reservas DHCP.
- `docs/seguridad.md` — política firewall/TLS/contraseñas.
- `docs/backup-dr.md` — esquema de respaldos y plan de restauración.
- `docs/decisiones.md` — registro de decisiones (ADCT, ADR).