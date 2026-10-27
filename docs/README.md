# Documentación — Infraestructura IT (Sudoers Enterprise)

Bienvenido al índice de documentación del proyecto. A continuación se listan las guías y especificaciones técnicas disponibles:

---

## 1. Guías de Operación y Arquitectura

* **[`arquitectura.md`](arquitectura.md)**:
  **Diseño Integral de la Infraestructura IT.** Visión general, principios de ingeniería, plan de direccionamiento IP/DNS/DHCP, Active Directory nativo con Samba 4, servicios contenerizados, esquemas de seguridad perimetral y plan de fases de implementación.

* **[`guia-uso-servicios.md`](guia-uso-servicios.md)**:
  **Guía Maestra de Uso de Servicios.** Explica paso a paso cómo utilizar cada servicio de la red: portal web, cuentas de Active Directory, carpetas compartidas SMB, webmail, gestor de archivos, impresión CUPS, conexión WiFi 802.1X, paneles de monitoreo (Zabbix y Grafana), y administración del IDS/IPS Suricata.

* **[`ids-ips.md`](ids-ips.md)**:
  **Diseño y Arquitectura de IDS / IPS (Actividad 8).** Fundamentación conceptual de Detección (IDS) vs Prevención (IPS), comparativa técnica detallada entre Suricata 7 y Snort 3, propuesta de ubicación en red empresarial y suite de pruebas de laboratorio.

* **[`publicar-servicios-admin.md`](publicar-servicios-admin.md)**:
  **Publicación de Servicios y Subdominios de Administradores.** Explicación de cómo funciona el DNS autoritativo del DC, los registros A hacia `192.168.0.2` y el proxy reverso Nginx para publicar sitios personales (`joaquin`, `david`, `nicolas`).

---

## 2. Guías para Clientes

* **[`../clients/wifi.md`](../clients/wifi.md)**:
  Configuración de conexión para clientes inalámbricos a la red WiFi empresarial `sudoers` mediante WPA2-Enterprise (802.1X PEAP / MSCHAPv2) contra el Active Directory.

---

## 3. Instalación e Infraestructura

* **[`../install.sh`](../install.sh)** / **[`../server/bootstrap.sh`](../server/bootstrap.sh)**:
  Instalador y verificador unificado del servidor `dc1`.
* **[`../server/suricata/`](../server/suricata/)**:
  Módulo nativo de Suricata para inspección pasiva (IDS) o bloqueo en línea (IPS).
* **[`../services/snort/`](../services/snort/)**:
  Módulo de laboratorio y referencia de Snort 3 para comparativas técnicas.

---

## 4. Documentos Académicos e Informes en LaTeX

Los informes académicos formales, reportes de auditoría de vulnerabilidades y fuentes en LaTeX (con sus PDFs compilados) se gestionan y versionan de forma dedicada en la **rama `docs`** del repositorio (`git checkout docs`), manteniendo la rama `main` limpia y enfocada en el código, servicios e infraestructura operativa.
