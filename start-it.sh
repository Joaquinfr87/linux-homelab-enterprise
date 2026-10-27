#!/bin/bash
# ==============================================================================
# start-it.sh — Wrapper para el orquestador de servicios IT (server/start-it.sh)
# ==============================================================================
# Uso:
#   sudo bash start-it.sh                    # Inicia y diagnostica toda la infraestructura
#   sudo bash start-it.sh --check            # Solo diagnóstico
#   sudo bash start-it.sh --force            # Fuerza reinicio de servicios
#   sudo bash start-it.sh --install-service  # Habilita inicio automático al encender el sistema
# ==============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$DIR/server/start-it.sh" "$@"
