#!/usr/bin/env python3
"""Counselor Companion — il PONTE addon↔server (Fase 1 MVP).

L'addon WoW non ha rete: scrive un envelope JSON nelle SavedVariables
(CounselorDB.payload) al logout/`/reload`. Questo companion fa file-watch su quel
file, estrae il JSON e lo carica su https://wow.jeevesaicloud.com/v1/ingest.
Autenticazione: la prima volta usa il pairing-code presente nell'envelope → il
server lega char+account e restituisce un char_token, che il companion salva e
riusa (header X-Char-Token) per gli upload successivi.

Solo libreria standard Python 3.9+. Nessuna dipendenza esterna.
  python3 counselor_companion.py            # avvia il watch
  python3 counselor_companion.py --once      # un solo ciclo (test)
  python3 counselor_companion.py --path <Counselor.lua>   # forza il percorso
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import platform
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

try:
    import fcntl  # POSIX (macOS/Linux): lock singleton
except Exception:  # Windows
    fcntl = None

SSL_CTX: ssl.SSLContext | None = None   # impostato in main()


def build_ssl_context(insecure: bool = False) -> ssl.SSLContext:
    """Context TLS robusto: prova certifi (utile su macOS/python.org senza CA bundle),
    altrimenti i CA di sistema. --insecure solo per test locali."""
    if insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    try:
        import certifi  # type: ignore
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()

SERVER = os.environ.get("COUNSELOR_SERVER", "https://wow.jeevesaicloud.com")
FROZEN = bool(getattr(sys, "frozen", False))
LABEL = "com.jeeves.counselor-companion"         # macOS LaunchAgent label
WIN_RUN_VALUE = "CounselorCompanion"             # nome valore nel registro Windows
POLL_S = 10
# Round-trip statistiche: dopo il sync scarichiamo /v1/snapshot e lo scriviamo nella
# SavedVariable `CounselorSnapshot`. Il file va toccato SOLO quando WoW l'ha lasciato
# "a riposo" (non lo sta riscrivendo): mtime piu' vecchio di questa soglia. Vedi NOTA TIMING.
SNAPSHOT_REST_S = 20


def data_dir() -> str:
    """Cartella utente scrivibile per config/stato/log/binario installato.
    (Program Files su Windows e' read-only → mai scrivere accanto all'eseguibile.)"""
    sysname = platform.system()
    if sysname == "Windows":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        d = os.path.join(base, "Counselor")
    elif sysname == "Darwin":
        d = os.path.expanduser("~/Library/Application Support/Counselor")
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
        d = os.path.join(base, "counselor")
    os.makedirs(d, exist_ok=True)
    return d


DATA_DIR = data_dir()
CFG_PATH = os.path.join(DATA_DIR, "config.json")
STATE_PATH = os.path.join(DATA_DIR, "state.json")
LOCK_PATH = os.path.join(DATA_DIR, "companion.lock")
LOG_PATH = os.path.join(DATA_DIR, "companion.log")
INSTALLED_BIN = os.path.join(
    DATA_DIR, "counselor-companion" + (".exe" if platform.system() == "Windows" else ""))


def setup_logging():
    """Dirotta stdout/stderr su file (il servizio e' invisibile: niente console).
    Indispensabile su Windows --windowed dove stdout non esiste."""
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 2_000_000:
            open(LOG_PATH, "w").close()  # rotazione grezza
        f = open(LOG_PATH, "a", buffering=1, encoding="utf-8")
        sys.stdout = f
        sys.stderr = f
    except Exception:
        pass


def _msgbox(title: str, text: str):
    """Feedback all'utente senza console (usato su Windows --windowed; innocuo altrove)."""
    if platform.system() == "Windows":
        try:
            import ctypes
            ctypes.windll.user32.MessageBoxW(0, text, title, 0x40)  # MB_ICONINFORMATION
            return
        except Exception:
            pass
    print(f"{title}: {text}", flush=True)

_LOCK_FH = None  # mantiene aperto il file-handle del lock per tutta la vita del processo


def acquire_singleton() -> bool:
    """Garantisce una sola istanza drenante (evita doppioni se l'utente lancia a mano
    mentre gira il servizio). True se abbiamo il lock, False se gia' in esecuzione."""
    global _LOCK_FH
    if fcntl is None:
        return True  # su Windows il servizio e' unico per design
    try:
        _LOCK_FH = open(LOCK_PATH, "w")
        fcntl.flock(_LOCK_FH.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        _LOCK_FH.write(str(os.getpid()))
        _LOCK_FH.flush()
        return True
    except Exception:
        return False


# ---------- config/state ----------
def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return dict(default)


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def autodetect_paths():
    """Tutti i Counselor.lua sotto le installazioni WoW Classic Era note."""
    home = os.path.expanduser("~")
    pats = []
    sysname = platform.system()
    # La flavor e' un wildcard: WoW Forever usa _forever_ (flavor 'wowf'), ma copriamo
    # anche _classic_era_/_retail_ ecc. senza doverli elencare.
    if sysname == "Darwin":
        pats += ["/Applications/World of Warcraft/*/WTF/Account/*/SavedVariables/Counselor.lua",
                 home + "/Applications/World of Warcraft/*/WTF/Account/*/SavedVariables/Counselor.lua"]
    elif sysname == "Windows":
        for base in (r"C:\Program Files (x86)\World of Warcraft",
                     r"C:\Program Files\World of Warcraft", r"D:\World of Warcraft"):
            pats.append(base + r"\*\WTF\Account\*\SavedVariables\Counselor.lua")
    else:  # Linux / wine
        pats += [home + "/.wine/drive_c/Program Files (x86)/World of Warcraft/*/WTF/Account/*/SavedVariables/Counselor.lua"]
    found = []
    for p in pats:
        found += glob.glob(p)
    return sorted(set(found))


# ---------- parsing SavedVariables ----------
def _unescape_lua(s: str) -> str:
    """Decodifica un letterale-stringa Lua (contenuto tra le virgolette) → stringa reale."""
    out, i, n = [], 0, len(s)
    while i < n:
        ch = s[i]
        if ch == "\\" and i + 1 < n:
            nx = s[i + 1]
            if nx == "n": out.append("\n"); i += 2
            elif nx == "t": out.append("\t"); i += 2
            elif nx == "r": out.append("\r"); i += 2
            elif nx == '"': out.append('"'); i += 2
            elif nx == "\\": out.append("\\"); i += 2
            elif nx.isdigit():
                j = i + 1; dig = ""
                while j < n and len(dig) < 3 and s[j].isdigit():
                    dig += s[j]; j += 1
                out.append(chr(int(dig))); i = j
            else:
                out.append(nx); i += 2
        else:
            out.append(ch); i += 1
    return "".join(out)


def extract_payload(text: str):
    """Estrae la stringa CounselorDB.payload (JSON) dal file SavedVariables e la parsa."""
    key = '["payload"]'
    k = text.find(key)
    if k < 0:
        return None
    eq = text.find("=", k)
    q = text.find('"', eq)
    if eq < 0 or q < 0:
        return None
    # scorre fino alla virgoletta di chiusura NON escapata
    i = q + 1
    while i < len(text):
        if text[i] == "\\":
            i += 2; continue
        if text[i] == '"':
            break
        i += 1
    literal = text[q + 1:i]
    try:
        return json.loads(_unescape_lua(literal))
    except Exception as e:
        print(f"[warn] JSON non parsabile: {e}")
        return None


# ---------- upload ----------
def post_ingest(payload: dict, char_token: str | None):
    body = {
        "source": "companion",
        "character": payload.get("character") or {},
        "gear": payload.get("gear") or [],
        "quests_completed": payload.get("quests_completed"),
        "active_quests": payload.get("active_quests") or [],
        "loot": payload.get("loot") or [],
        "perf": payload.get("perf") or [],
        "perf_live": payload.get("perf_live") or [],
    }
    if char_token:
        headers = {"Content-Type": "application/json", "X-Char-Token": char_token}
    else:
        body["pairing_code"] = payload.get("pairing_code")
        headers = {"Content-Type": "application/json"}
    req = urllib.request.Request(SERVER + "/v1/ingest", data=json.dumps(body).encode(),
                                 headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=20, context=SSL_CTX) as r:
        return r.status, json.loads(r.read())


def char_key(payload: dict) -> str:
    c = payload.get("character") or {}
    return f"{(c.get('name') or '').lower()}@{(c.get('realm') or '').lower()}"


def process_file(path: str, state: dict) -> bool:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except Exception as e:
        print(f"[warn] non leggo {path}: {e}"); return False
    digest = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()
    seen = state.setdefault("files", {})
    unchanged = seen.get(path) == digest
    payload = extract_payload(text)
    if not payload or not (payload.get("character") or {}).get("name"):
        seen[path] = digest; save_json(STATE_PATH, state); return False
    key = char_key(payload)
    tokens = state.setdefault("char_tokens", {})
    tok = tokens.get(key)
    # Perf dal combat log su disco (l'addon su Forever non puo' leggerlo): calcolato
    # qui e allegato all'ingest. Robusto: mai far fallire il sync se il parsing va male.
    c = payload.get("character") or {}
    try:
        sessions = extract_perf_sessions(text)
        if not sessions and isinstance(payload.get("perf_sessions"), list):
            sessions = payload.get("perf_sessions")      # fallback: sessioni nel payload JSON
    except Exception as e:
        print(f"[perf] sessioni non leggibili: {e}")
        sessions = []
    try:
        perf = parse_combat_perf(c.get("name"), c.get("level"), state, sessions)
    except Exception as e:
        print(f"[perf] parsing combat log fallito: {e}")
        perf = []
    if perf:
        payload["perf"] = perf
    # Niente di nuovo (ne' SavedVariables ne' nuovi encounter) → non ricaricare.
    if unchanged and not perf:
        return False
    if not tok and not payload.get("pairing_code"):
        print(f"[info] {key}: nessun char_token e nessun pairing-code — incolla il codice nell'addon (/co).")
        seen[path] = digest; save_json(STATE_PATH, state); return False
    try:
        st, resp = post_ingest(payload, tok)
    except urllib.error.HTTPError as e:
        print(f"[err] ingest HTTP {e.code}: {e.read().decode()[:160]}"); return False
    except Exception as e:
        print(f"[err] ingest fallito ({e})"); return False
    if st < 300 and resp.get("char_token"):
        tokens[key] = resp["char_token"]
        perf_note = f" · perf {len(perf)}" if perf else ""
        print(f"[ok] sync {c.get('name')} L{c.get('level')} · gear {resp.get('gear_items')} · char#{resp.get('character_id')}{perf_note}")
        # Round-trip statistiche: dopo ogni sync riuscito marca lo snapshot come "da
        # scrivere" per questo file; flush_snapshot lo scrivera' quando il file sara' a riposo.
        state.setdefault("snap_pending", {})[path] = tokens[key]
        seen[path] = digest; save_json(STATE_PATH, state); return True
    print(f"[err] risposta inattesa: {st} {resp}"); return False


# ---------- round-trip statistiche → SavedVariable CounselorSnapshot ----------
# NOTA TIMING (ciclo di vita delle SavedVariables di WoW):
#   • WoW CARICA l'intero file SavedVariables in memoria al LOGIN/entrata-nel-mondo
#     (e al /reload) e lo RISCRIVE da zero al LOGOUT/uscita/ /reload.
#   • Quindi una nostra scrittura su disco viene LETTA dall'addon solo al prossimo
#     login/reload, e SOPRAVVIVE solo se WoW non riscrive il file nel frattempo
#     sovrascrivendolo con la sua copia in memoria.
#   • L'addon dichiara `CounselorSnapshot` come SavedVariable (nel .toc): WoW la ricarica
#     dal file al login. Perche' la nostra scrittura venga letta e non venga schiacciata,
#     la facciamo quando il file e' "A RIPOSO" — cioe' WoW ha finito di scriverlo e non lo
#     sta toccando: mtime piu' vecchio di SNAPSHOT_REST_S. Tipicamente: dopo il logout,
#     o con WoW chiuso. Scrittura ATOMICA (tmp+os.replace) e CounselorDB sempre preservato.
#   LIMITE ONESTO: se scriviamo mentre WoW e' in esecuzione, al successivo logout WoW
#   sovrascrive il file con la sua copia in memoria e lo snapshot puo' risultare vecchio di
#   una sessione. Non possiamo rilevare in modo affidabile e cross-platform se WoW e' acceso,
#   quindi usiamo l'euristica mtime-a-riposo. In ogni caso lo snapshot e' best-effort: non
#   fa MAI fallire il sync (tutto in try/except).

def _lua_escape(s: str) -> str:
    out = []
    for ch in s:
        if ch == "\\": out.append("\\\\")
        elif ch == '"': out.append('\\"')
        elif ch == "\n": out.append("\\n")
        elif ch == "\r": out.append("\\r")
        elif ch == "\t": out.append("\\t")
        else: out.append(ch)
    return "".join(out)


def to_lua(obj, indent: int = 0) -> str:
    """Serializza un valore Python in un letterale Lua (NON JSON): stringhe fra virgolette
    con escape, numeri, bool, nil, tabelle annidate (liste → array posizionale, dict →
    [\"chiave\"]=valore). Usato per scrivere il blocco CounselorSnapshot = {...}."""
    pad, pad2 = "  " * indent, "  " * (indent + 1)
    if obj is None or isinstance(obj, bool):
        return "nil" if obj is None else ("true" if obj else "false")
    if isinstance(obj, int):
        return str(obj)
    if isinstance(obj, float):
        if obj != obj or obj in (float("inf"), float("-inf")):  # NaN/inf → 0 (Lua non li gradisce)
            return "0"
        return repr(obj)
    if isinstance(obj, str):
        return '"' + _lua_escape(obj) + '"'
    if isinstance(obj, (list, tuple)):
        if not obj:
            return "{}"
        parts = [pad2 + to_lua(v, indent + 1) + "," for v in obj]
        return "{\n" + "\n".join(parts) + "\n" + pad + "}"
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        parts = [pad2 + '["' + _lua_escape(str(k)) + '"]=' + to_lua(v, indent + 1) + "," for k, v in obj.items()]
        return "{\n" + "\n".join(parts) + "\n" + pad + "}"
    return '"' + _lua_escape(str(obj)) + '"'  # fallback prudente


def strip_lua_assignment(text: str, varname: str) -> str:
    """Rimuove un assegnamento TOP-LEVEL `varname = { ... }` (bilanciando le graffe e
    rispettando le stringhe) dal testo SavedVariables. Lascia intatto tutto il resto
    (es. CounselorDB). Se non presente, ritorna il testo invariato."""
    idx = 0
    while True:
        k = text.find(varname, idx)
        if k < 0:
            return text
        line_start = text.rfind("\n", 0, k) + 1
        # dev'essere l'inizio di un assegnamento a inizio riga (non un'occorrenza dentro una stringa)
        if text[line_start:k].strip() != "":
            idx = k + len(varname); continue
        br = text.find("{", k)
        if br < 0:
            return text
        i, depth, in_str = br, 0, False
        while i < len(text):
            ch = text[i]
            if in_str:
                if ch == "\\":
                    i += 2; continue
                if ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    i += 1; break
            i += 1
        end = i
        while end < len(text) and text[end] in " \t;":
            end += 1
        if end < len(text) and text[end] == "\n":
            end += 1
        return text[:line_start] + text[end:]


def write_snapshot_to_sv(path: str, snap: dict) -> None:
    """Scrive/aggiorna il blocco `CounselorSnapshot = {...}` nel file SavedVariables
    PRESERVANDO CounselorDB (e ogni altra variabile). Scrittura ATOMICA (tmp+os.replace)."""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    cleaned = strip_lua_assignment(text, "CounselorSnapshot")
    if cleaned and not cleaned.endswith("\n"):
        cleaned += "\n"
    out = cleaned + "CounselorSnapshot = " + to_lua(snap, 0) + "\n"
    tmp = path + ".cosnap.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, path)


def fetch_snapshot(char_token: str):
    req = urllib.request.Request(SERVER + "/v1/snapshot",
                                 headers={"X-Char-Token": char_token}, method="GET")
    with urllib.request.urlopen(req, timeout=20, context=SSL_CTX) as r:
        return json.loads(r.read())


def flush_snapshot(path: str, state: dict) -> None:
    """Se c'e' uno snapshot pendente per `path`, lo scarica e lo scrive nel file SV — ma
    SOLO quando il file e' "a riposo" (mtime piu' vecchio di SNAPSHOT_REST_S: WoW non lo sta
    scrivendo). Best-effort: non solleva MAI, il sync non dipende da questo. Vedi NOTA TIMING."""
    pend = state.setdefault("snap_pending", {})
    tok = pend.get(path)
    if not tok:
        return
    try:
        if not os.path.exists(path):
            return
        if (time.time() - os.path.getmtime(path)) < SNAPSHOT_REST_S:
            return  # WoW ha appena scritto / sta scrivendo: attendi che sia a riposo
        snap = fetch_snapshot(tok)
        write_snapshot_to_sv(path, snap)
        # La nostra scrittura cambia il file: riallinea il digest memorizzato cosi' il
        # prossimo giro NON la scambi per una modifica di WoW e non rifaccia un sync inutile.
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                state.setdefault("files", {})[path] = hashlib.sha256(
                    f.read().encode("utf-8", "replace")).hexdigest()
        except Exception:
            pass
        pend.pop(path, None)
        save_json(STATE_PATH, state)
        g = (snap.get("guild") or {})
        print(f"[snap] CounselorSnapshot scritto · membri {g.get('members')} · "
              f"roster {len(snap.get('roster') or [])} · dps {len(snap.get('dps') or [])}")
    except urllib.error.HTTPError as e:
        print(f"[snap] HTTP {e.code} — salto, ritento al prossimo giro")
    except Exception as e:
        print(f"[snap] non scritto ({e}) — salto, ritento al prossimo giro")


# ---------- installazione come servizio di background (Mac/Windows/Linux) ----------
PLIST_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
SYSTEMD_UNIT = os.path.expanduser("~/.config/systemd/user/counselor-companion.service")


def _service_argv():
    """Comando che l'autostart deve eseguire per far girare il servizio."""
    if FROZEN:
        return [INSTALLED_BIN, "--service"]
    return [os.path.abspath(sys.executable), os.path.abspath(__file__), "--service"]


def _ensure_installed_binary():
    """Copia il binario frozen in DATA_DIR (posizione stabile, non la cartella di Download)."""
    if not FROZEN:
        return
    import shutil
    src = os.path.abspath(sys.executable)
    if os.path.abspath(INSTALLED_BIN) != src:
        shutil.copy2(src, INSTALLED_BIN)
        try:
            os.chmod(INSTALLED_BIN, 0o755)
        except Exception:
            pass


def install_macos():
    import plistlib
    import subprocess
    _ensure_installed_binary()
    os.makedirs(os.path.dirname(PLIST_PATH), exist_ok=True)
    plist = {
        "Label": LABEL,
        "ProgramArguments": _service_argv(),
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }
    with open(PLIST_PATH, "wb") as f:
        plistlib.dump(plist, f)
    uid = os.getuid()
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)
    subprocess.run(["launchctl", "unload", PLIST_PATH], capture_output=True)
    r = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST_PATH], capture_output=True, text=True)
    if r.returncode != 0:
        subprocess.run(["launchctl", "load", "-w", PLIST_PATH], capture_output=True)
    subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/{LABEL}"], capture_output=True)


