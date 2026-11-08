#!/usr/bin/env bash
# Firma Authenticode di un .exe DA LINUX (usabile in CI) con osslsigncode — non serve Windows.
#
# Variabili richieste (secret CI protetti):
#   WIN_PFX_B64   certificato code-signing .pfx/.p12 codificato in base64
#   WIN_PFX_PASS  password del .pfx
# Se WIN_PFX_B64 non e' impostata, lo script ESCE 0 senza firmare (binario non firmato):
# cosi' la pipeline continua a funzionare finche' il certificato non c'e'.
#
# Uso: sign_windows.sh <percorso/al/file.exe>
set -euo pipefail
EXE="${1:?uso: sign_windows.sh <file.exe>}"

if [ -z "${WIN_PFX_B64:-}" ]; then
  echo "ℹ WIN_PFX_B64 non impostata → salto la firma Windows (binario NON firmato)."
  exit 0
fi

command -v osslsigncode >/dev/null || { echo "✗ osslsigncode non installato"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "$WIN_PFX_B64" | base64 -d > "$TMP/cert.pfx"

# -ts: timestamp RFC3161 → la firma resta valida anche dopo la scadenza del certificato.
osslsigncode sign \
  -pkcs12 "$TMP/cert.pfx" -pass "${WIN_PFX_PASS:-}" \
  -h sha256 \
  -n "Counselor Companion" \
  -i "https://wow.jeevesaicloud.com" \
  -ts "http://timestamp.sectigo.com" \
  -in "$EXE" -out "$TMP/signed.exe"

mv "$TMP/signed.exe" "$EXE"
echo "✓ firmato: $EXE"
osslsigncode verify "$EXE" 2>/dev/null | sed -n '1,14p' || true
