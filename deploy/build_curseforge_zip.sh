#!/usr/bin/env bash
#
# build_curseforge_zip.sh
# -----------------------
# Impacchetta l'addon Counselor in dist/Counselor.zip con la struttura
# richiesta da WoW/CurseForge: una cartella "Counselor/" alla radice dello
# zip che contiene i soli file necessari all'addon.
#
# COME CARICARLO SU CURSEFORGE (upload MANUALE dell'owner):
#   1. Login su CurseForge con l'account owner del progetto.
#   2. Vai al project 1788340 (Counselor) -> Files -> Upload.
#      URL: https://www.curseforge.com/wow/addons/<slug>  (project ID 1788340,
#      vedi "## X-Curse-Project-ID" nel .toc).
#   3. Carica dist/Counselor.zip, imposta release type e game version,
#      pubblica. L'upload NON e' automatizzato qui: CurseForge richiede il
#      login interattivo dell'owner.
#
# Lo STESSO zip (dist/Counselor.zip) puo' essere distribuito sul nostro
# canale ("nostro") senza rigenerarlo: la struttura interna e' identica.
#
set -euo pipefail

# Radice del repo = cartella padre di questo script (deploy/..)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SRC_DIR="${REPO_ROOT}/addon/Counselor"
DIST_DIR="${REPO_ROOT}/dist"
ZIP_PATH="${DIST_DIR}/Counselor.zip"

# File che fanno parte dell'addon (solo questi finiscono nello zip).
ADDON_FILES=(
  "Counselor.lua"
  "Counselor.toc"
  "CHANGELOG.md"
)
# Le texture .tga sono incluse dinamicamente (gcrest.tga, gbg.tga, ghub.tga, ...).

command -v zip >/dev/null 2>&1 || { echo "ERRORE: 'zip' non trovato nel PATH." >&2; exit 1; }
[ -d "${SRC_DIR}" ] || { echo "ERRORE: cartella addon non trovata: ${SRC_DIR}" >&2; exit 1; }

# Staging pulito in una cartella temporanea: cosi' lo zip contiene esattamente
# i file voluti dentro "Counselor/" e nessun file spurio (.DS_Store, ecc.).
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT
PKG_DIR="${STAGE_DIR}/Counselor"
mkdir -p "${PKG_DIR}"

# Copia i file fissi.
for f in "${ADDON_FILES[@]}"; do
  if [ -f "${SRC_DIR}/${f}" ]; then
    cp "${SRC_DIR}/${f}" "${PKG_DIR}/${f}"
  else
    echo "ERRORE: file richiesto mancante: ${SRC_DIR}/${f}" >&2
    exit 1
  fi
done

# Copia tutte le texture .tga presenti.
shopt -s nullglob
tga_found=0
for tga in "${SRC_DIR}"/*.tga; do
  cp "${tga}" "${PKG_DIR}/"
  tga_found=1
done
shopt -u nullglob
[ "${tga_found}" -eq 1 ] || echo "ATTENZIONE: nessun file .tga trovato in ${SRC_DIR}" >&2

# Rimuovi eventuali file spuri che potrebbero essersi insinuati.
find "${STAGE_DIR}" -name '.DS_Store' -delete
find "${STAGE_DIR}" -name '__MACOSX' -prune -exec rm -rf {} + 2>/dev/null || true

# Genera lo zip.
mkdir -p "${DIST_DIR}"
rm -f "${ZIP_PATH}"
( cd "${STAGE_DIR}" && zip -r -X "${ZIP_PATH}" "Counselor" >/dev/null )

echo "ZIP creato: ${ZIP_PATH}"
echo "Contenuto:"
unzip -l "${ZIP_PATH}"