def uninstall_macos():
    import subprocess
    uid = os.getuid()
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)
    subprocess.run(["launchctl", "unload", PLIST_PATH], capture_output=True)
    if os.path.exists(PLIST_PATH):
        os.remove(PLIST_PATH)


def install_windows():
    import subprocess
    import winreg
    _ensure_installed_binary()
    cmd = subprocess.list2cmdline(_service_argv())
    key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                         r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_SET_VALUE)
    winreg.SetValueEx(key, WIN_RUN_VALUE, 0, winreg.REG_SZ, cmd)
    winreg.CloseKey(key)
    DETACHED_PROCESS = 0x00000008
    CREATE_NO_WINDOW = 0x08000000
    subprocess.Popen(_service_argv(), creationflags=DETACHED_PROCESS | CREATE_NO_WINDOW,
                     close_fds=True)


def uninstall_windows():
    import winreg
    try:
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                             r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_SET_VALUE)
        winreg.DeleteValue(key, WIN_RUN_VALUE)
        winreg.CloseKey(key)
    except FileNotFoundError:
        pass


def install_linux():
    import subprocess
    _ensure_installed_binary()
    os.makedirs(os.path.dirname(SYSTEMD_UNIT), exist_ok=True)
    execstart = " ".join(f'"{a}"' for a in _service_argv())
    unit = (
        "[Unit]\nDescription=Counselor Companion\n\n"
        f"[Service]\nExecStart={execstart}\nRestart=always\nRestartSec=10\n\n"
        "[Install]\nWantedBy=default.target\n"
    )
    with open(SYSTEMD_UNIT, "w", encoding="utf-8") as f:
        f.write(unit)
    subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
    subprocess.run(["systemctl", "--user", "enable", "--now", "counselor-companion.service"],
                   capture_output=True)


