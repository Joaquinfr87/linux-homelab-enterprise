# Guía de capturas de pantalla — Actividad 8

Todas las capturas se guardan en `docs/latex/a8/figuras/`. Si una captura
falta, el PDF muestra un recuadro "CAPTURA PENDIENTE" con el nombre esperado
del archivo; se compila igualmente.

Los comandos corren en el servidor **Debian 12** (`dc1.sudoers.lan`,
`192.168.0.2`) salvo que se indique **CLIENTE** (equipo en
`192.168.0.100–199`, con DNS `192.168.0.2` entregado por DHCP).

---

## 1. Zona y rol del DC en el DNS (smb.conf)

**Archivo:** `captura-smb-dns.png`
**Comando (server, en el repo):**
```bash
grep -E 'server role|dns|realm' /etc/samba/smb.conf
```
**Qué mostrar:** `server role = active directory domain controller`,
`realm = SUDOERS.LAN` y `dns forwarder = 192.168.0.1`.

---

## 2. Zona DNS completa consultada con samba-tool

**Archivo:** `captura-zona-dns.png`
**Comando (server):**
```bash
sudo kinit administrator
samba-tool dns query dc1.sudoers.lan sudoers.lan @ ALL -k yes
```
**Qué mostrar:** los registros A de la zona (`dc1`, `web`, `www`, `print`,
`portainer`, `joaquin`, `david`, `nicolas`) apuntando a `192.168.0.2`.

---

## 3. Resolución de `web.sudoers.lan`

**Archivo:** `captura-dig-web.png`
**Comando (server):**
```bash
dig web.sudoers.lan
```
**Qué mostrar:** `web.sudoers.lan. 900 IN A 192.168.0.2` en la ANSWER SECTION.

---

## 4. Registros idempotentes de los administradores

**Archivo:** `captura-dns-records.png`
**Comando (server, en el repo):**
```bash
sudo kinit administrator
sudo bash dc/dns-records.sh
```
**Qué mostrar:** la salida del script con `ok david.sudoers.lan → 192.168.0.2`
y `ok nicolas.sudoers.lan → 192.168.0.2`.

---

## 5. Registros SRV de descubrimiento

**Archivo:** `captura-dig-srv.png`
**Comando (server):**
```bash
dig _ldap._tcp.dc._msdcs.sudoers.lan SRV
```
**Qué mostrar:** el SRV `_ldap._tcp.dc._msdcs... 0 100 389 dc1.sudoers.lan.`

---

## 6. Resolución externa (forwarder)

**Archivo:** `captura-dig-externo.png`
**Comando (server):**
```bash
dig google.com @192.168.0.2 +short
```
**Qué mostrar:** una dirección IP pública (ej. `142.250.78.78`) resuelta a
través del forwarder `192.168.0.1`.

---

## 7. Servicio `web` en el docker-compose

**Archivo:** `captura-compose-web.png`
**Comando (server, en el repo):**
```bash
grep -A8 'web:' docker-compose.yml
```
**Qué mostrar:** el bloque del servicio web con los puertos 80/443, los
volúmenes `public` y `tls`, y `restart: always`.

---

## 8. Virtual host del portal en Nginx

**Archivo:** `captura-nginx-conf.png`
**Comando (server, en el repo):**
```bash
grep -B2 -A12 'server_name sudoers.lan' services/web/nginx.conf
```
**Qué mostrar:** el bloque HTTP que redirige con `return 301` y el bloque
HTTPS (443 ssl) del portal.

---

## 9. Generación de la CA interna y el wildcard

**Archivo:** `captura-tls-gen.png`
**Comando (server, en el repo):**
```bash
sudo bash services/web/tls-gen.sh
docker compose up -d --build web
```
**Qué mostrar:** el resumen final con `CA: ca.crt` y `Server: server.crt /
server.key  (*.sudoers.lan, 825 días)`.

---

## 10. Acceso HTTPS al portal

**Archivo:** `captura-curl-web.png`
**Comando (server):**
```bash
curl -skI https://web.sudoers.lan
```
**Qué mostrar:** `HTTP/1.1 200 OK` y `Server: nginx`.

---

## 11. Subdominio del administrador (proxy → máquina)

**Archivo:** `captura-curl-david.png`
**Comando (server):**
```bash
dig david.sudoers.lan +short
curl -sk https://david.sudoers.lan
```
**Qué mostrar:** `192.168.0.2` (el proxy) y el contenido del servicio web de
la máquina de David (`192.168.0.51`).

---

## 12. Resolución desde un cliente de la red

**Archivo:** `captura-cliente-dig.png`
**Comando (CLIENTE):**
```bash
dig web.sudoers.lan
```
**Qué mostrar:** `192.168.0.2` resuelto por el DNS entregado por DHCP.

---

## 13. Portal en el navegador del cliente (HTTPS)

**Archivo:** `captura-cliente-web.png`
**Comando (CLIENTE):** abrir `https://web.sudoers.lan` en el navegador.
**Qué mostrar:** el portal cargado por HTTP**S** con el candado de confianza
(CA interna instalada).