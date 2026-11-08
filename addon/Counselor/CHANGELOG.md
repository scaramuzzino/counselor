# Counselor — Changelog

## 0.4.0
- Hub unico CounselorHub: un solo pannello che raccoglie tutte le funzioni (niente piu' finestre sparse).
- Meter DPS/HPS live in-game via API nativa C_DamageMeter (secret-safe, senza parsing del combat log).
- "Gilda ORA": roster live della gilda con gearscore e stato dei membri online.
- Estetica dossier: finestra ridisegnata con fondo scuro, banda stemma di gilda e titoli in oro.
- Cache snapshot persistente (CounselorSnapshot) per mantenere i dati tra una sessione e l'altra.

## 0.2.0 (beta)
- Icona sulla minimappa (clic sx: finestra Jeeves · clic dx: pannello dati).
- Finestra Jeeves in-game: saluti e aforismi, casella domande (coda), eco in chat di gilda.
- Cattura chat di gilda (CHAT_MSG_GUILD) con consenso esplicito (GDPR).
- Raccolta quest attive e progressione XP, oltre a gear/played/livello/rank.
- Comandi: /co (pannello), /jeeves (maggiordomo), /co sync.

## 0.1.0
- MVP: raccolta gear/played/quest-count/livello/gilda+rank del proprio personaggio → SavedVariables.
- Pannello /co con pairing-code per collegare il sito.