def uninstall_linux():
    import subprocess
    subprocess.run(["systemctl", "--user", "disable", "--now", "counselor-companion.service"],
                   capture_output=True)
    if os.path.exists(SYSTEMD_UNIT):
        os.remove(SYSTEMD_UNIT)


_WOW_FLAVORS = ["_forever_", "_classic_era_", "_classic_", "_retail_", "_ptr_"]


def wow_flavor_dirs():
    """Trova le cartelle 'flavor' di WoW (es. .../World of Warcraft/_forever_) su Mac/Windows/Linux."""
    home = os.path.expanduser("~")
    sysname = platform.system()
    if sysname == "Darwin":
        roots = ["/Applications/World of Warcraft", home + "/Applications/World of Warcraft"]
    elif sysname == "Windows":
        roots = [r"C:\Program Files (x86)\World of Warcraft", r"C:\Program Files\World of Warcraft",
                 r"D:\World of Warcraft", r"D:\Games\World of Warcraft", r"C:\Games\World of Warcraft"]
    else:
        roots = [home + "/.wine/drive_c/Program Files (x86)/World of Warcraft"]
    found = []
    for r in roots:
        try:
            if not os.path.isdir(r):
                continue
            for fl in _WOW_FLAVORS:
                d = os.path.join(r, fl)
                if os.path.isdir(d):
                    found.append(d)
        except Exception:
            pass
    return found


