#!/usr/bin/env bash
set -euo pipefail
base=https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main
cache="${XDG_CACHE_HOME:-$HOME/.cache}/jetson-uart"
mkdir -p "$cache"
command -v python3 >/dev/null || { echo 'Install Python 3 first.' >&2; exit 1; }
[ -x "$cache/venv/bin/python" ] || python3 -m venv "$cache/venv"
"$cache/venv/bin/python" -c 'import serial' 2>/dev/null || "$cache/venv/bin/python" -m pip install pyserial==3.5
curl -fsSL "$base/uart-logs.py" -o "$cache/uart-logs.py.tmp"
mv "$cache/uart-logs.py.tmp" "$cache/uart-logs.py"
exec "$cache/venv/bin/python" "$cache/uart-logs.py" "$@"
