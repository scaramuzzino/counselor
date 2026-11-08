#!/usr/bin/env bash
# Build del Counselor Companion in eseguibile onefile (macOS/Linux).
# Usa un venv isolato (non sporca il Python di sistema). Bundla certifi (fix cert macOS).
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv .build-venv
# shellcheck disable=SC1091
. .build-venv/bin/activate
pip install --quiet --upgrade pip pyinstaller certifi
pyinstaller --onefile --name counselor-companion --collect-data certifi --clean --noconfirm counselor_companion.py
deactivate
echo "OK → $(pwd)/dist/counselor-companion"
echo "Esegui:  ./dist/counselor-companion            (watch)"
echo "         ./dist/counselor-companion --once      (singolo ciclo)"
