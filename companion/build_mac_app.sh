#!/usr/bin/env bash
# =============================================================================
# build_mac_app.sh — impacchetta il Counselor Companion per macOS in un .app
# bundle e poi in un .dmg pronto alla distribuzione (vero DOPPIO CLIC).
#
# PERCHE': PyInstaller produce un binario CLI (`counselor-companion-mac`). Se
# l'utente ci fa doppio clic, macOS apre il Terminale: brutto e confusionario.
# Un .app bundle con LSUIElement=1 parte senza finestre ne' icona nel Dock: il
# doppio clic lancia il companion, che al primo avvio si auto-installa come
# LaunchAgent (do_install) e poi gira invisibile a ogni login.
#
# COSA FA:
#   1. trova (o costruisce, se manca) il binario PyInstaller onefile;
#   2. crea `dist/Counselor Companion.app` con Info.plist corretto;
#   3. genera l'icona .icns da ../stemma.png (se possibile, best-effort);
#   4. firma ad-hoc il bundle (riduce i prompt Gatekeeper; opzionale);
#   5. impacchetta tutto in `dist/Counselor Companion.dmg` via hdiutil.
#
# PREREQUISITI:
#   - macOS (sips/iconutil/hdiutil/codesign fanno parte del sistema);
#   - il binario `dist/counselor-companion-mac` (o `dist/counselor-companion`),
#     altrimenti serve Python 3 + pyinstaller nel PATH per costruirlo al volo
#     (questo script riusa companion/build.sh via PyInstaller se il binario
#     non c'e').
#
# USO:
#   bash companion/build_mac_app.sh                 # usa il binario in dist/
#   bash companion/build_mac_app.sh /path/al/binario
#   APP_VERSION=1.2.0 bash companion/build_mac_app.sh
#
# NOTA FIRMA/NOTARIZZAZIONE: questo script fa solo una firma *ad-hoc* (senza
# certificato). Per eliminare l'avviso "sviluppatore non identificato" firma e
# notarizza l'.app con un Developer ID — vedi deploy/signing/SIGNING.md.
# =============================================================================
set -euo pipefail

# Lavora sempre dalla cartella companion/ (dove sta questo script).
cd "$(dirname "$0")"

# --- parametri -------------------------------------------------------------
APP_NAME="Counselor Companion"
BUNDLE_ID="com.jeeves.counselor-companion"     # == LABEL del LaunchAgent nel .py
APP_VERSION="${APP_VERSION:-1.0.0}"
DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
ICON_SRC="../stemma.png"                        # stemma della gilda (se presente)

# Nome dell'eseguibile DENTRO il bundle. Lo teniamo uguale al binario così il
# companion (che usa sys.executable) si comporta identico a quando lanciato a mano.
EXE_NAME="counselor-companion-mac"

# --- 1) individua (o costruisci) il binario PyInstaller --------------------
# Priorita': argomento esplicito > nome CI (mac) > nome di build.sh.
BIN=""
if [[ "${1:-}" != "" ]]; then
  BIN="$1"
elif [[ -f "${DIST_DIR}/counselor-companion-mac" ]]; then
  BIN="${DIST_DIR}/counselor-companion-mac"
elif [[ -f "${DIST_DIR}/counselor-companion" ]]; then
  BIN="${DIST_DIR}/counselor-companion"
fi

if [[ -z "${BIN}" || ! -f "${BIN}" ]]; then
  echo "[build_mac_app] binario non trovato in ${DIST_DIR}/ — lo costruisco con PyInstaller…"
  if ! command -v pyinstaller >/dev/null 2>&1; then
    # Niente pyinstaller globale: proviamo con build.sh (crea un venv isolato).
    if [[ -x "./build.sh" ]]; then
      bash ./build.sh
      BIN="${DIST_DIR}/counselor-companion"
    else
      echo "ERRORE: nessun binario in ${DIST_DIR}/ e pyinstaller non disponibile." >&2
      echo "        Lancia prima la build (companion/build.sh) o passa il binario come argomento." >&2
      exit 1
    fi
  else
    pyinstaller --onefile --name counselor-companion-mac --collect-data certifi \
      --clean --noconfirm counselor_companion.py
    BIN="${DIST_DIR}/counselor-companion-mac"
  fi
