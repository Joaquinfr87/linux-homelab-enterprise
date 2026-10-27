#!/usr/bin/env bash
cd "$(dirname "$0")/.."
./backend/start_backend.sh
sleep 1
cd frontend && npm run dev