# ---------- combat log → perf encounters ----------
# Su WoW Forever l'addon NON puo' leggere il combat log in gioco (valori "secret"
# → ADDON_ACTION_BLOCKED). Qui, lato companion, parsiamo il file testuale che WoW
# scrive su disco quando l'utente attiva /combatlog, e ne ricaviamo gli encounter
# (dmg/heal/durata) del PROPRIO personaggio da inviare come body["perf"].

# Riga tipo: "11/7/2026 16:38:02.6111  SPELL_DAMAGE,srcGUID,\"srcName\",srcFlags,..."
CL_TS_RE = re.compile(r"^(\d+/\d+/\d+)\s+([\d:.]+)\s+(.*)$")
# Il primo campo dei "advanced params" e' un GUID (o 16 zeri per nil); serve a capire
# se la riga include il blocco advanced (su Forever e' presente: 19 campi).
CL_GUID_RE = re.compile(r"^(?:Player|Creature|Pet|Vehicle|GameObject|BattlePet|BNetAccount|Vignette|Cast|Item)-")
CL_ADV_FIELDS = 19          # n. campi del blocco advanced osservato su Forever
CL_GAP_S = 5.0              # inattivita' del proprio char che chiude un encounter
CL_MIN_DUR_S = 5.0          # encounter piu' corti si scartano
CL_DAMAGE_EVENTS = {
    "SWING_DAMAGE", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE", "RANGE_DAMAGE",
    "SPELL_BUILDING_DAMAGE", "DAMAGE_SHIELD", "DAMAGE_SPLIT",
}
# NB: SWING_DAMAGE_LANDED e' volutamente escluso: duplica SWING_DAMAGE (stesso ts/amount).
CL_HEAL_EVENTS = {"SPELL_HEAL", "SPELL_PERIODIC_HEAL", "SPELL_BUILDING_HEAL"}


