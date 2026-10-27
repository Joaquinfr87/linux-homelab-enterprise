# Guía de Uso y Administración de Servicios — Infraestructura IT

> **Dominio:** `SUDOERS.LAN`  
> **Servidor Principal (dc1):** `192.168.0.2`  
> **Servidor de Monitoreo (zabbix):** `192.168.0.3`  
> **Puerta de Enlace (Router):** `192.168.0.1`  
> **Subred Única:** `192.168.0.0/24`

---

## 1. Mapa General de Servicios y Accesos

| Servicio | URL / Dirección | Credenciales / Acceso | Tipo |
|---|---|---|---|
| **Portal Intranet** | `https://dc1.sudoers.lan` | Acceso público en la LAN | Web HTTPS |
| **Páginas del Equipo** | `https://<admin>.sudoers.lan` | `joaquin`, `david`, `nicolas` | Web HTTPS |
| **Webmail (Roundcube)** | `https://webmail.sudoers.lan` | Usuario AD / Correo (`joaquin`, `david`, etc.) | Web HTTPS |
| **Archivos Web (FileBrowser)** | `https://archivos.sudoers.lan` | Usuario AD (`joaquin`, `david`) o admin de archivos | Web HTTPS |
| **Impresión (CUPS)** | `https://print.sudoers.lan` (o `:1631`) | `admin` / Password CUPS de `.env` | Web HTTPS |
| **Monitoreo Grafana** | `https://grafana.sudoers.lan` | `admin` / Password Grafana de `.env` | Web HTTPS |
| **Monitoreo Zabbix** | `http://zabbix.sudoers.lan` | `Admin` / `zabbix` (Server físico `192.168.0.3`) | Web HTTP |
| **Portainer (Docker UI)** | `https://portainer.sudoers.lan:9443` | Cuenta admin configurada al primer ingreso | Web HTTPS |
| **Active Directory (Kerberos/LDAP)** | `dc1.sudoers.lan` (puertos 88, 389, 636) | `administrator` o usuarios del dominio | Nativo dc1 |
| **Carpetas Compartidas SMB** | `\\dc1.sudoers.lan\departamentos` | Usuario y contraseña del dominio AD | Nativo dc1 |
| **WiFi WPA2-Enterprise** | SSID: `sudoers` (puerto 1812/udp) | Usuario y contraseña del dominio AD (802.1X PEAP) | FreeRADIUS dc1 |
| **Seguridad de Red (IDS / IPS)** | Host `dc1` (CLI / Logs) | Control mediante `server/suricata/ips-toggle.sh` | Suricata 7 dc1 |
| **Métricas Internas (Prometheus)** | `http://127.0.0.1:9090` | Vía túnel SSH: `ssh -L 9090:127.0.0.1:9090 joaquin@192.168.0.2` | Interno |

---

## 2. Requisitos Previos en los Clientes (PC / Laptops)

### 2.1 Configuración de DNS
Para acceder mediante los nombres de dominio (`*.sudoers.lan`), los clientes deben tener como servidor DNS primario la IP de **dc1**:
* **Servidor DNS:** `192.168.0.2`
* **Dominio de búsqueda:** `sudoers.lan`
*(Si el cliente obtiene IP por DHCP desde Kea, esta configuración se asigna automáticamente).*

### 2.2 Instalación del Certificado de la CA Interna (HTTPS sin Advertencias)
El portal y los servicios web utilizan certificados emitidos por la Autoridad Certificadora interna de la organización. Para navegar con candado verde sin alertas:
1. Copiar el archivo del certificado raíz ubicado en el servidor:
   ```text
   services/web/tls/ca.crt
   ```
2. **En Windows:**
   - Doble clic en `ca.crt` → *Instalar certificado*.
   - Seleccionar *Equipo local* → *Colocar todos los certificados en el siguiente almacén*.
   - Elegir: **Entidades de certificación raíz de confianza** → Finalizar.
3. **En Linux (Debian / Ubuntu):**
   ```bash
   sudo cp ca.crt /usr/local/share/ca-certificates/sudoers-ca.crt
   sudo update-ca-certificates
   ```
4. **En Navegadores (Firefox / Chrome):**
   - Configuración → *Privacidad y Seguridad* → *Certificados* → *Ver certificados*.
   - Pestaña *Autoridades* → *Importar* → Seleccionar `ca.crt` y marcar *"Confiar en esta CA para identificar sitios web"*.

---

## 3. Guía de Uso Paso a Paso por Servicio

