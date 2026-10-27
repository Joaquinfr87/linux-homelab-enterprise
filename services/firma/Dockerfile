# ==============================================================================
# Etapa 1: Compilación del Frontend en Astro (Node.js 22 LTS requerido por Astro v7)
# ==============================================================================
FROM node:22-slim AS frontend-builder
WORKDIR /build

COPY frontend/package*.json ./
RUN npm install

COPY frontend/ ./
RUN npm run build

# ==============================================================================
# Etapa 2: Entorno de Ejecución en Python 3.11 para el Backend Criptográfico
# ==============================================================================
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5000 \
    HOST=0.0.0.0

WORKDIR /app

# Dependencias del sistema requeridas para criptografía, Pillow y fuentes
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libffi-dev \
    libssl-dev \
    libraqm0 \
    libimagequant0 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Instalar dependencias de Python
COPY backend/requirements.txt ./backend/
RUN pip install --no-cache-dir -r ./backend/requirements.txt

# Copiar código del backend
COPY backend/ ./backend/

# Copiar frontend compilado desde la etapa 1
COPY --from=frontend-builder /build/dist ./frontend/dist

# Directorios de datos y almacén temporal
RUN mkdir -p /app/backend/data /app/practice /tmp/opencode/web_cert_store

COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 5000

VOLUME ["/app/backend/data"]

ENTRYPOINT ["./entrypoint.sh"]
