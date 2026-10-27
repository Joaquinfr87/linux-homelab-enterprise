# Servicio: Firma Digital PAdES (UPDS)

Aplicación institucional de **firma digital de documentos PDF** basada en el estándar **PAdES (ISO 32000-2)** con emisión de identidades y Autoridad Certificadora Raíz X.509 v3.

## Características

- **Gestión de Identidades y Cuentas:** Registro de usuarios institucionales con clave protegida y emisión automática de certificados X.509 firmados por la CA Raíz UPDS (RSA 4096 bits).
- **Firma Cloud en 1 Clic:** Firma digital PAdES directa con sellos de tiempo y rúbricas visuales opcionales.
- **Validador Criptográfico de Firmas:** Verificación de integridad hash SHA-256, validez de certificados y cadena de confianza.
- **Auditoría:** Registro de documentos firmados en base de datos SQLite con claves privadas cifradas en reposo vía AES-256 (`.master_key`).
- **Descarga de Claves:** Exportación de paquetes `.p12` / `.pfx` y certificados `.crt`.

## Despliegue en Docker

El servicio corre dentro de la red interna `tso-net` y se expone a través del proxy inverso Nginx en `https://firma.sudoers.lan`.

### Variables de entorno

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `PORT` | `5000` | Puerto interno en el contenedor |
| `HOST` | `0.0.0.0` | Dirección de enlace |

### Volúmenes

- `firma_data`: Montado en `/app/backend/data`, persiste `app.db`, la clave y certificado de la CA institucional (`ca/`) y la clave simétrica maestra (`.master_key`).

### Verificación manual

```bash
# Estado de salud de la API
curl http://tso-firma:5000/api/health

# Acceso web desde el navegador
https://firma.sudoers.lan
```