fi
echo "[build_mac_app] binario: ${BIN}"

# --- 2) scheletro del .app --------------------------------------------------
# Struttura standard: Contents/{MacOS,Resources}/ + Info.plist.
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN}" "${APP_DIR}/Contents/MacOS/${EXE_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${EXE_NAME}"

# --- 3) icona (best-effort) -------------------------------------------------
# Converte ../stemma.png in AppIcon.icns. Se qualcosa manca, procediamo senza
# icona (il bundle resta valido, solo con l'icona generica).
ICON_PLIST_KEY=""
if [[ -f "${ICON_SRC}" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  echo "[build_mac_app] genero l'icona da ${ICON_SRC}…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "${ICONSET}"
  # macOS vuole un set di dimensioni (normale + @2x). sips scala il PNG sorgente.
  for size in 16 32 64 128 256 512; do
    sips -z "${size}" "${size}"       "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}.png"       >/dev/null
    dbl=$(( size * 2 ))
    sips -z "${dbl}"  "${dbl}"         "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}@2x.png"    >/dev/null
  done
  if iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    ICON_PLIST_KEY=$'\n\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>'
  else
    echo "[build_mac_app] iconutil fallito — proseguo senza icona."
  fi
  rm -rf "$(dirname "${ICONSET}")"
else
  echo "[build_mac_app] icona non generata (stemma.png o sips/iconutil assenti) — proseguo senza."
fi

# --- 4) Info.plist ----------------------------------------------------------
# LSUIElement=1  -> app "agent": gira in background, nessuna icona nel Dock,
#                   nessuna finestra forzata. Perfetto per un servizio invisibile.
# CFBundleExecutable DEVE combaciare col file in Contents/MacOS/.
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleVersion</key>
	<string>${APP_VERSION}</string>
	<key>CFBundleShortVersionString</key>
	<string>${APP_VERSION}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>${EXE_NAME}</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.13</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>${ICON_PLIST_KEY}
</dict>
</plist>
PLIST

# --- 5) firma ad-hoc (opzionale, best-effort) -------------------------------
# Una firma ad-hoc (`codesign -s -`) non toglie l'avviso Gatekeeper ma rende il
# bundle "sigillato" e stabile. Se c'e' un Developer ID preferiscilo via SIGNING.md.
if command -v codesign >/dev/null 2>&1; then
  if codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null; then
    echo "[build_mac_app] firma ad-hoc applicata."
  else
    echo "[build_mac_app] firma ad-hoc non riuscita — proseguo (bundle comunque valido)."
  fi
fi

echo "[build_mac_app] creato: ${APP_DIR}"

# --- 6) .dmg per la distribuzione ------------------------------------------
# hdiutil crea un'immagine disco compressa (UDZO) col solo .app dentro.
# Stage in una cartella temporanea così il .dmg contiene esattamente l'.app.
rm -f "${DMG_PATH}"
STAGE="$(mktemp -d)"
cp -R "${APP_DIR}" "${STAGE}/"
# Comodo: scorciatoia ad /Applications per il classico drag-and-drop.
ln -s /Applications "${STAGE}/Applications" 2>/dev/null || true

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGE}" \
  -ov -format UDZO \
  "${DMG_PATH}" >/dev/null
rm -rf "${STAGE}"

echo "[build_mac_app] creato: ${DMG_PATH}"
echo
echo "OK. Distribuisci:  ${DMG_PATH}"
echo "L'utente apre il .dmg e fa doppio clic su '${APP_NAME}.app' (o lo trascina in Applicazioni)."
echo "Il primo avvio auto-installa il LaunchAgent e il companion parte da solo a ogni login."
