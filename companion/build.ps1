# Build del Counselor Companion in eseguibile onefile (Windows).
# PyInstaller NON cross-compila: questo va eseguito SU WINDOWS per ottenere il .exe.
# Richiede Python 3.9+ installato (python.org).
Set-Location $PSScriptRoot
python -m venv .build-venv
. .\.build-venv\Scripts\Activate.ps1
pip install --quiet --upgrade pip pyinstaller certifi
# --windowed: nessuna finestra console (il servizio deve essere INVISIBILE).
# Il feedback d'installazione usa una MessageBox; il drain logga su file.
pyinstaller --onefile --windowed --name counselor-companion --collect-data certifi --clean --noconfirm counselor_companion.py
deactivate
Write-Host "OK -> $PSScriptRoot\dist\counselor-companion.exe"