### 3.1 Portal Intranet y Páginas del Equipo
* **Acceso:** Navegar a [https://dc1.sudoers.lan](https://dc1.sudoers.lan).
* **Funcionalidad:** Portal central corporativo ("Banco Sudoers") con accesos directos a todos los sistemas internos, información de estado de la red y fichas del equipo administrador:
  * [https://joaquin.sudoers.lan](https://joaquin.sudoers.lan)
  * [https://david.sudoers.lan](https://david.sudoers.lan)
  * [https://nicolas.sudoers.lan](https://nicolas.sudoers.lan)

---

### 3.2 Identidad y Active Directory (Samba 4 AD DC)

Los usuarios creados en el dominio (`joaquin`, `david`, `nicolas`, `grupo2` .. `grupo9`) se gestionan centralizadamente.

#### Autenticación Kerberos desde Linux:
```bash
# Solicitar un ticket Kerberos
kinit joaquin@SUDOERS.LAN
# Ingresar contraseña (inicial: CambiarMe!2026)

# Listar tickets activos en memoria
klist
```

#### Acceso a Carpetas Compartidas (SMB / CIFS):
* **Desde Windows:**
  - Abrir el Explorador de archivos (`Win + E`).
  - En la barra de dirección escribir: `\\dc1.sudoers.lan\departamentos` o `\\192.168.0.2\departamentos`.
  - Introducir credenciales de dominio: `SUDOERS\joaquin` y su contraseña.
* **Desde Linux (Terminal o Gestor de Archivos):**
  - Conectar mediante `smbclient`:
    ```bash
    smbclient //dc1.sudoers.lan/departamentos -U joaquin
    ```
  - En Nautilus / Dolphin: `smb://dc1.sudoers.lan/departamentos`.

#### Gestión de Usuarios en el Servidor (dc1):
```bash
# Listar usuarios del dominio
sudo samba-tool user list

# Cambiar la contraseña de un usuario
sudo samba-tool user setpassword joaquin

# Crear un usuario nuevo
sudo samba-tool user create nuevo_usuario 'ClaveSegura2026!'
```

---

### 3.3 Correo Electrónico y Webmail (Roundcube)

* **Acceso Webmail:** [https://webmail.sudoers.lan](https://webmail.sudoers.lan)
* **Inicio de Sesión:**
  * **Usuario:** Nombre de cuenta (ej. `joaquin` o `david`).
  * **Contraseña:** Contraseña configurada en `MAIL_USERS` en `.env`.
* **Configuración en Clientes Externos (Thunderbird, Outlook, Móvil):**
  * **Servidor IMAP (Entrante):** `mail.sudoers.lan` | Puerto `993` (SSL/TLS) o `143` (STARTTLS).
  * **Servidor SMTP (Saliente):** `mail.sudoers.lan` | Puerto `587` (STARTTLS) con autenticación.
  * **Nombre de usuario:** `usuario` (sin @sudoers.lan).

---

### 3.4 Gestor Web de Archivos (FileBrowser)

Permite gestionar los shares de red directamente desde un navegador web sin necesidad de cliente SMB.

* **Acceso:** [https://archivos.sudoers.lan](https://archivos.sudoers.lan)
* **Inicio de Sesión:**
  * Usuario administrador: `admin` (clave en `.env` -> `FILES_ADMIN_PASS`).
  * Usuarios estándar: `joaquin`, `david` (claves configuradas en `FILES_USERS`).
* **Características:**
  * Permite subir, descargar, previsualizar documentos y editar archivos de texto.
  * Los archivos se guardan directamente en `/srv/samba/departamentos` respetando permisos y grupos del dominio para que también sean visibles por SMB.

---

### 3.5 Servidor de Impresión (CUPS)

* **Acceso Web:** [https://print.sudoers.lan](https://print.sudoers.lan) o `https://192.168.0.2:1631`
* **Administración:** Usuario `admin` con la contraseña `CUPS_ADMIN_PASS` de `.env`.
* **Impresión en Clientes:**
  * **Impresora Virtual PDF:** Los trabajos enviados a la impresora `PDF-Virtual` se procesan y exportan como archivos PDF dentro del volumen de salida del servidor.
  * **Agregar impresora en Windows / Linux:**
    - URL de la impresora: `http://192.168.0.2:1631/printers/PDF-Virtual` o `ipp://print.sudoers.lan:1631/printers/PDF-Virtual`.

---

### 3.6 Conexión a la Red WiFi Empresarial (WPA2-Enterprise 802.1X)

La red inalámbrica corporativa no utiliza una contraseña compartida fija (WPA-Personal), sino que valida la identidad de cada usuario contra el Directorio Activo mediante FreeRADIUS.

* **Nombre de Red (SSID):** `sudoers`
* **Seguridad:** WPA/WPA2-Enterprise (802.1X EAP)
* **Parámetros de Conexión en Dispositivos:**
  * **Método EAP:** `PEAP`
  * **Autenticación Fase 2 / Interna:** `MSCHAPv2`
  * **Certificado CA:** *"No validar"* (o seleccionar el certificado `ca.crt` importado).
  * **Identidad / Usuario:** Tu usuario de Active Directory (ej. `joaquin`).
  * **Contraseña:** Tu contraseña del dominio.
  * **Identidad Anónima:** *(Dejar en blanco)*.

---

### 3.7 Monitoreo y Métricas (Zabbix y Grafana)

#### Monitoreo con Zabbix:
* **Acceso:** [http://zabbix.sudoers.lan](http://zabbix.sudoers.lan) (o `http://192.168.0.3`)
* **Login por defecto:** `Admin` / `zabbix` *(cambiar en producción)*.
* **Uso:** Supervisión de estado de hosts, agentes Zabbix pasivos en puerto `10050`, disponibilidad de puertos y alarmas de infraestructura.

#### Monitoreo con Grafana:
* **Acceso:** [https://grafana.sudoers.lan](https://grafana.sudoers.lan)
* **Login:** `admin` / Password en `GRAFANA_ADMIN_PASSWORD` de `.env`.
* **Uso:** Cuadros de mando con métricas de consumo de CPU, RAM, tráfico de red, salud de contenedores Docker y sondas de disponibilidad.

---

### 3.8 Sistema de Detección y Prevención de Intrusos (IDS / IPS Suricata)

Suricata se ejecuta de forma nativa en `dc1` protegiendo los servicios corporativos contra ataques internos y externos.

#### Comprobar Estado y Últimas Alertas:
```bash
bash server/suricata/ips-toggle.sh --status
```
* Muestra si Suricata está activo, si opera en modo IDS o IPS, si la regla `queue num 0` está inyectada en `nftables` y las últimas alertas generadas en `fast.log`.

#### Alternar Modos de Seguridad en Caliente:
```bash
# Cambiar a MODO IPS (Bloqueo y descarte activo en tiempo real):
sudo bash server/suricata/ips-toggle.sh --ips

# Cambiar a MODO IDS (Monitoreo pasivo, solo alertas sin interrupción):
sudo bash server/suricata/ips-toggle.sh --ids
```

#### Ejecutar Batería de Pruebas de Laboratorio:
```bash
sudo bash server/suricata/test-ids-ips.sh
```
* **Prueba 1 (Detección IDS):** Envía una sonda benigna y confirma el registro de la firma en `/var/log/suricata/fast.log`.
* **Prueba 2 (Prevención IPS):** Envía una carga maliciosa simulada (`MALICIOUS_SIMULATION_ATTACK`). Si el modo IPS está activo, la conexión es **abortada y descartada** por el kernel Netfilter antes de ser procesada por Nginx.

#### Monitoreo de Alertas en Vivo:
```bash
# Registro rápido en texto:
tail -f /var/log/suricata/fast.log

# Registro estructurado JSON (EVE) filtrando campos relevantes:
tail -f /var/log/suricata/eve.json | jq -r '[.timestamp, .event_type, .alert.signature, .src_ip, .dest_port] | @tsv'
```

#### Agregar Nuevas Reglas Personalizadas:
1. Editar el archivo de reglas locales:
   ```bash
   sudo nano server/suricata/rules/homelab.rules
   ```
2. Añadir la regla con acción `alert` (detección) o `drop` (prevención en modo IPS), utilizando un SID superior a `9000000`.
3. Sincronizar y recargar sin reiniciar el servidor:
   ```bash
   sudo bash server/deploy.sh
   ```

---

### 3.9 Gestión de Docker con Portainer

* **Acceso:** [https://portainer.sudoers.lan:9443](https://portainer.sudoers.lan:9443) (o `https://192.168.0.2:9443`)
* **Uso:** Panel web visual para inspeccionar los contenedores (`tso-web`, `tso-mail`, `tso-dhcp`, `tso-files`, etc.), consultar logs en vivo, reiniciar servicios y verificar el consumo de CPU/memoria.

---

### 3.10 Copias de Seguridad y Restauración (Restic)

El servidor cuenta con un sistema de respaldos nativo con snapshots cifrados y deduplicados:

```bash
# Ejecutar un respaldo completo inmediato de datos y configuraciones:
sudo bash server/backup.sh

# Listar los puntos de restauración (snapshots) disponibles:
sudo restic -r /srv/backup/restic-repo snapshots

# Restaurar datos de un servicio específico:
sudo bash server/restore.sh
```

---

## 4. Comandos de Referencia Rápida para el Administrador (Cheat-Sheet)

```bash
# --- ESTADO GENERAL ---
sudo bash install.sh --check                     # Diagnóstico integral de la infraestructura
sudo docker compose ps                           # Estado de los contenedores Docker
sudo systemctl status samba-ad-dc suricata       # Estado de servicios nativos clave

# --- GESTIÓN DE SERVICIOS DOCKER ---
sudo docker compose restart <servicio>           # Reiniciar un contenedor puntual (ej. web, mail)
sudo docker compose logs -f <servicio>           # Ver logs en vivo de un contenedor

# --- FIREWALL Y RED ---
sudo nft list ruleset                            # Ver reglas activas del firewall nftables
sudo ss -tuln                                    # Comprobar puertos abiertos y a la escucha
ip -brief addr                                   # Ver interfaces e IPs asignadas

# --- SEGURIDAD IDS / IPS ---
sudo bash server/suricata/ips-toggle.sh --status # Consultar modo de Suricata
sudo bash server/suricata/test-ids-ips.sh        # Ejecutar pruebas de seguridad
tail -n 20 /var/log/suricata/fast.log            # Ver últimas alertas del IDS/IPS
```
