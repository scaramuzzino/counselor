#!/usr/bin/env bash
# Firma (Developer ID) + notarizzazione Apple di un binario/app macOS. Da eseguire SU macOS.
#
# Variabili richieste:
#   DEV_ID_APP   identita' nel keychain, es: "Developer ID Application: Nome Cognome (TEAMID)"
# Per la notarizzazione, UNA delle due opzioni:
#   A) AC_KEYCHAIN_PROFILE  nome di un profilo notarytool gia' salvato
#        (crealo una volta con:  xcrun notarytool store-credentials <profilo> \
#           --apple-id <mail> --team-id <TEAMID> --password <app-specific-password>)
#   B) AC_APPLE_ID + AC_PASSWORD (app-specific password) + AC_TEAM_ID
#
# Uso: sign_macos.sh <percorso/al/binario-o-.app-o-.dmg>
set -euo pipefail
TARGET="${1:?uso: sign_macos.sh <binario|.app|.dmg>}"
: "${DEV_ID_APP:?serve DEV_ID_APP (es. 'Developer ID Application: Nome (TEAMID)')}"

echo "→ codesign (hardened runtime + timestamp)"
codesign --force --timestamp --options runtime --sign "$DEV_ID_APP" "$TARGET"
codesign --verify --strict --verbose=2 "$TARGET"

echo "→ notarizzazione (notarytool, attende l'esito)"
ZIPDIR="$(mktemp -d)"; trap 'rm -rf "$ZIPDIR"' EXIT
ZIP="$ZIPDIR/notarize.zip"
ditto -c -k --keepParent "$TARGET" "$ZIP"
if [ -n "${AC_KEYCHAIN_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$AC_KEYCHAIN_PROFILE" --wait
else
  : "${AC_APPLE_ID:?serve AC_APPLE_ID oppure AC_KEYCHAIN_PROFILE}"
  : "${AC_PASSWORD:?serve AC_PASSWORD (app-specific password)}"
  : "${AC_TEAM_ID:?serve AC_TEAM_ID}"
  xcrun notarytool submit "$ZIP" --apple-id "$AC_APPLE_ID" --password "$AC_PASSWORD" --team-id "$AC_TEAM_ID" --wait
fi

# Lo "staple" (notarizzazione offline incorporata) funziona su .app/.dmg/.pkg, NON su un binario nudo.
case "$TARGET" in
  *.app|*.dmg|*.pkg) xcrun stapler staple "$TARGET" && echo "✓ staple ok" ;;
  *) echo "ℹ binario nudo: niente staple (la notarizzazione resta valida, Gatekeeper la verifica online). Per lo staple offline distribuisci un .dmg/.pkg." ;;
esac
echo "✓ firmato+notarizzato: $TARGET"