def _cl_split_csv(s: str):
    """Split CSV del combat log rispettando le virgolette (i nomi possono contenere virgole)."""
    out, cur, q = [], [], False
    for ch in s:
        if ch == '"':
            q = not q
            cur.append(ch)
        elif ch == "," and not q:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def _cl_parse_ts(dpart: str, tpart: str):
    """'11/7/2026' + '16:38:02.6111' → epoch locale (float). None se non parsabile."""
    try:
        mo, da, yr = dpart.split("/")
        hh, mm, rest = tpart.split(":")
        ss, _, frac = rest.partition(".")
        base = time.mktime((int(yr), int(mo), int(da), int(hh), int(mm), int(ss), 0, 0, -1))
        return base + (float("0." + frac) if frac else 0.0)
    except Exception:
        return None


def newest_combatlog():
    """Il file WoWCombatLog-*.txt piu' recente (per mtime) tra le installazioni WoW trovate."""
    cands = []
    for fl in wow_flavor_dirs():
        cands += glob.glob(os.path.join(fl, "Logs", "WoWCombatLog-*.txt"))
    if not cands:
        return None
    try:
        return max(cands, key=lambda p: os.path.getmtime(p))
    except Exception:
        return None


# --- RAID METER: bitmask dei sourceFlags del combat log (COMBATLOG_OBJECT_*) ---
# Per attribuire il danno/cura ai SOLI GIOCATORI del raid (non mob/NPC/pet) usiamo:
#   • tipo oggetto GIOCATORE: 0x00000400 (COMBATLOG_OBJECT_TYPE_PLAYER)
#   • affiliazione raid/party/mine: 0x1(MINE)|0x2(PARTY)|0x4(RAID) = 0x7
# Un source e' un giocatore del raid se (flags & PLAYER) e (flags & AFFIL_RAID).
CL_OBJ_TYPE_PLAYER = 0x00000400
CL_AFFIL_RAID = 0x7           # MINE | PARTY | RAID
CL_DUR_FLOOR_S = 1.0          # floor della durata attiva (evita dps assurdi su 1 solo evento)

# --- parsing del blocco Lua CounselorDB.perf_sessions dalle SavedVariables ---
# L'addon (altro componente) scrive una SavedVariable:
#   CounselorDB.perf_sessions = { {["id"]="...",["start"]=<epoch>,["stop"]=<epoch|nil>,["by"]="..."}, ... }
# stop assente/nil ⇒ sessione ancora APERTA (conta fino ad ora). Non e' JSON: lo
# leggiamo direttamente dal testo Lua del file (lo stesso gia' letto per il payload).
_RE_SESS_ID = re.compile(r'\["id"\]\s*=\s*"((?:[^"\\]|\\.)*)"')
_RE_SESS_ID_NUM = re.compile(r'\["id"\]\s*=\s*(-?\d+)')
_RE_SESS_BY = re.compile(r'\["by"\]\s*=\s*"((?:[^"\\]|\\.)*)"')
_RE_SESS_START = re.compile(r'\["start"\]\s*=\s*(-?\d+)')
_RE_SESS_STOP = re.compile(r'\["stop"\]\s*=\s*(-?\d+)')


