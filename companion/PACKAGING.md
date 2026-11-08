# Packaging del Counselor Companion

Obiettivo: distribuzione **a prova di doppio clic** per utenti non tecnici.
Il binario grezzo di PyInstaller non basta: su macOS un binario CLI apre il
Terminale, su Windows manca un installer. Qui sotto come produrre i pacchetti
veri (`.app`/`.dmg` su Mac, installer `.exe` su Windows).

> Il companion si auto-installa al primo avvio (`do_install()`): LaunchAgent su
> macOS, chiave `Run` in HKCU su Windows. I pacchetti qui sotto servono solo a
> consegnarlo e lanciarlo bene — non duplicano la logica di autostart.

---

## macOS → `.app` + `.dmg`

### Prerequisiti
- macOS (gli strumenti `sips`, `iconutil`, `hdiutil`, `codesign` sono di sistema).
- Il binario PyInstaller onefile. O lo si costruisce al volo (serve Python 3 +
  `pyinstaller` nel PATH) o lo si ha gia' in `companion/dist/`:
  - `companion/dist/counselor-companion-mac` (nome usato dalla CI), oppure
  - `companion/dist/counselor-companion` (nome usato da `build.sh`).

### Comando
```bash
# 1) costruisci il binario (se non ce l'hai gia')
bash companion/build.sh

# 2) crea Counselor Companion.app + Counselor Companion.dmg
bash companion/build_mac_app.sh
# versione personalizzata:
APP_VERSION=1.2.0 bash companion/build_mac_app.sh
# oppure parti da un binario specifico:
bash companion/build_mac_app.sh /percorso/al/counselor-companion-mac
```
Output in `companion/dist/`:
- `Counselor Companion.app` — doppio clic = lancia il companion (si auto-installa);
- `Counselor Companion.dmg` — il file da distribuire.

### Cosa fa `build_mac_app.sh`
1. trova o costruisce il binario onefile;
2. crea il bundle `.app` con `Info.plist`:
   - `CFBundleExecutable` = `counselor-companion-mac`,
   - `CFBundleIdentifier` = `com.jeeves.counselor-companion` (== `LABEL` del LaunchAgent),
   - `CFBundleName` / `CFBundleDisplayName` = `Counselor Companion`,
   - `LSUIElement = 1` → gira in background, **nessuna icona nel Dock**, nessuna
     finestra/Terminale;
3. genera l'icona `AppIcon.icns` da `../stemma.png` (best-effort: se mancano
   `sips`/`iconutil` o il PNG, prosegue senza icona);
4. firma **ad-hoc** il bundle (best-effort);
5. impacchetta l'`.app` in un `.dmg` compresso (`hdiutil`, con alias ad
   `/Applications` per il drag-and-drop).

### Avviso Gatekeeper
La firma ad-hoc **non** elimina l'avviso "sviluppatore non identificato". Per
una distribuzione pulita firma e **notarizza** con un *Developer ID Application*:
vedi [`../deploy/signing/SIGNING.md`](../deploy/signing/SIGNING.md). Nel frattempo
l'utente puo' aprire con tasto destro → *Apri* (una volta sola).

---

## Windows → installer `.exe` (Inno Setup)

Sorgente installer: [`../deploy/installer/counselor-companion.iss`](../deploy/installer/counselor-companion.iss).

### Prerequisiti
- **Inno Setup 6+** (https://jrsoftware.org/isdl.php) → fornisce `ISCC.exe`.
- Il `counselor-companion.exe`, da `companion/build.ps1` (eseguito **su Windows**)
  oppure scaricato dall'artifact CI `build:windows`. Default atteso in
  `companion/dist/counselor-companion.exe`.

### Comando
```bat
REM 1) build del .exe (su Windows)
powershell -ExecutionPolicy Bypass -File companion\build.ps1

REM 2) compila l'installer (dalla root del repo)
ISCC.exe deploy\installer\counselor-companion.iss

REM varianti:
ISCC.exe /DMyAppVersion=1.2.0 deploy\installer\counselor-companion.iss
ISCC.exe /DExeDir="C:\percorso\con\exe" deploy\installer\counselor-companion.iss
```
Output: `deploy\installer\Output\counselor-companion-setup.exe`.

### Cosa fa l'installer
- installa in `%LOCALAPPDATA%\Counselor` (per-utente, **niente UAC/admin**);
- registra la voce in "Installazione applicazioni" (disinstallabile);
- avvia il companion a fine installazione → al primo avvio scrive da solo la
  chiave `Run` in HKCU;
- alla disinstallazione lancia `counselor-companion.exe --uninstall` (rimuove
  l'autostart) e ripulisce `%LOCALAPPDATA%\Counselor`.

### SmartScreen
Per evitare l'avviso SmartScreen, firma Authenticode **sia il `.exe` sia
l'installer** (vedi `SIGNING.md`). Puoi agganciare `SignTool` in `[Setup]`.

---

## Integrazione con la CI esistente (`.gitlab-ci.yml`)

> Il `.gitlab-ci.yml` **non va modificato** in questo task. Qui sotto solo dove
> si aggancerebbe il packaging, come riferimento futuro.

La CI oggi produce **solo i binari** grezzi come artifact:
- `build:windows` → `companion/dist/counselor-companion.exe`
- `build:linux`   → `companion/dist/counselor-companion-linux`
- `build:macos`   → `companion/dist/counselor-companion-mac` (`when: manual`,
  nessun runner macOS registrato; build locale consigliata con `build.sh`)

Dove agganciare i pacchetti di questo documento:
- **macOS**: lo stage `build:macos` gira solo su un runner taggato `macos`. Su
  quel runner, dopo PyInstaller, si potrebbe eseguire `bash companion/build_mac_app.sh`
  e pubblicare `companion/dist/Counselor Companion.dmg` come artifact. In
  assenza di runner macOS, il `.dmg` si produce **in locale** con lo stesso
  script a partire dall'artifact `build:macos` o da `build.sh`.
- **Windows**: `ISCC.exe` e' Windows-only, mentre `build:windows` gira sotto
  Wine su Linux (immagine `batonogov/pyinstaller-windows`). L'installer si
  compila quindi **in locale su Windows** partendo dall'artifact `.exe` della
  CI (o dal `.exe` gia' firmato dallo stage `sign:windows`). In alternativa, un
  job dedicato su un runner Windows con Inno Setup installato.

In sintesi: la CI resta la fonte dei **binari**; i **pacchetti distribuibili**
(`.dmg` / `setup.exe`) si generano con gli script di questo documento a partire
da quei binari.
