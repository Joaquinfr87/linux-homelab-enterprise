# Guía de Auditoría de Vulnerabilidades y Detección con IDS (Modo Portable)

Esta guía detalla cómo realizar y demostrar una auditoría de seguridad y detección de intrusos en la rama `pfinal`. 

En esta modalidad **no se requiere Active Directory ni servidor DNS**: el servidor es 100% portable y atiende directamente por dirección IP en cualquier red (WiFi, laboratorio universitario o red cableada).

---

## 1. Puesta en marcha rápida (Cero dependencias)

Para levantar todos los servicios en cualquier máquina o red:

```bash
# 1. Asegurarse de estar en la rama pfinal
git checkout pfinal

# 2. (Opcional) Copiar .env si deseas personalizar credenciales
cp -n .env.example .env

# 3. Levantar los contenedores
docker compose up -d
```

> **Nota sobre DHCP (Kea):** En esta rama, el servicio DHCP está asignado al perfil `dhcp`, por lo que **no se iniciará automáticamente**, evitando generar conflictos o interferir con la red donde conectes la máquina (el router del aula asignará la IP normalmente).

Para averiguar la IP asignada en Linux:
```bash
ip -brief address show
```
*(Por ejemplo: `192.168.1.45` o `192.168.0.2`).*

---

## 2. Mapa de Puertos y Servicios Expuestos

Al acceder a `http://<IP_DEL_SERVIDOR>/`, el portal web detectará automáticamente la IP del navegador y ajustará todos los accesos directos:

| Puerto | Protocolo | Servicio | Rol en la Demostración |
|---|---|---|---|
| **TCP 80** | HTTP | Nginx Portal | Punto de entrada web corporativo y matriz de seguridad. |
| **TCP 443** | HTTPS | Nginx TLS | Evaluación de cifrados SSL/TLS y suites criptográficas. |
| **TCP 22** | SSH | OpenSSH (Host) | Auditoría de contraseñas, versiones de SSH y hardening del sistema. |
| **TCP 25 / 143** | SMTP / IMAP | Postfix / Dovecot | Pruebas de Open Relay, STARTTLS y banners de correo. |
| **TCP 1631** | HTTP | CUPS Print | Servicio de impresión en red e impresora virtual PDF. |
| **TCP 3000** | HTTP | Grafana | Dashboards y tableros de métricas del servidor. |
| **TCP 5432** | PostgreSQL | PostgreSQL DB | Auditoría de autenticación y exposición de base de datos relacional. |
| **TCP 8080** | HTTP | Roundcube Webmail | Aplicación webmail (detección de CVEs en aplicaciones web PHP). |
| **TCP 8082** | HTTP | Filebrowser | Gestor web de archivos (prueba de Directory Traversal y autenticación). |
| **TCP 8085** | HTTP | Uyuni Way Web | Aplicación web en React + Vite (auditoría DAST con OWASP ZAP). |
| **TCP 8090 / HTTPS** | HTTP / HTTPS | Firma Digital PAdES | Plataforma de emisión X.509, firma avanzada ISO 32000-2 y validación semafórica. |
| **TCP 9443** | HTTPS | Portainer CE | Consola administrativa de orquestación de contenedores. |

---

## 3. Demostración de Escaneo con OpenVAS (Greenbone)

OpenVAS audita vulnerabilidades a nivel de red, sistema operativo y aplicaciones.

### A. Configurar el Escaneo en OpenVAS
1. Acceder a la interfaz de OpenVAS (ej. Greenbone en `http://localhost:9392` desde la PC del auditor).
2. Ir a **Configuration** → **Targets** → **New Target**:
   - **Name:** `Servidor-Auditoria`
   - **Hosts:** Ingresar la IP del servidor (ej. `192.168.1.45`).
   - **Port List:** Seleccionar `All IANA assigned TCP` o `All TCP and Nmap top 100 UDP`.
3. Ir a **Scans** → **Tasks** → **New Task**:
   - Asignar el Target creado.
   - **Scan Config:** `Full and Fast`.
4. Iniciar el escaneo (**Start Task**).

### B. Qué esperar en el Reporte de OpenVAS
- **Banners detectados:** Versión de OpenSSH, Postfix, Nginx y PostgreSQL.
- **Vulnerabilidades y Advertencias (CVEs / Misconfigurations):**
  - Advertencias sobre certificados autofirmados en puertos TLS (ej. 9443 y 443).
  - Verificación de cabeceras de seguridad HTTP faltantes en los servicios web (`X-Frame-Options`, `Content-Security-Policy`).
  - Información sobre versiones de imágenes y servicios conocidos.

---

## 4. Detección y Prevención en Tiempo Real con Suricata (IDS vs IPS)

El servidor cuenta con **Suricata 7** configurado para operar en dos modalidades según lo que quieras demostrar ante el docente:

### A. Alternar entre Modo IDS y Modo IPS
El script [server/suricata/ips-toggle.sh](file:///f:/tareas/seguridadInformatica1/linux-homelab-enterprise/server/suricata/ips-toggle.sh) permite alternar el comportamiento del servidor en caliente:

```bash
# 1. Poner Suricata en MODO IDS (Detección Pasiva con AF_PACKET)
# El escaneo o ataque se detecta y se genera la alerta, pero el tráfico NO se corta
sudo bash server/suricata/ips-toggle.sh --ids

# 2. Poner Suricata en MODO IPS (Prevención Activa en Línea con NFQUEUE + nftables)
# Cuando se detecta una firma con acción 'drop', el paquete se DESCARTA en el kernel en tiempo real
sudo bash server/suricata/ips-toggle.sh --ips

# 3. Ver estado actual (si está en modo IDS o IPS) y últimas alertas
bash server/suricata/ips-toggle.sh --status
```

### B. Monitoreo de Alertas durante el Escaneo
Mientras lanzás OpenVAS o Nmap contra el servidor:
```bash
# Ver alertas inmediatas de Suricata:
sudo tail -f /var/log/suricata/fast.log

# O analizar eventos estructurados JSON con jq:
sudo tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert") | {timestamp: .timestamp, src: .src_ip, alerta: .alert.signature, accion: .alert.action}'
```

### C. Firmas específicas añadidas en esta rama:
En [server/suricata/rules/homelab.rules](file:///f:/tareas/seguridadInformatica1/linux-homelab-enterprise/server/suricata/rules/homelab.rules) se configuraron reglas para:
- `[HOMELAB-IDS-ALERT] Escaneo de vulnerabilidades: OpenVAS / Greenbone detectado`
- `[HOMELAB-IDS-ALERT] Escaneo de vulnerabilidades: Nikto Web Scanner detectado`
- `[HOMELAB-IDS-ALERT] Escaneo de vulnerabilidades: Nmap NSE detectado`
- `[HOMELAB-IPS-DROP] Bloqueo en tiempo real: Inyeccion SQL interceptada y descartada`
- `[HOMELAB-IPS-DROP] Bloqueo en tiempo real: Directory Traversal interceptado y descartado`

### D. Batería de pruebas automatizadas
Para demostrar rápidamente que el IDS detecta y el IPS bloquea sin esperar a OpenVAS:
```bash
sudo bash server/suricata/test-ids-ips.sh
```

---

## 5. Otro Sistema de Prevención (Host IPS): Fail2ban

Si el docente pide **otro programa** además de Suricata para prevención de intrusiones, la opción complementaria por excelencia en Linux es **Fail2ban**:
- **Suricata:** Es un **NIDS / NIPS** (inspecciona paquetes y tráfico de red en bruto a nivel de capas 3, 4 y 7).
- **Fail2ban:** Es un **HIPS** (Host Intrusion Prevention System) que analiza bitácoras de autenticación y bloquea dinámicamente direcciones IP infractoras en el firewall `nftables`.

### Cómo instalarlo y probarlo en 2 pasos:
```bash
# 1. Instalar Fail2ban en el servidor Debian:
sudo apt install -y fail2ban

# 2. Habilitar la protección para SSH (puerto 22):
sudo systemctl enable --now fail2ban
```
Si alguien intenta 3 o 5 contraseñas erróneas por SSH, Fail2ban inserta una regla de bloqueo temporal (`drop`) en `nftables` y podés mostrar el bloqueo con:
```bash
sudo fail2ban-client status sshd
sudo nft list ruleset
```
---

## 6. Pruebas Complementarias y Ligeras

Si en el aula no se dispone de suficiente memoria RAM para levantar OpenVAS completo, podés utilizar estas herramientas complementarias equivalentes:

### 1. Nmap con Scripts de Vulnerabilidades (NSE)
Desde la máquina auditora:
```bash
# Escaneo de versiones y CVEs conocidos en todos los puertos abiertos
nmap -sV -p 22,25,80,143,1631,3000,5432,8080,8082,9443 --script vuln <IP_DEL_SERVIDOR>
```

### 2. Trivy (Auditoría de Contenedores y Supply Chain)
Permite mostrar el enfoque moderno DevSecOps directamente sobre los contenedores del proyecto:
```bash
# Escanear el archivo docker-compose en busca de malas configuraciones:
docker run --rm -v $(pwd):/work -w /work aquasec/trivy:latest config docker-compose.yml

# Escanear una imagen específica (ej. Postgres o Roundcube):
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest image roundcube/roundcubemail:1.7.4-apache
```

### 3. Nikto (Auditoría de Vulnerabilidades Web)
Escaneo de cabeceras, archivos sensibles y configuraciones inseguras en el servidor web:
```bash
nikto -h http://<IP_DEL_SERVIDOR>:80/
nikto -h http://<IP_DEL_SERVIDOR>:8080/
```

---

## 7. Resumen de la Demostración para la Exposición

1. **Mostrar la arquitectura:** Explicar cómo cada servicio corre aislado en Docker y expone su puerto de red.
2. **Abrir el portal web:** Navegar a `http://<IP_DEL_SERVIDOR>` para demostrar que todo se adapta dinámicamente a la IP asignada.
3. **Lanzar la auditoría:** Iniciar el escaneo con OpenVAS o Nmap `vuln`.
4. **Demostrar la defensa:** Mostrar la consola con `tail -f /var/log/suricata/fast.log` evidenciando cómo el IDS detecta el escaneo en vivo.
5. **Conclusión:** Explicar cómo la combinación de un escáner de vulnerabilidades (proactivo) y un IDS (reactivo/preventivo) conforma la postura de seguridad de la organización.
