; =============================================================================
; counselor-companion.iss — installer Inno Setup per il Counselor Companion (Windows)
;
; PERCHE': distribuire il nudo counselor-companion.exe e' scomodo per un utente
; non tecnico (SmartScreen, "dove lo metto?", nessuna voce in "App installate").
; Questo installer da' un'esperienza da vero doppio clic:
;   - copia il .exe in una cartella utente SCRIVIBILE (%LOCALAPPDATA%, niente UAC);
;   - crea la voce in "Installazione applicazioni" (disinstallabile);
;   - avvia il companion a fine installazione.
; Al primo avvio il companion fa do_install() da solo: scrive la chiave Run in
; HKCU e copia il binario nella sua DATA_DIR. L'installer quindi NON deve toccare
; il registro di autostart: ci pensa l'app.
;
; COME COMPILARE:
;   1. Installa Inno Setup 6+ (https://jrsoftware.org/isdl.php). Fornisce ISCC.exe.
;   2. Costruisci prima il .exe (companion/build.ps1 su Windows, o scaricalo
;      dall'artifact CI build:windows).
;   3. Dalla root del repo:
;        ISCC.exe deploy\installer\counselor-companion.iss
;      Opzionale, per puntare a un .exe gia' pronto altrove:
;        ISCC.exe /DExeDir="C:\percorso\con\exe" deploy\installer\counselor-companion.iss
;      Opzionale, versione:
;        ISCC.exe /DMyAppVersion=1.2.0 deploy\installer\counselor-companion.iss
;   4. Output: deploy\installer\Output\counselor-companion-setup.exe
;
; FIRMA: per togliere SmartScreen firma l'installer (e il .exe) con Authenticode.
; Vedi deploy/signing/SIGNING.md. Puoi agganciare qui SignTool con [Setup] SignTool=.
; =============================================================================

#define MyAppName "Counselor Companion"
#define MyAppPublisher "The Faceless Council"
#define MyAppURL "https://wow.jeevesaicloud.com"
#define MyAppExeName "counselor-companion.exe"

; Versione (sovrascrivibile da riga di comando: ISCC /DMyAppVersion=...).
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

; Cartella dove ISCC cerca il .exe da impacchettare. Default: companion\dist
; (percorso relativo a questo .iss -> ..\..\companion\dist). Sovrascrivibile con
; /DExeDir="C:\percorso".
#ifndef ExeDir
  #define ExeDir "..\..\companion\dist"
#endif

[Setup]
; AppId: GUID stabile = l'installer riconosce e aggiorna la stessa app.
AppId={{B7E4B0C2-1D3F-4A9E-9C2A-0C0A5E1F9B21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
; Installazione per-utente in %LOCALAPPDATA%: niente privilegi admin, niente UAC.
DefaultDirName={localappdata}\Counselor
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
; Non serve una cartella nel menu Start: l'app e' un servizio invisibile.
DisableDirPage=yes
Uninstallable=yes
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
OutputDir=Output
OutputBaseFilename=counselor-companion-setup
; Architettura: il .exe PyInstaller e' a 64 bit.
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Copia il .exe nella cartella di installazione. "ignoreversion": sovrascrive
; sempre (il PyInstaller onefile non ha versione di file affidabile).
Source: "{#ExeDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Run]
; Avvia il companion a fine installazione. nowait+runasoriginaluser: parte come
; l'utente corrente e l'installer non resta appeso. Il primo avvio fa do_install()
; (scrive la chiave Run in HKCU) e poi gira invisibile a ogni login.
Filename: "{app}\{#MyAppExeName}"; Description: "Avvia {#MyAppName}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; Alla disinstallazione, chiedi al companion di rimuovere il proprio autostart
; (chiave Run in HKCU + LaunchAgent equivalente). RunOnceId evita doppie esecuzioni.
Filename: "{app}\{#MyAppExeName}"; Parameters: "--uninstall"; Flags: runhidden skipifdoesntexist; RunOnceId: "CounselorUninstall"

[UninstallDelete]
; Ripulisce i dati utente del companion (config/stato/log/binario copiato).
Type: filesandordirs; Name: "{localappdata}\Counselor"