def _lua_balanced_block(text: str, open_idx: int):
    """Ritorna la sottostringa dal '{' in open_idx fino alla '}' che lo bilancia,
    rispettando le stringhe Lua (le graffe dentro le virgolette non contano)."""
    depth, i, n, instr = 0, open_idx, len(text), False
    while i < n:
        ch = text[i]
        if instr:
            if ch == "\\":
                i += 2; continue
            if ch == '"':
                instr = False
        else:
            if ch == '"':
                instr = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[open_idx:i + 1]
        i += 1
    return None


def _parse_lua_session(sub: str):
    """Da un sotto-blocco Lua {...} estrae {id,start,stop,by}. None se id o start mancano."""
    out = {}
    m = _RE_SESS_ID.search(sub)
    if m:
        out["id"] = _unescape_lua(m.group(1))
    else:
        m = _RE_SESS_ID_NUM.search(sub)
        if m:
            out["id"] = m.group(1)
    m = _RE_SESS_START.search(sub)
    if not m:
        return None
    try:
        out["start"] = int(m.group(1))
    except Exception:
        return None
    m = _RE_SESS_STOP.search(sub)
    out["stop"] = int(m.group(1)) if m else None      # assente ⇒ sessione aperta
    m = _RE_SESS_BY.search(sub)
    if m:
        out["by"] = _unescape_lua(m.group(1))
    if not out.get("id"):
        return None
    return out


def extract_perf_sessions(text: str):
    """Estrae CounselorDB.perf_sessions dal testo SavedVariables → lista di dict
    {id,start,stop,by}. Lista vuota se la SavedVariable non c'e'/non e' parsabile."""
    idx = text.find('["perf_sessions"]')
    if idx < 0:
        idx = text.find("perf_sessions")
    if idx < 0:
        return []
    eq = text.find("=", idx)
    if eq < 0:
        return []
    ob = text.find("{", eq)
    if ob < 0:
        return []
    block = _lua_balanced_block(text, ob)
    if not block:
        return []
    inner = block[1:-1]
    sessions, i, n = [], 0, len(inner)
    while i < n:
        if inner[i] == "{":
            sub = _lua_balanced_block(inner, i)
            if not sub:
                break
            s = _parse_lua_session(sub)
            if s:
                sessions.append(s)
            i += len(sub)
        else:
            i += 1
    return sessions


def _session_windows(sessions):
    """Normalizza le sessioni in finestre (sid, start, end, by, is_open). Per le sessioni
    aperte (stop=None) end = ora. Scarta le incoerenti (end < start, id/start mancanti)."""
    now = time.time()
    out = []
    for s in sessions or []:
        sid = str(s.get("id") or "")
        start = s.get("start")
        if not sid or not isinstance(start, int):
            continue
        stop = s.get("stop")
        is_open = stop is None
        end = now if is_open else stop
        try:
            end = float(end)
        except Exception:
            continue
        if end < start:
            continue
        out.append((sid, float(start), end, s.get("by"), is_open))
    return out


