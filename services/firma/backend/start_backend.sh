#!/usr/bin/env bash
cd "$(dirname "$0")"
export PYTHONPATH="$HOME/pylibs/usr/lib/python3/dist-packages"
export LD_LIBRARY_PATH="$HOME/pylibs/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export HOST="0.0.0.0"
export PORT="5000"
setsid python3 main.py >/tmp/opencode/main.log 2>&1 </dev/null &
PID=$!
disown $PID 2>/dev/null || true
echo "PID: $PID"
