# Publicar un servicio web desde las máquinas de admins (.51 / .52)

> Estructura para que **David** (192.168.0.51) y **Nicolás** (192.168.0.52)
> puedan alojar servicios web propios y publicarlos con un nombre del dominio,
> sin pisar el server ni cambiar la arquitectura.

## Idea general: el proxy es la única puerta

Todo nombre `*.sudoers.lan` se resuelve **siempre** hacia el proxy inverso
(Nginx en el server, `192.168.0.2`). El proxy enruta cada nombre hacia el
backend correspondiente, que puede ser un contenedor **o una máquina de la LAN**
como `.51` / `.52`.

```text
usuario en el navegador
        │  https://david.sudoers.lan   (HTTPS 443; el HTTP 80 redirige)
        ▼
   Nginx (192.168.0.2)  ── server_name ──►  http://192.168.0.51:8080  (Pc de David)
                                              http://192.168.0.52:8080  (Pc de Nicolás)

DNS:  david.sudoers.lan   A  192.168.0.2   (al proxy, NO a la máquina)
      nicolas.sudoers.lan A  192.168.0.2
```

## ¿Importa el puerto?

**Para el cliente, no.** Afuera solo se ve el puerto web estándar (**443** con
TLS; el HTTP 80 redirige solo). Nadie escribe `:8080` ni nada raro: el navegador
entra a `https://david.sudoers.lan` y listo.

**Para el backend (la máquina del admin), el puerto sí debe ser conocido.** En
este caso se definió **8080 en ambas máquinas** como puerto fijo para el
servicio web de David y Nicolás. El proxy "alcanza" la máquina por la LAN plana,
así que ese 8080 puede cambiarse si el dueño lo necesita — solo hay que
actualizar el upstream en `nginx.conf` y el registro de abajo. Lo que importa es
que **el puerto elegido quede registrado y no colisione** entre servicios de la
misma máquina.

No hay NAT, ni apertura de puertos en el router, ni reenvío: la red es única
`192.168.0.0/24` y el server llega directo a `.51`/`.52`.

## Roles

| Quién | Qué hace |
| --- | --- |
| **David / Nicolás** (dueño del servicio) | Corren el servicio web **en su máquina** y avisan *qué nombre quieren + a qué IP/puerto queda*. |
| **joaquin** (publicador, admin del server) | Crea el registro DNS, agrega el `server {}` en Nginx, recarga y avisa que está online. |

## Paso a paso — dueño del servicio (David / Nicolás)

1. Correr el servicio en su máquina escuchando en **todas las interfaces**
   (`0.0.0.0:8080`), no solo `127.0.0.1` — si no, el server no puede
   alcanzarlo. (Ej.: `flask run --host 0.0.0.0 -p 8080`, `nginx` normal, etc.)
2. Si la máquina tiene firewall local (nftables/ufw), permitir el puerto
   **8080** desde `192.168.0.2` (el server).
3. El servicio queda **disponible solo mientras la máquina esté encendida**.
4. Si cambia el puerto, avisar al publicador para ajustar el upstream.

## Paso a paso — publicador (joaquin)

1. **DNS** — crear los A records hacia el **proxy** (no hacia la máquina).
   En el DC, con ticket de administrador (idempotente):
   ```bash
   sudo kinit administrator        # pide el password una sola vez
   sudo bash dc/dns-records.sh
   ```
   o a mano:
   ```bash
   samba-tool dns add dc1.sudoers.lan sudoers.lan david A 192.168.0.2 -U administrator
   samba-tool dns add dc1.sudoers.lan sudoers.lan nicolas A 192.168.0.2 -U administrator
   ```
   (dentro del DC, sin TLS: `samba-tool dns add 127.0.0.1 ...`)
2. **Nginx** — los `server {}` de `david.sudoers.lan` y `nicolas.sudoers.lan`
   ya están en `services/web/nginx.conf` (sección 5b, HTTPS): apuntan a
   `http://192.168.0.51:8080` y `http://192.168.0.52:8080` respectivamente.
   Si cambia el puerto, actualizar SOLO el `set $X_upstream`.
3. **Recargar**:
   ```bash
   docker compose up -d --build web
   ```
4. **Verificar** (si la CA interna no está instalada, usar `curl -k`):
   ```bash
   dig david.sudoers.lan            # → A 192.168.0.2
   curl -sk https://david.sudoers.lan   # → responde el servicio de la máquina de David
   curl -sk https://nicolas.sudoers.lan # → responde el de Nicolás
   ```

## Convención de nombres

- **Un nombre por admin, la raíz de su máquina**: `david.sudoers.lan` (Pc de
  David) y `nicolas.sudoers.lan` (Pc de Nicolás). Lo publica su servicio web del
  puerto 8080.
- Si más adelante un admin necesita más de un servicio, se agregan subnombres:
  `david.gitea.sudoers.lan`, `david.phpmyadmin.sudoers.lan`, etc., siempre con
  su backend en `192.168.0.51` y el puerto que corresponda.
- Solo `[a-z0-9-]`, sin mayúsculas ni acentos.

## Registro de servicios publicados (actualizar al agregar)

| Nombre | Backend | Puerto | Dueño | Estado |
| --- | --- | --- | --- | --- |
| `david.sudoers.lan` | `192.168.0.51` | 8080 | David | activo en nginx |
| `nicolas.sudoers.lan` | `192.168.0.52` | 8080 | Nicolás | activo en nginx |

> Los servicios alojados **en el propio server** no entran en esta tabla:
> su mapa vive en [`services/web/README.md`](../services/web/README.md)
> (`print`, `portainer`, `webmail`, `archivos`, portal). El webmail es
> `webmail.sudoers.lan` → contenedor `tso-webmail:80` y el gestor de
> archivos es `archivos.sudoers.lan` → contenedor `tso-files:80`.