# Informe LaTeX (normas APA · tipografía Arial · papel A4) — Actividad 8

Informe de la Actividad 8 (**Configuración del DNS del dominio con Samba AD
DC y Servidor WEB/Proxy inverso con Nginx en Linux con Debian**). Solo incluye
el **formato** (carátula, texto y portada); el contenido se agrega a medida
que se redacta.

```
latex/a8/
├── main.tex                  # Integra todo: formato + portada + capítulos + anexos. Datos de portada aquí.
├── Makefile                  # Compila el informe con un solo comando (make).
├── guia-capturas.md          # Lista de capturas de pantalla a tomar (una por figura del informe).
├── formato/                  # FORMATO: todo lo que define la apariencia.
│   ├── preambulo.sty         # Paquetes, configuración APA + A4 y carátulas de capítulo.
│   ├── portada.tex           # Portada estilo APA (los datos se definen en main.tex).
│   └── referencias.bib       # Fuentes bibliográficas en BibTeX (agregar las citadas en el texto).
├── contenido/                # CONTENIDO: un archivo por sección.
│   ├── 01-introduccion.tex   # Introducción (capítulo I).
│   ├── 02-objetivos.tex      # Objetivos (capítulo II).
│   ├── 03-alcance.tex        # Alcance y límites (capítulo II).
│   ├── 04-desarrollo.tex     # Desarrollo del trabajo (capítulo III).
│   └── 05-conclusiones.tex   # Conclusiones.
├── anexos/                   # Material complementario (tras las referencias).
│   └── anexo-a.tex           # Plantilla de anexo.
└── figuras/                  # Imágenes (logo institucional + capturas de pantalla).
    └── logo.png              # Logo institucional de la portada.
```

## Compilar

Con un solo comando (requiere `latexmk`):

```bash
make          # compila el PDF
make view     # compila y abre el PDF
```

Sin `latexmk` (compilación manual):

```bash
pdflatex -interaction=nonstopmode main.tex
bibtex main
pdflatex -interaction=nonstopmode main.tex
pdflatex -interaction=nonstopmode main.tex
```

## Datos de la portada

Se editan en la parte superior de `main.tex`:

- `\tituloDocumento`
- `\equipo`
- `\integrantes`
- `\docente`
- `\materia`
- `\fecha`