def parse_combat_perf(char_name, char_level, state: dict, sessions):
    """RAID METER basato su sessioni. Legge le righe NUOVE del combat log del CAPO RAID
    (il suo file contiene gli eventi di TUTTI i presenti, come WarcraftLogs) e aggrega
    danno/cura PER GIOCATORE e PER SESSIONE. Ritorna una lista di record perf:
       {char, dmg, heal, dps, hps, dur, ts, zone, level, session}

    - Considera SOLO gli eventi che cadono dentro una sessione [start, stop or now].
      Eventi fuori da ogni sessione (mob/trash casuali) ⇒ IGNORATI (niente DPS spuri).
    - Sorgente contato SOLO se e' un GIOCATORE del raid: (sflags & PLAYER 0x400) e
      (sflags & 0x7 MINE|PARTY|RAID). Esclude NPC/mob e i pet (tipo PET, non PLAYER).
    - Giocatore identificato dal sourceName, normalizzato con strip del realm sul 1o '-'
      ('Luchidra-Ii-Normal-EU' → 'Luchidra'). level ignoto per gli altri ⇒ None (solo il
      proprio char ha level, se noto).
    - Heal effettivo = amount - overhealing. dps = dmg/dur, hps = heal/dur.
    - dur = durata ATTIVA del giocatore nella sessione (ultimo - primo suo evento), con
      floor CL_DUR_FLOOR_S. ts del record = inizio della sessione (raggruppa i giocatori).
    - Posizione letta tracciata in state['combatlog'] (byte offset) e aggregati parziali
      in state['perf_agg'] (persistenti): le sessioni APERTE accumulano tra un poll e
      l'altro e vengono re-inviate con i totali aggiornati (il backend fa UPSERT).
    - Se non ci sono sessioni ⇒ non invia nulla. Robusto a file assente/righe malformate.
    """
    windows = _session_windows(sessions)
    if not windows:
        return []                        # nessuna sessione di raid → non inviare nulla
    path = newest_combatlog()
    if not path:
        return []
    cl = state.setdefault("combatlog", {})
    agg = state.setdefault("perf_agg", {})   # key "sid|player_lc" → accumulatore persistente
    reset = False
    if cl.get("path") != path:          # nuovo file di log → riparti da capo
        cl["path"] = path
        cl["offset"] = 0
        reset = True
    try:
        size = os.path.getsize(path)
    except Exception:
        return []
    start = cl.get("offset", 0)
    if not isinstance(start, int) or start < 0 or start > size:
        start = 0                        # offset incoerente / file troncato o sostituito
        reset = True
    if reset:
        agg.clear()                      # re-lettura da 0 ⇒ azzera per non ri-contare

    current_zone = cl.get("zone")        # continua la zona vista nel file
    last_complete = start
    touched = set()                      # sessioni con nuovi eventi in questo poll
    name_lc = (char_name or "").lower()
    try:
        lvl_self = int(char_level) if char_level is not None else None
    except Exception:
        lvl_self = None

    try:
        f = open(path, "rb")
    except Exception as e:
        print(f"[perf] non apro {path}: {e}")
        return []
    try:
        f.seek(start)
        while True:
            raw = f.readline()
            if not raw:
                break
            if not raw.endswith(b"\n"):
                # riga parziale in coda (file in scrittura): non consumarla
                break
            last_complete = f.tell()
            try:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                m = CL_TS_RE.match(line)
                if not m:
                    continue
                dpart, tpart, csv = m.groups()
                sub = csv.split(",", 1)[0]
                if sub == "ZONE_CHANGE":
                    fs = _cl_split_csv(csv)
                    if len(fs) >= 3:
                        current_zone = fs[2].strip('"') or None
                    continue
                is_dmg = sub in CL_DAMAGE_EVENTS
                is_heal = sub in CL_HEAL_EVENTS
                if not (is_dmg or is_heal):
                    continue
                fs = _cl_split_csv(csv)
                if len(fs) < 9:
                    continue
                # SOLO giocatori del raid: tipo PLAYER e affiliazione MINE|PARTY|RAID.
                try:
                    sflags = int(fs[3], 16) if fs[3].lower().startswith("0x") else int(fs[3])
                except Exception:
                    sflags = 0
                if not ((sflags & CL_OBJ_TYPE_PLAYER) and (sflags & CL_AFFIL_RAID)):
                    continue
                ts = _cl_parse_ts(dpart, tpart)
                if ts is None:
                    continue
                sid = None
                for w in windows:
                    if w[1] <= ts <= w[2]:
                        sid = w[0]; break
                if sid is None:
                    continue             # evento fuori da ogni sessione → ignora
                # posizione dell'amount: dopo i campi base (+prefix spell) e il blocco advanced.
                p = 9 if sub.startswith("SWING") else 12
                if p >= len(fs):
                    continue
                tok = fs[p]
                adv = bool(CL_GUID_RE.match(tok)) or tok == "0" * 16
                amt_idx = p + (CL_ADV_FIELDS if adv else 0)
                if amt_idx >= len(fs):
                    continue
                try:
                    amount = int(fs[amt_idx])
                except Exception:
                    continue
                if is_heal:
                    try:
                        over = int(fs[amt_idx + 2]) if amt_idx + 2 < len(fs) else 0
                    except Exception:
                        over = 0
                    dv, hv = 0, max(0, amount - over)   # heal effettivo = amount - overhealing
                else:
                    dv, hv = (amount if amount > 0 else 0), 0
                player = fs[2].strip('"').split("-", 1)[0]
                if not player:
                    continue
                key = sid + "|" + player.lower()
                a = agg.get(key)
                if a is None:
                    a = {"sid": sid, "player": player, "first": ts, "last": ts,
                         "dmg": 0, "heal": 0, "zone": current_zone}
                    agg[key] = a
                if ts < a["first"]:
                    a["first"] = ts
                if ts > a["last"]:
                    a["last"] = ts
                a["dmg"] += dv
                a["heal"] += hv
                if not a.get("zone"):
                    a["zone"] = current_zone
                touched.add(sid)
            except Exception:
                continue  # riga malformata: ignorala, non interrompere il parsing
    finally:
        f.close()

    cl["offset"] = last_complete
    cl["zone"] = current_zone

    # bound memoria: scarta gli accumulatori di sessioni non piu' presenti nella SavedVariable
    live = {w[0] for w in windows}
    sid_start = {w[0]: w[1] for w in windows}
    for k in list(agg.keys()):
        if agg[k].get("sid") not in live:
            del agg[k]

    emit = []
    for a in agg.values():
        if a["sid"] not in touched:
            continue                     # nessun nuovo evento questo giro → non re-inviare
        if (a["dmg"] + a["heal"]) <= 0:
            continue
        dur = max(a["last"] - a["first"], CL_DUR_FLOOR_S)
        dmg, heal = int(a["dmg"]), int(a["heal"])
        player_lc = a["player"].lower()
        emit.append({
            "char": a["player"],
            "ts": int(sid_start.get(a["sid"], a["first"])),
            "dur": round(dur, 1),
            "dmg": dmg,
            "heal": heal,
            "dps": round(dmg / dur, 1),
            "hps": round(heal / dur, 1),
            "level": lvl_self if (name_lc and player_lc == name_lc) else None,
            "zone": a.get("zone"),
            "session": a["sid"],
        })
    return emit


def install_addon():
    """Installa/aggiorna l'addon Counselor dentro Interface/AddOns di ogni WoW trovato,
    scaricando lo zip dal sito (breadcrumb di stato). Trasparente per l'utente."""
    print("[addon] Cerco l'installazione di World of Warcraft…", flush=True)
    dirs = wow_flavor_dirs()
    if not dirs:
        print("[addon] WoW non trovato ora — l'addon verra' installato appena WoW sara' presente.", flush=True)
        return 0
    import io
    import zipfile
    print(f"[addon] Scarico l'addon da {SERVER}…", flush=True)
    try:
        ctx = SSL_CTX or build_ssl_context()
        req = urllib.request.Request(SERVER + "/download/counselor-addon.zip",
                                     headers={"User-Agent": "CounselorCompanion"})
        with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
            data = r.read()
    except Exception as e:
        print(f"[addon] download fallito: {e}", flush=True)
        return 0
    ok = 0
    for fl in dirs:
        addons = os.path.join(fl, "Interface", "AddOns")
        try:
            os.makedirs(addons, exist_ok=True)
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                z.extractall(addons)  # contiene la cartella Counselor/
            print(f"[addon] ✓ installato in {addons}", flush=True)
            ok += 1
        except Exception as e:
            print(f"[addon] errore in {addons}: {e}", flush=True)
    return ok


