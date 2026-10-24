# Actividad 8: Herramientas de Monitoreo para la Defensa (IDS / IPS)

Informe técnico académico para la asignatura **Seguridad Informática** (Universidad Privada Domingo Savio).

---

## Datos de la Entrega

* **Actividad:** A8. Informe: Herramientas de monitoreo para la defensa
* **Equipo:** Grupo 1 Sudoers
* **Integrantes:**
  * Joaquin Alessandro Felipez Rojas
  * Nicolas Sebastian Reguerin Meneses
  * David Willy Cruz Huanca
* **Docente:** Jose Abraham Mita Huanca
* **Fecha:** 24/10/2026 - 20:15
* **Puntaje:** 100 Puntos

---

## Contenido del Informe

1. **Conceptos Fundamentales (IDS vs IPS):**
   * Detección pasiva fuera de banda (*Out-of-band*) vs Prevención en línea (*In-line*).
   * Modos de inspección: basados en firmas vs basados en anomalías.
   * Gestión de riesgos: análisis de falsos positivos vs falsos negativos, impacto en latencia y filosofías de resiliencia (*Fail-Open* con directiva `bypass` vs *Fail-Close*).
2. **Propuesta y Análisis de Herramientas Open Source:**
   * Comparativa técnica profunda entre **Suricata 7** y **Snort 3** (modelo de hilos multithreading, aceleración de patrones con Intel Hyperscan, integración con el kernel Linux vía NFQUEUE/DAQ, decodificación de protocolos de Directorio Activo como SMB/Kerberos/LDAP, telemetría EVE JSON).
   * Referencia metodológica a **Wireshark** como analizador forense interactivo.
   * Justificación técnica de la selección de Suricata como motor nativo para `dc1`.
3. **Propuesta Arquitectónica en Red Empresarial:**
   * Ubicación estratégica de sensores: Borde perimetral (tráfico Norte-Sur), Núcleo/Distribución interna (tráfico Este-Oeste en switches SPAN) y Servidor central (*Host-based Network IPS* H-NIPS en `dc1`).
   * Diagrama de red lógico y coherente modelado en TikZ.
   * Validación empírica de laboratorio con pruebas de alerta pasiva (IDS) y bloqueo proactivo en tiempo real (IPS).

---

## Compilación del Documento

Para generar el PDF final bajo normas APA y formato institucional:

```bash
cd docs/latex/a8
make
```

El resultado compilado es `main.pdf`.
