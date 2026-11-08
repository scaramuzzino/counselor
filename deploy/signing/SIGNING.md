# Firma dei binari del Counselor Companion

Senza firma, al primo avvio i sistemi operativi mostrano un avviso ("sviluppatore non
identificato" su macOS, SmartScreen su Windows) e l'utente medio si blocca. Questa cartella
contiene tutto il necessario per firmare+notarizzare i binari in automatico nella CI.

Lo scaffolding è **opt-in**: se i certificati/secret non sono configurati, la pipeline gira
come prima producendo binari NON firmati (vedi "Mitigazione senza certificato").

---

## 1. Cosa acquistare (una volta)

### Windows — certificato Authenticode
- Un certificato **OV** (Organization Validation, ~150–300 €/anno) o **EV** (Extended, elimina
  del tutto SmartScreen ma richiede token hardware) da una CA: Sectigo, DigiCert, SSL.com…
- Ti serve il file **`.pfx`/`.p12`** + la sua **password**.

### macOS — Apple Developer Program
- Iscrizione all'**Apple Developer Program** (99 $/anno) → https://developer.apple.com/programs/
- Nel portale crei un certificato **"Developer ID Application"** e lo installi nel Portachiavi del Mac.
- Per la notarizzazione serve una **app-specific password** (appleid.apple.com → Sicurezza) e il **Team ID**.

---

## 2. Configurare i secret

### GitLab CI (per la firma Windows automatica)
In *Settings → CI/CD → Variables* (protette e mascherate):
- `WIN_PFX_B64`  = output di `base64 -w0 certificato.pfx`
- `WIN_PFX_PASS` = password del `.pfx`

La firma Windows parte da sola nella pipeline quando `WIN_PFX_B64` è presente.

### macOS (firma locale, non c'è un runner macOS)
Una volta sola, salva le credenziali di notarizzazione nel Portachiavi:
```
xcrun notarytool store-credentials counselor \
  --apple-id tuo@mail.it --team-id TEAMID --password <app-specific-password>
```
Poi firma il binario appena compilato:
```
export DEV_ID_APP="Developer ID Application: Tuo Nome (TEAMID)"
export AC_KEYCHAIN_PROFILE="counselor"
bash deploy/signing/sign_macos.sh companion/dist/counselor-companion-mac
```

---

## 3. Come funziona in CI

- `deploy/signing/sign_windows.sh <exe>` — firma Authenticode via **osslsigncode** (gira su Linux,
  niente Windows), con timestamp RFC3161. Senza `WIN_PFX_B64` esce senza firmare.
- Il job `sign:windows` in `.gitlab-ci.yml` firma l'artifact di `build:windows`; `publish:server`
  pubblica il binario firmato (needs `optional`, così senza certificato la pipeline non si rompe).

---

## 4. Mitigazione SENZA certificato (gratis, nel frattempo)

Da mettere nella pagina di download del sito (drawer helper), finché i certificati non ci sono:

- **macOS**: "Fai **clic destro → Apri** la prima volta, poi *Apri* nel dialogo. Serve una volta sola."
  (bypassa Gatekeeper senza notarizzazione). Nota: un eseguibile da riga di comando aperto con
  doppio clic apre il Terminale — valuta di impacchettarlo in un **.app** per un vero doppio clic.
- **Windows**: "SmartScreen → **Ulteriori informazioni → Esegui comunque**."

Queste istruzioni NON sono una vera firma: riducono l'attrito ma l'avviso resta finché non si
firma/notarizza davvero.

---

## 5. Nota packaging macOS (futuro)

Il binario attuale è un eseguibile CLI `--onefile`. Per un'esperienza "doppio clic" pulita su Mac
conviene un **.app bundle** (con Info.plist) firmato e notarizzato, distribuito in un **.dmg**
(su cui si può fare `stapler staple` per la verifica offline). Vedi `sign_macos.sh`.
