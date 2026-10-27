#!/bin/bash
set -euo pipefail

mkdir -p /app/backend/data /tmp/opencode/web_cert_store /app/practice
chmod 700 /app/backend/data 2>/dev/null || true

echo "==> Iniciando Servicio de Firma Digital PAdES (UPDS) en ${HOST:-0.0.0.0}:${PORT:-5000}..."
cd /app/backend

if command -v gunicorn >/dev/null 2>&1; then
    exec gunicorn --bind "${HOST:-0.0.0.0}:${PORT:-5000}" --workers 2 --threads 4 --timeout 120 main:app
else
    exec python3 main.py
fi
