# ============================================================================
# Makefile — Compila el informe LaTeX (pdflatex + bibtex + 2 pasadas finales)
#   make        -> compila el PDF
#   make view   -> compila y abre el PDF
#   make clean  -> borra solo los archivos auxiliares (conserva el PDF)
#   make cleanall -> borra también el PDF
# ============================================================================

MAIN    = main
LATEXMK = latexmk
PDF     = main.pdf

.PHONY: all view clean cleanall

all:
	$(LATEXMK) -pdf $(MAIN).tex

view: all
	xdg-open $(PDF)

clean:
	$(LATEXMK) -c

cleanall:
	$(LATEXMK) -C

# Si latexmk no está disponible, usar la secuencia manual:
# manual:
# 	pdflatex -interaction=nonstopmode $(MAIN)
# 	bibtex $(MAIN)
# 	pdflatex -interaction=nonstopmode $(MAIN)
# 	pdflatex -interaction=nonstopmode $(MAIN)