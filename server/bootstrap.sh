#!/bin/bash
# ===================================================================
# bootstrap.sh — COMPATIBILIDAD
#
# El punto de entrada único del repo es install.sh (raíz). Este archivo
# se mantiene para que los comandos viejos sigan funcionando, pero ya no
# tiene lógica propia: delega todo en install.sh.
#
#   sudo bash server/bootstrap.sh --check
#   sudo bash server/bootstrap.sh --yes
# ===================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
printf 'AVISO: server/bootstrap.sh es un alias; ejecutando install.sh...\n' >&2
exec bash "$ROOT/install.sh" "$@"