def do_install():
    sysname = platform.system()
    # 1) installa l'addon dentro WoW (trasparente)
    try:
        addon_ok = install_addon()
    except Exception:
        addon_ok = 0
    # 2) installa il companion come servizio di background
    try:
        if sysname == "Darwin":
            install_macos()
        elif sysname == "Windows":
            install_windows()
        else:
            install_linux()
    except Exception as e:
        _msgbox("Counselor — errore", f"Installazione fallita: {e}")
        raise
    addon_line = (f"Addon installato in WoW ({addon_ok} cartelle). " if addon_ok
                  else "Addon: WoW non trovato ora, lo installero' appena presente. ")
    _msgbox("Counselor",
            "Installato. Counselor gira in background e si avvia da solo a ogni login.\n\n"
            + addon_line + "\n\n"
            "Unica cosa che devi fare: registrarti su https://wow.jeevesaicloud.com,\n"
            "generare il pairing-code e incollarlo nell'addon in gioco (/co). Poi basta.")


def do_uninstall():
    sysname = platform.system()
    if sysname == "Darwin":
        uninstall_macos()
    elif sysname == "Windows":
        uninstall_windows()
    else:
        uninstall_linux()
    _msgbox("Counselor", "Disinstallato: il servizio in background non si avviera' piu'.")


def print_status():
    sysname = platform.system()
    installed = os.path.exists(
        PLIST_PATH if sysname == "Darwin" else SYSTEMD_UNIT) if sysname != "Windows" else None
    if sysname == "Windows":
        try:
            import winreg
            key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                 r"Software\Microsoft\Windows\CurrentVersion\Run")
            winreg.QueryValueEx(key, WIN_RUN_VALUE)
            installed = True
        except Exception:
            installed = False
    print(f"Counselor Companion — stato")
    print(f"  autostart installato: {'si' if installed else 'no'}")
    print(f"  binario:              {INSTALLED_BIN if FROZEN else os.path.abspath(__file__)}")
    print(f"  dati/log:             {DATA_DIR}")
    print(f"  server:               {SERVER}")


# ---------- main ----------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", action="store_true", help="installa come servizio di background e avvia")
    ap.add_argument("--uninstall", action="store_true", help="rimuove il servizio di background")
    ap.add_argument("--status", action="store_true", help="mostra lo stato dell'installazione")
    ap.add_argument("--service", action="store_true", help="(interno) esecuzione come servizio: log su file")
    ap.add_argument("--watch", action="store_true", help="drain in foreground (debug, console visibile)")
    ap.add_argument("--once", action="store_true", help="un solo ciclo e poi esce")
    ap.add_argument("--path", help="percorso esplicito di Counselor.lua (ripetibile con virgole)")
    ap.add_argument("--insecure", action="store_true", help="salta la verifica TLS (SOLO test locali)")
    args = ap.parse_args()

    # Comandi di gestione: nessuna rete, console visibile, nessun dirottamento log.
    if args.install:
        do_install(); return
    if args.uninstall:
        do_uninstall(); return
    if args.status:
        print_status(); return

    # Binario frozen lanciato senza comandi (doppio click) = prima esecuzione → auto-installa.
    if FROZEN and not (args.service or args.watch or args.once or args.path):
        do_install(); return

    # Modalita' servizio: invisibile → log su file (indispensabile su Windows --windowed).
    if args.service and FROZEN:
        setup_logging()

    global SSL_CTX
    SSL_CTX = build_ssl_context(insecure=args.insecure)

    if not args.once and not acquire_singleton():
        print("[info] un'altra istanza del companion e' gia' in esecuzione — esco.")
        return

    cfg = load_json(CFG_PATH, {"server": SERVER, "paths": []})
    state = load_json(STATE_PATH, {"files": {}, "char_tokens": {}})

    def resolve_paths():
        if args.path:
            return [p.strip() for p in args.path.split(",") if p.strip()]
        if cfg.get("paths"):
            return list(cfg["paths"])
        return autodetect_paths()

    print(f"Counselor Companion → {SERVER}", flush=True)
    paths = resolve_paths()
    if paths and not args.path and not cfg.get("paths"):
        cfg["paths"] = paths
        save_json(CFG_PATH, cfg)
    for p in paths:
        print(f"  watch: {p}", flush=True)

    waited = False
    while True:
        if not paths:
            # WoW/addon non ancora presenti: NON usciamo, ri-rileviamo a ogni giro
            # finche' il file compare (cosi' il servizio resta invisibile e vivo).
            if not waited:
                print("[info] Counselor.lua non ancora presente — attendo l'avvio di WoW…", flush=True)
                waited = True
            paths = resolve_paths()
            if paths and not args.path:
                cfg["paths"] = paths
                save_json(CFG_PATH, cfg)
                for p in paths:
                    print(f"  watch: {p}", flush=True)
                waited = False
        for p in paths:
            if os.path.exists(p):
                process_file(p, state)
                # round-trip statistiche: scrive CounselorSnapshot quando il file e' a riposo
                flush_snapshot(p, state)
        if args.once:
            break
        time.sleep(POLL_S)


if __name__ == "__main__":
    main()
