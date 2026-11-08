--[[ Counselor — addon in-game (Fase 1 MVP, pure Lua, nessuna dipendenza).
  Raccoglie il PROPRIO personaggio (gear, /played, quest, livello, gilda+rank) e scrive
  in SavedVariables (CounselorDB) un "envelope" serializzato in JSON ASCII-safe, che il
  COMPANION desktop legge (al logout/reload) e carica su https://wow.jeevesaicloud.com.
  L'addon NON ha rete: è il companion a parlare col server. Vedi STATO.md / PIANO.
  Autenticazione: l'utente incolla il PAIRING-CODE (dal sito) nella UI → finisce
  nell'envelope → il companion lo usa al primo upload per legare char+account. ]]--

local ADDON = ...
CounselorDB = CounselorDB or {}

-- Cache persistente dello snapshot del sito. Il companion scrive CounselorSnapshot nel file, ma un
-- /reload di WoW la sovrascrive (WoW risalva la propria memoria PRIMA di rileggere il file). Al LOGIN
-- invece lo snapshot viene letto: lo copiamo in CounselorDB.snap_cache (persistente), cosi' le
-- statistiche restano visibili anche dopo i /reload, finche' il companion non ne scrive uno nuovo.
local function curSnap()
  if type(CounselorSnapshot) == "table" then return CounselorSnapshot end
  return CounselorDB.snap_cache
end

local SCHEMA = 1
-- 19 slot equipaggiamento (INVSLOT_* 1..19; 0=ammo non usato qui)
local SLOTS = {
  "HeadSlot","NeckSlot","ShoulderSlot","ShirtSlot","ChestSlot","WaistSlot","LegsSlot",
  "FeetSlot","WristSlot","HandsSlot","Finger0Slot","Finger1Slot","Trinket0Slot",
  "Trinket1Slot","BackSlot","MainHandSlot","SecondaryHandSlot","RangedSlot","TabardSlot",
}

-- ---------- JSON encoder minimale, ASCII-safe (\uXXXX per byte >126) ----------
local function jesc(s)
  s = tostring(s)
  -- Su WoW Forever certi valori (es. nomi dal combat log) sono "secret": qualsiasi
  -- operazione (#s, byte) da un addon scatena ADDON_ACTION_BLOCKED. Li saltiamo.
  local okLen, n = pcall(function() return #s end)
  if not okLen or type(n) ~= "number" then return "" end
  local out = {}
  for i = 1, n do
    local b = s:byte(i)
    if b == nil then break end
    if b == 34 then out[#out+1] = '\\"'
    elseif b == 92 then out[#out+1] = '\\\\'
    elseif b == 10 then out[#out+1] = '\\n'
    elseif b == 13 then out[#out+1] = '\\r'
    elseif b == 9 then out[#out+1] = '\\t'
    elseif b < 32 or b > 126 then out[#out+1] = string.format('\\u%04x', b)
    else out[#out+1] = string.char(b) end
  end
  return table.concat(out)
end

local function jenc(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v then return string.format("%d", v) end
    return string.format("%.4f", v)
  elseif t == "string" then return '"' .. jesc(v) .. '"'
  elseif t == "table" then
    -- array se chiavi 1..n contigue
    local n, isarr = 0, true
    for k in pairs(v) do n = n + 1; if type(k) ~= "number" then isarr = false end end
    if isarr and n > 0 then
      local a = {}
      for i = 1, n do a[i] = jenc(v[i]) end
      return "[" .. table.concat(a, ",") .. "]"
    elseif n == 0 then return "{}"
    else
      local a = {}
      for k, val in pairs(v) do a[#a+1] = '"' .. jesc(k) .. '":' .. jenc(val) end
      return "{" .. table.concat(a, ",") .. "}"
    end
  end
  return "null"
end

-- ---------- raccolta dati ----------
local playedTotal, playedLevel = nil, nil

local function collectGear()
  local gear = {}
  for _, slotName in ipairs(SLOTS) do
    local slotId = GetInventorySlotInfo and select(1, GetInventorySlotInfo(slotName)) or nil
    if slotId then
      local link = GetInventoryItemLink("player", slotId)
      if link then
        local itemId = GetInventoryItemID("player", slotId)
        local name, _, quality, ilvl = GetItemInfo(link)   -- può essere nil se non cacheato
        gear[#gear+1] = {
          slot = slotName, item_id = itemId, item_link = link,
          ilvl = ilvl, quality = quality,
        }
      end
    end
  end
  return gear
end

local function questsCompletedCount()
  -- NB: C_QuestLog.GetAllCompletedQuestIDs è RISERVATA alla UI Blizzard su WoW Forever
  -- (chiamarla scatena ADDON_ACTION_BLOCKED, e pcall non lo evita). Non la usiamo.
  return nil
end

-- Quest ATTIVE (quelle nel log in corso): titolo, livello, zona (header), completata.
-- L'armory NON le espone: vengono solo da qui.
local function collectQuests()
  local quests = {}
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then
    return quests
  end
  local header = nil
  local num = select(1, C_QuestLog.GetNumQuestLogEntries()) or 0
  for i = 1, num do
    local info = C_QuestLog.GetInfo(i)
    if info then
      if info.isHeader then
        header = info.title
      else
        local complete = info.isComplete
        if complete == nil and C_QuestLog.IsComplete and info.questID then
          local ok, r = pcall(C_QuestLog.IsComplete, info.questID)
          if ok then complete = r end
        end
        quests[#quests + 1] = {
          id = info.questID, title = info.title, level = info.level,
          zone = header, complete = complete and true or false,
        }
      end
    end
  end
  return quests
end

-- Cattura del LOOT da CHAT_MSG_LOOT. Parsa link item, nome, quantita' e destinatario;
-- accoda in CounselorDB.loot (buffer limitato a 250). Nessuna rete, nessun invio in chat.
local function captureLoot(msg)
  if not msg then return end
  local itemName = msg:match("|h%[(.-)%]|h")
  if not itemName then return end                         -- non e' una riga di loot con item
  local itemLink = msg:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)") or msg:match("(|Hitem:.-|h%[.-%]|h)")
  local itemId = tonumber(msg:match("|Hitem:(%d+):"))
  local qty = tonumber(msg:match("|h|?r?x(%d+)")) or tonumber(msg:match("x(%d+)%.?%s*$")) or 1
  -- destinatario: "You receive loot:" → io; "Nome receives loot:" → quel Nome
  local who = msg:match("^(%S+) receives? loot:")
  if not who or who == "You" or who == "Tu" then
    who = UnitName("player")
  end
  local quality = nil
  if itemId then
    local _, _, q = GetItemInfo(itemId)                   -- può essere nil se non cacheato
    quality = q
  elseif itemLink then
    local _, _, q = GetItemInfo(itemLink)
    quality = q
  end
  CounselorDB.loot = CounselorDB.loot or {}
  local loot = CounselorDB.loot
  loot[#loot + 1] = {
    item_id = itemId, item_name = itemName, item_link = itemLink,
    quality = quality, qty = qty, who = who, ts = time(),
  }
  while #loot > 250 do table.remove(loot, 1) end
end

-- ---------- Performance meter (combat log) — DISABILITATO su Forever ----------
-- Conservato per compatibilita': su WoW Forever il combat log e' "secret" e NON e' registrato
-- (vedi piu' sotto). Il meter LIVE vero usa l'API nativa C_DamageMeter (hub, pannello destro).
local perf = { active = false, start = 0, dmg = 0, heal = 0 }
local myGUID, petGUID

local function perfReset()
  perf.active = true
  perf.start = GetTime()
  perf.dmg = 0; perf.heal = 0
end

local AFFIL_MINE = 0x00000001   -- COMBATLOG_OBJECT_AFFILIATION_MINE (copre anche pet/totem miei)
local function perfOnCLEU()
  local flags = tonumber(select(6, CombatLogGetCurrentEventInfo())) or 0
  if bit.band(flags, AFFIL_MINE) == 0 then return end
  local sub = select(2, CombatLogGetCurrentEventInfo())
  if not perf.active then perfReset() end
  if sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
    local amt, over = select(15, CombatLogGetCurrentEventInfo())
    local eff = (tonumber(amt) or 0) - (tonumber(over) or 0)
    if eff > 0 then perf.heal = perf.heal + eff end
    return
  end
  local amount
  if sub == "SWING_DAMAGE" then
    amount = select(12, CombatLogGetCurrentEventInfo())
  elseif sub == "SPELL_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "DAMAGE_SHIELD" then
    amount = select(15, CombatLogGetCurrentEventInfo())
  else
    return
  end
  amount = tonumber(amount) or 0
  if amount > 0 then perf.dmg = perf.dmg + amount end
end

local function perfEndCombat()
  if not perf.active then return end
  perf.active = false
  local dur = GetTime() - perf.start
  if dur < 5 or (perf.dmg + perf.heal) <= 0 then return end   -- scarta combat insignificanti
  CounselorDB.perf = CounselorDB.perf or {}
  local arr = CounselorDB.perf
  arr[#arr + 1] = {
    ts = time(), dur = math.floor(dur + 0.5),
    dmg = math.floor(perf.dmg), heal = math.floor(perf.heal),
    level = UnitLevel("player"),
    zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or nil,
  }
  while #arr > 100 do table.remove(arr, 1) end
end

local function buildEnvelope()
  local name = UnitName("player")
  local realm = GetRealmName and GetRealmName() or ""
  local _, class = UnitClass("player")
  local _, race = UnitRace("player")
  local guildName, rankName, rankIndex = GetGuildInfo("player")
  local env = {
    schema = SCHEMA,
    collected_at = time(),
    pairing_code = CounselorDB.pairing_code or nil,
    character = {
      name = name, realm = realm,
      class = class, race = race,
      level = UnitLevel("player"),
      faction = (UnitFactionGroup("player")),
      played_total_s = playedTotal, played_level_s = playedLevel,
      guild = guildName, guild_rank = rankName, guild_rank_index = rankIndex,
      xp = UnitXP and UnitXP("player") or nil,
      xp_max = UnitXPMax and UnitXPMax("player") or nil,
    },
    gear = collectGear(),
    quests_completed = questsCompletedCount(),
    active_quests = collectQuests(),
    loot = CounselorDB.loot,                                       -- bottino catturato (CHAT_MSG_LOOT)
    perf = CounselorDB.perf,                                        -- DPS/HPS per combattimento (combat log)
    perf_live = CounselorDB.perf_live,                              -- DPS/HPS per-giocatore via C_DamageMeter (fine combat)
    jeeves_queue = CounselorDB.jeeves_queue,                       -- domande poste in-game
    chat_log = (CounselorDB.chat_consent and CounselorDB.chat_log) or nil,  -- solo con consenso
  }
  return env
end

local function refresh(reason)
  local env = buildEnvelope()
  CounselorDB.envelope = env
  CounselorDB.payload = jenc(env)       -- il companion legge QUESTA stringa JSON
  CounselorDB.last_collected = time()
  CounselorDB.addon_version = "0.4.0"
  if CounselorUI and CounselorUI.Update then CounselorUI.Update(reason) end
end

-- ---------- indicatore "registrazione" durante il fight ----------
local rec = CreateFrame("Frame", "CounselorRec", UIParent)
rec:SetSize(260, 26); rec:SetPoint("TOP", 0, -140); rec:SetFrameStrata("HIGH"); rec:Hide()
rec.bg = rec:CreateTexture(nil, "BACKGROUND")
rec.bg:SetAllPoints(); rec.bg:SetColorTexture(0, 0, 0, 0.55)
rec.txt = rec:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rec.txt:SetPoint("CENTER")
local function recShow(inCombat)
  if inCombat then
    rec.txt:SetText("|cffff6666* Counselor registra il combattimento...|r")
    rec:Show()
  else
    rec.txt:SetText("|cff66ff66Combattimento registrato (sync al prossimo /reload)|r")
    rec:Show()
    if C_Timer and C_Timer.After then
      C_Timer.After(5, function() rec:Hide() end)
    else
      rec:Hide()
    end
  end
end

-- ---------- eventi ----------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_REMOVED")
f:RegisterEvent("PLAYER_XP_UPDATE")
f:RegisterEvent("GUILD_ROSTER_UPDATE")
f:RegisterEvent("TIME_PLAYED_MSG")
f:RegisterEvent("CHAT_MSG_GUILD")
f:RegisterEvent("CHAT_MSG_LOOT")
-- NB: perf-meter DISABILITATO su WoW Forever: il combat log (COMBAT_LOG_EVENT_UNFILTERED)
-- espone solo valori "secret" e ogni accesso da addon scatena ADDON_ACTION_BLOCKED.
-- PLAYER_REGEN_DISABLED/ENABLED sono invece SICURI (booleani di stato, nessun secret).
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_LOGOUT")

f:SetScript("OnEvent", function(_, event, ...)
  if event == "TIME_PLAYED_MSG" then
    playedTotal, playedLevel = ...
    refresh("played")
  elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
    if type(CounselorSnapshot) == "table" then CounselorDB.snap_cache = CounselorSnapshot end  -- cattura lo snapshot al login
    myGUID = UnitGUID("player"); petGUID = UnitGUID("pet")
    if IsInGuild() then
      if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster)
      elseif GuildRoster then pcall(GuildRoster) end
    end
    if RequestTimePlayed then pcall(RequestTimePlayed) end   -- → TIME_PLAYED_MSG
    C_Timer.After(3, function() refresh("login") end)
  elseif event == "CHAT_MSG_GUILD" then
    if CounselorDB.chat_consent then
      local msg, author = ...
      CounselorDB.chat_log = CounselorDB.chat_log or {}
      local log = CounselorDB.chat_log
      log[#log + 1] = { t = time(), from = author, msg = msg }
      while #log > 300 do table.remove(log, 1) end
    end
  elseif event == "CHAT_MSG_LOOT" then
    local msg = ...
    captureLoot(msg)
  elseif event == "PLAYER_REGEN_DISABLED" then
    recShow(true)
  elseif event == "PLAYER_REGEN_ENABLED" then
    recShow(false)
  elseif event == "PLAYER_LOGOUT" then
    refresh("logout")
  else
    refresh(event)
  end
end)

-- ---------- identità visiva della gilda (SOLO estetica) ----------
local GUILD_GOLD  = { 0.91, 0.72, 0.37 }   -- #E8B85E (titoli/accenti)
local GUILD_EMBER = { 0.88, 0.34, 0.18 }   -- #E0572E (ember, accenti caldi)
local GUILD_TEXT  = { 0.95, 0.90, 0.82 }   -- #F1E6D2 (testo chiaro)
local GUILD_DIM   = { 0.72, 0.70, 0.66 }   -- grigio tenue (voci inattive)
local CREST_TEX   = "Interface\\AddOns\\Counselor\\gcrest.tga"   -- stemma 128x128 trasparente
local HUB_TEX     = "Interface\\AddOns\\Counselor\\ghub.tga"     -- sfondo "dossier" 1024x512
local WHITE       = "Interface\\Buttons\\WHITE8x8"

-- fondo scuro pieno che copre la "pietra" del template
local function skinSolidDark(frame)
  local dark = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  dark:SetColorTexture(0.05, 0.04, 0.045, 0.97)
  if frame.Inset then dark:SetAllPoints(frame.Inset)
  else dark:SetPoint("TOPLEFT", 3, -22); dark:SetPoint("BOTTOMRIGHT", -3, 3) end
  frame.darkFill = dark
  return dark
end

-- sfondo "dossier" ricco su un pannello: fondo scuro + texture cuoio ghub.tga (in pcall).
local function skinDossier(frame, alpha)
  local dark = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  dark:SetAllPoints(frame); dark:SetColorTexture(0.05, 0.04, 0.045, 0.90)
  local tex = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
  tex:SetAllPoints(frame)
  if pcall(tex.SetTexture, tex, HUB_TEX) then tex:SetAlpha(alpha or 0.92)
  else tex:Hide() end
  frame.dossier = tex
  return tex
end

-- cornice: 4 fili oro attorno al frame (100% affidabile, niente backdrop). 'a' = alpha.
local function goldBorder(frame, a)
  a = a or 0.5
  local function line() local t = frame:CreateTexture(nil, "OVERLAY"); t:SetTexture(WHITE)
    t:SetVertexColor(GUILD_GOLD[1], GUILD_GOLD[2], GUILD_GOLD[3], a); return t end
  local top = line(); top:SetHeight(1.5); top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
  local bot = line(); bot:SetHeight(1.5); bot:SetPoint("BOTTOMLEFT"); bot:SetPoint("BOTTOMRIGHT")
  local lft = line(); lft:SetWidth(1.5); lft:SetPoint("TOPLEFT"); lft:SetPoint("BOTTOMLEFT")
  local rgt = line(); rgt:SetWidth(1.5); rgt:SetPoint("TOPRIGHT"); rgt:SetPoint("BOTTOMRIGHT")
  frame.border = { top, bot, lft, rgt }
end

-- ---------- frasi di Jeeves ----------
local JEEVES = {
  greet = {
    "Bentornato, Maestro. La vostra assenza era quasi rumorosa.",
    "Ai vostri ordini. Eviti morti imbarazzanti, almeno oggi.",
    "Di servizio. Il gear non si lustra da solo, ahime'.",
  },
  aforismi = {
    "Un eroe non muore mai... se non pesta il tasto sbagliato.",
    "Il coraggio e' ammirevole; i consumabili, indispensabili.",
    "Chi non ripara l'armatura, prima o poi ripara i rimpianti.",
    "Le quest abbandonate sono i fantasmi che infestano il log.",
    "Il /played, Maestro, non mente mai.",
  },
}
local function jpick(cat) local t = JEEVES[cat]; return t[math.random(#t)] end

-- CounselorUI.Update e' definita nell'hub (pannello Profilo); 'refresh' la chiama se presente.
CounselorUI = {}

-- ---------- helper statistiche (riuso invariato) ----------
local NO_DATA = "Le statistiche della gilda arrivano dall'app Counselor Companion.\n \n1) Registrati su wow.jeevesaicloud.com\n2) Scarica e apri una volta il Companion (si installa da solo e resta in background)\n3) Incolla il pairing-code nella scheda Profilo\n \nI dati compaiono al tuo prossimo accesso al gioco."

local function fmtInt(v)
  v = tonumber(v)
  if not v then return "-" end
  return string.format("%d", math.floor(v + 0.5))
end

local function fmtNum1(v)
  v = tonumber(v)
  if not v then return "-" end
  if math.floor(v) == v then return string.format("%d", v) end
  return string.format("%.1f", v)
end

local function fmtTs(ts)
  ts = tonumber(ts)
  if not ts then return "-" end
  return date("%d/%m %H:%M", ts)
end

local function buildKPI(snap)
  local g = snap.guild or {}
  return table.concat({
    "|cffffd100Gilda|r",
    " ",
    "Nome:               " .. tostring(g.name or "-"),
    "Membri:             " .. fmtInt(g.members),
    "Livello medio:      " .. fmtNum1(g.lv_avg) .. "   (max " .. fmtInt(g.lv_max) .. ")",
    "GearScore medio:    " .. fmtInt(g.gs_avg),
    "GS min / max:       " .. fmtInt(g.gs_min) .. " / " .. fmtInt(g.gs_max),
  }, "\n")
end

local function buildDPS(snap)
  local dps = snap.dps
  if type(dps) ~= "table" or #dps == 0 then
    return "|cffffd100Classifica DPS / HPS|r\n \nNessun dato di combattimento ancora disponibile."
  end
  local lines = { "|cffffd100Classifica DPS / HPS|r  (best per personaggio)", " " }
  for i = 1, #dps do
    local r = dps[i] or {}
    lines[#lines + 1] = string.format("%2d. %s", i, tostring(r.char or "-"))
    lines[#lines + 1] = string.format("      DPS %s  |  HPS %s  |  combatt. %s",
      fmtInt(r.best_dps), fmtInt(r.best_hps), fmtInt(r.n))
  end
  return table.concat(lines, "\n")
end

local function buildLoot(snap)
  local loot = snap.loot
  if type(loot) ~= "table" or #loot == 0 then
    return "|cffffd100Ultimi drop|r\n \nNessun loot registrato."
  end
  local lines = { "|cffffd100Ultimi drop|r", " " }
  for i = #loot, 1, -1 do
    local r = loot[i] or {}
    local qty = tonumber(r.qty) or 1
    local q = (qty > 1) and (" x" .. qty) or ""
    lines[#lines + 1] = string.format("%s  -  %s: %s%s",
      fmtTs(r.ts), tostring(r.char or "-"), tostring(r.item or "-"), q)
  end
  return table.concat(lines, "\n")
end

local function buildCalendar(snap)
  local cal = snap.calendar
  if type(cal) ~= "table" or #cal == 0 then
    return "|cffffd100Prossimi eventi|r\n \nNessun evento in calendario."
  end
  local lines = { "|cffffd100Prossimi eventi|r", " " }
  for i = 1, #cal do
    local r = cal[i] or {}
    lines[#lines + 1] = string.format("%s  -  %s", fmtTs(r.ts), tostring(r.title or "-"))
  end
  return table.concat(lines, "\n")
end

-- colore di classe -> codice colore "ffRRGGBB" per concatenazione nel testo.
local function classColorHex(cls)
  local token = tostring(cls or ""):upper():gsub("%s+", "")
  if token ~= "" then
    if type(GetClassColor) == "function" then
      local ok, r, g, b = pcall(GetClassColor, token)
      if ok and r then
        return string.format("ff%02x%02x%02x",
          math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
      end
    end
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c and c.r then
      return string.format("ff%02x%02x%02x",
        math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
    end
  end
  return "ffe8b85e"   -- fallback: oro gilda
end

local ROLE_LABEL = { TANK = "Tank", HEALER = "Healer", HEAL = "Healer", DAMAGER = "DPS", DPS = "DPS" }

local function buildRaid(snap)
  local rc = snap.raid_comp
  if type(rc) ~= "table" or type(rc.members) ~= "table" or #rc.members == 0 then
    return "|cffffd100Composizione raid|r\n \nNessuna composizione: il capo la crea dal sito/Jeeves\ne appare qui al prossimo /reload."
  end
  local size = rc.size and ("  (" .. fmtInt(rc.size) .. ")") or ""
  local lines = { "|cffffd100" .. tostring(rc.title or "Composizione raid") .. "|r" .. size }
  if rc.updated_at then lines[#lines + 1] = "|cff888888aggiornata " .. fmtTs(rc.updated_at) .. "|r" end
  lines[#lines + 1] = " "
  for i = 1, #rc.members do
    local m = rc.members[i] or {}
    local hex  = classColorHex(m.cls)
    local lvl  = m.level and ("  |cffaaaaaalv " .. fmtInt(m.level) .. "|r") or ""
    local role = m.role and ("  |cffe8b85e· " .. (ROLE_LABEL[tostring(m.role):upper()] or tostring(m.role)) .. "|r") or ""
    lines[#lines + 1] = string.format("|c%s%s|r%s%s", hex, tostring(m.name or "-"), lvl, role)
    if m.note and tostring(m.note) ~= "" then
      lines[#lines + 1] = "      |cffd8d2c6" .. tostring(m.note) .. "|r"
    end
    lines[#lines + 1] = " "
  end
  return table.concat(lines, "\n")
end

-- "Gilda ORA": membri ONLINE dal server di GIOCO (GetGuildRosterInfo: nome/livello/zona/classe, nessuna rete)
-- INCROCIATI col roster del SITO (CounselorSnapshot.roster) per GEARSCORE e GRADO. Il gear/GS degli altri NON
-- e' leggibile live dal gioco (serve ispezione ravvicinata), ma il sito ce l'ha gia' nello snapshot.
local function buildGuildNow()
  if not IsInGuild() then return "|cffffd100Gilda ORA|r\n \nNon sei in una gilda." end
  local total = GetNumGuildMembers() or 0
  if total == 0 then return "|cffffd100Gilda ORA|r\n \nRoster in caricamento: riprova tra un istante." end
  -- indice nome(senza realm, minuscolo) -> {gs, role} dallo snapshot del sito
  local site = {}
  local snap = curSnap()
  if type(snap) == "table" and type(snap.roster) == "table" then
    for _, r in ipairs(snap.roster) do
      local rn = tostring(r.name or ""):match("^[^-]+")
      if rn then site[rn:lower()] = r end
    end
  end
  local online = {}
  for i = 1, total do
    local name, _, _, level, _, zone, _, _, isOnline, _, classFile = GetGuildRosterInfo(i)
    if isOnline and name then
      local nm = name:match("^[^-]+") or name                -- togli "-realm" dal nome
      local si = site[nm:lower()]
      online[#online + 1] = { name = nm, level = level, zone = zone, cls = classFile,
                              gs = si and si.gs or nil, role = si and si.role or nil }
    end
  end
  -- ordina per GEARSCORE (poi livello); chi non ha GS noto va in coda
  table.sort(online, function(a, b)
    local ga, gb = tonumber(a.gs) or -1, tonumber(b.gs) or -1
    if ga ~= gb then return ga > gb end
    return (tonumber(a.level) or 0) > (tonumber(b.level) or 0)
  end)
  local lines = { string.format("|cffffd100Gilda ORA|r  (%d online · %d totali)", #online, total), " " }
  if #online == 0 then
    lines[#lines + 1] = "Nessun membro online in questo momento."
  else
    for i = 1, #online do
      local m = online[i]
      local zone = (m.zone and m.zone ~= "") and m.zone or "zona sconosciuta"
      local gs = m.gs and ("  |cffe8b85eGS " .. fmtInt(m.gs) .. "|r") or "  |cff666666GS n/d|r"
      local role = m.role and ("  |cff888888" .. tostring(m.role) .. "|r") or ""
      lines[#lines + 1] = string.format("|c%s%s|r  |cffaaaaaalv %s|r%s%s",
        classColorHex(m.cls), m.name, fmtInt(m.level), gs, role)
      lines[#lines + 1] = "      |cffd8d2c6" .. zone .. "|r"
    end
  end
  return table.concat(lines, "\n")
end

-- Cruscotto = roster LIVE in cima (si aggiorna in diretta) + KPI della gilda dal sito sotto.
local function buildCruscotto(snap)
  local parts = { buildGuildNow(), " " }
  if type(snap) == "table" then
    parts[#parts + 1] = buildKPI(snap)
  else
    parts[#parts + 1] = "|cffffd100Statistiche gilda|r\n \nIn attesa dei dati dall'app Companion: compaiono al tuo prossimo accesso al gioco."
  end
  return table.concat(parts, "\n")
end

local STATS_TABS = {
  { key = "dash", label = "Cruscotto",  build = buildCruscotto, live = true },
  { key = "dps",  label = "DPS / HPS",  build = buildDPS },
  { key = "loot", label = "Bottino",    build = buildLoot },
  { key = "cal",  label = "Calendario", build = buildCalendar },
  { key = "raid", label = "Raid",       build = buildRaid },
}

--==================================================================================
--  HUB UNICO  (CounselorHub): header + sidebar + content (schede) + pannello DANNI
--==================================================================================
local hub = CreateFrame("Frame", "CounselorHub", UIParent, "BasicFrameTemplateWithInset")
hub:SetSize(860, 560); hub:SetPoint("CENTER"); hub:Hide()
hub:SetMovable(true); hub:EnableMouse(true); hub:SetClampedToScreen(true)
hub:SetFrameStrata("HIGH")
hub:RegisterForDrag("LeftButton")
hub:SetScript("OnDragStart", hub.StartMoving); hub:SetScript("OnDragStop", hub.StopMovingOrSizing)
skinSolidDark(hub)
if hub.TitleText then hub.TitleText:SetText("") end

-- ---- header ----
local header = CreateFrame("Frame", nil, hub)
header:SetPoint("TOPLEFT", hub, "TOPLEFT", 8, -24)
header:SetPoint("TOPRIGHT", hub, "TOPRIGHT", -8, -24)
header:SetHeight(56)
local hband = header:CreateTexture(nil, "BACKGROUND")
hband:SetAllPoints(); hband:SetColorTexture(0, 0, 0, 0.40)

local crest = header:CreateTexture(nil, "ARTWORK")
crest:SetTexture(CREST_TEX); crest:SetSize(46, 46)
crest:SetPoint("TOPLEFT", header, "TOPLEFT", 8, -4)

local brand = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
brand:SetPoint("TOPLEFT", crest, "TOPRIGHT", 12, -2)
brand:SetText("COUNSELOR"); brand:SetTextColor(unpack(GUILD_GOLD))

local brandSub = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
brandSub:SetPoint("TOPLEFT", brand, "BOTTOMLEFT", 1, -2)
brandSub:SetText("The Faceless Council"); brandSub:SetTextColor(unpack(GUILD_TEXT))

local statusFS = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
statusFS:SetPoint("RIGHT", header, "RIGHT", -8, 2); statusFS:SetJustifyH("RIGHT")

local reloadBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
reloadBtn:SetSize(120, 22); reloadBtn:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -6, 2)
reloadBtn:SetText("Aggiorna dati")
reloadBtn:SetScript("OnClick", function() ReloadUI() end)

local hsep = hub:CreateTexture(nil, "OVERLAY")
hsep:SetTexture(WHITE); hsep:SetVertexColor(GUILD_GOLD[1], GUILD_GOLD[2], GUILD_GOLD[3], 0.85)
hsep:SetHeight(2)
hsep:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
hsep:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -2)

-- ---- regioni: sidebar, content, meter pane ----
local sidebar = CreateFrame("Frame", nil, hub)
sidebar:SetPoint("TOPLEFT", hub, "TOPLEFT", 12, -90)
sidebar:SetSize(150, 456)
skinDossier(sidebar, 0.80); goldBorder(sidebar, 0.45)

local content = CreateFrame("Frame", nil, hub)
content:SetPoint("TOPLEFT", hub, "TOPLEFT", 170, -90)
content:SetPoint("BOTTOMRIGHT", hub, "BOTTOMRIGHT", -216, 16)
skinDossier(content, 0.92); goldBorder(content, 0.5)

local meterPane = CreateFrame("Frame", nil, hub)
meterPane:SetPoint("TOPRIGHT", hub, "TOPRIGHT", -10, -90)
meterPane:SetSize(198, 456)
skinDossier(meterPane, 0.80); goldBorder(meterPane, 0.5)

-- ================= SIDEBAR: voci di navigazione =================
local NAV = {
  { kind = "stats", tab = 1, label = "Cruscotto" },
  { kind = "stats", tab = 2, label = "DPS / HPS" },
  { kind = "stats", tab = 3, label = "Bottino" },
  { kind = "stats", tab = 4, label = "Calendario" },
  { kind = "stats", tab = 5, label = "Raid" },
  { kind = "jeeves",         label = "Jeeves" },
  { kind = "profile",        label = "Profilo" },
}
local navBtns = {}
local hubSelect   -- forward (definita dopo i pannelli)
for i, nav in ipairs(NAV) do
  local b = CreateFrame("Button", nil, sidebar)
  b:SetSize(134, 30)
  if i == 1 then b:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 8, -10)
  else b:SetPoint("TOPLEFT", navBtns[i - 1], "BOTTOMLEFT", 0, -4) end
  b.sel = b:CreateTexture(nil, "BACKGROUND")
  b.sel:SetAllPoints(); b.sel:SetColorTexture(GUILD_GOLD[1], GUILD_GOLD[2], GUILD_GOLD[3], 0.16); b.sel:Hide()
  b.acc = b:CreateTexture(nil, "OVERLAY")
  b.acc:SetTexture(WHITE); b.acc:SetVertexColor(GUILD_GOLD[1], GUILD_GOLD[2], GUILD_GOLD[3], 0.95)
  b.acc:SetWidth(3); b.acc:SetPoint("TOPLEFT"); b.acc:SetPoint("BOTTOMLEFT"); b.acc:Hide()
  b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.fs:SetPoint("LEFT", b, "LEFT", 12, 0); b.fs:SetText(nav.label); b.fs:SetTextColor(unpack(GUILD_DIM))
  b:SetScript("OnEnter", function(self) if not self._active then self.fs:SetTextColor(unpack(GUILD_TEXT)) end end)
  b:SetScript("OnLeave", function(self) if not self._active then self.fs:SetTextColor(unpack(GUILD_DIM)) end end)
  b:SetScript("OnClick", function() hubSelect(i) end)
  navBtns[i] = b
end

-- ================= PANNELLO STATISTICHE (schede 1-5) =================
local statsPanel = CreateFrame("Frame", nil, content)
statsPanel:SetAllPoints(content)

local statsTitle = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statsTitle:SetPoint("TOPLEFT", statsPanel, "TOPLEFT", 12, -8)
statsTitle:SetTextColor(unpack(GUILD_GOLD))

local ssf = CreateFrame("ScrollFrame", "CounselorHubScroll", statsPanel, "UIPanelScrollFrameTemplate")
ssf:SetPoint("TOPLEFT", statsPanel, "TOPLEFT", 10, -32)
ssf:SetPoint("BOTTOMRIGHT", statsPanel, "BOTTOMRIGHT", -28, 10)
local scontent = CreateFrame("Frame", nil, ssf)
scontent:SetSize(430, 1); ssf:SetScrollChild(scontent)

-- liste "a righe" (zebra + header di sezione). Pool riusato tra i refresh.
local ROW_W = 428
local rowPool = {}
local function acquireRow(idx)
  local r = rowPool[idx]
  if not r then
    r = CreateFrame("Frame", nil, scontent)
    r:SetWidth(ROW_W)
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(r)
    r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.fs:SetPoint("TOPLEFT", r, "TOPLEFT", 10, -2); r.fs:SetWidth(ROW_W - 20)
    r.fs:SetJustifyH("LEFT"); r.fs:SetSpacing(1)
    r.fs:SetTextColor(unpack(GUILD_TEXT))
    rowPool[idx] = r
  end
  return r
end

local function renderBody(body)
  local y, n, zebra = -4, 0, 0
  for line in (tostring(body) .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*$") then
      y = y - 6
    else
      n = n + 1
      local r = acquireRow(n)
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", scontent, "TOPLEFT", 2, y); r:SetWidth(ROW_W)
      r.fs:SetText(line)
      local isHeader = line:find("^|cffffd100") and true or false
      local th = r.fs:GetStringHeight() or 12
      local h = math.floor(th + (isHeader and 10 or 6) + 0.5)
      r:SetHeight(h)
      if isHeader then
        r.bg:SetColorTexture(GUILD_GOLD[1], GUILD_GOLD[2], GUILD_GOLD[3], 0.12); zebra = 0
      elseif zebra % 2 == 1 then
        r.bg:SetColorTexture(1, 1, 1, 0.05)
      else
        r.bg:SetColorTexture(1, 1, 1, 0.0)
      end
      if not isHeader then zebra = zebra + 1 end
      r:Show(); y = y - h
    end
  end
  for j = n + 1, #rowPool do rowPool[j]:Hide() end
  scontent:SetHeight(math.max(10, -y + 8))
end

local function renderStats(tab)
  local t = STATS_TABS[tab] or STATS_TABS[1]
  statsTitle:SetText(t.label)
  local snap = curSnap()
  -- le schede 'live' (Cruscotto col roster di gioco) si disegnano anche senza snapshot del sito
  if t.live or type(snap) == "table" then renderBody(t.build(snap)) else renderBody(NO_DATA) end
  ssf:SetVerticalScroll(0)
end

-- ================= PANNELLO JEEVES =================
local jeevesPanel = CreateFrame("Frame", nil, content)
jeevesPanel:SetAllPoints(content); jeevesPanel:Hide()

local jscroll = CreateFrame("ScrollingMessageFrame", nil, jeevesPanel)
jscroll:SetPoint("TOPLEFT", jeevesPanel, "TOPLEFT", 12, -12)
jscroll:SetPoint("BOTTOMRIGHT", jeevesPanel, "BOTTOMRIGHT", -12, 76)
jscroll:SetFontObject(GameFontNormalSmall); jscroll:SetJustifyH("LEFT")
jscroll:SetFading(false); jscroll:SetMaxLines(250); jscroll:SetInsertMode("BOTTOM")

local function jsay(text)
  jscroll:AddMessage("|cffe8b85eJeeves:|r " .. text)
  if CounselorDB.jeeves_echo and IsInGuild() then
    SendChatMessage("Jeeves: " .. string.sub(text, 1, 230), "GUILD")
  end
end

local echo = CreateFrame("CheckButton", nil, jeevesPanel, "UICheckButtonTemplate")
echo:SetPoint("BOTTOMLEFT", jeevesPanel, "BOTTOMLEFT", 12, 46); echo:SetSize(22, 22)
echo.text = echo:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
echo.text:SetPoint("LEFT", echo, "RIGHT", 2, 0); echo.text:SetText("Eco in chat di gilda")
echo:SetScript("OnClick", function(self) CounselorDB.jeeves_echo = self:GetChecked() and true or false end)

local consent = CreateFrame("CheckButton", nil, jeevesPanel, "UICheckButtonTemplate")
consent:SetPoint("LEFT", echo.text, "RIGHT", 16, 0); consent:SetSize(22, 22)
consent.text = consent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
consent.text:SetPoint("LEFT", consent, "RIGHT", 2, 0); consent.text:SetText("Condividi chat con Jeeves")
consent:SetScript("OnClick", function(self) CounselorDB.chat_consent = self:GetChecked() and true or false end)

local jeb = CreateFrame("EditBox", nil, jeevesPanel, "InputBoxTemplate")
jeb:SetPoint("BOTTOMLEFT", jeevesPanel, "BOTTOMLEFT", 14, 14); jeb:SetSize(300, 22); jeb:SetAutoFocus(false)
jeb:SetScript("OnEnterPressed", function(self)
  local q = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if q ~= "" then
    jscroll:AddMessage("|cff9a6bffVoi:|r " .. q)
    CounselorDB.jeeves_queue = CounselorDB.jeeves_queue or {}
    CounselorDB.jeeves_queue[#CounselorDB.jeeves_queue + 1] = { t = time(), q = q }
    jsay("Ricevuto. Mediterò la risposta: comparirà sul portale (e qui al prossimo /reload).")
    self:SetText(""); refresh("jeeves_q")
  end
  self:ClearFocus()
end)

local jafor = CreateFrame("Button", nil, jeevesPanel, "UIPanelButtonTemplate")
jafor:SetSize(92, 22); jafor:SetPoint("LEFT", jeb, "RIGHT", 6, 0); jafor:SetText("Aforisma")
jafor:SetScript("OnClick", function() jsay(jpick("aforismi")) end)

-- ================= PANNELLO PROFILO (pairing + info personaggio) =================
local profilePanel = CreateFrame("Frame", nil, content)
profilePanel:SetAllPoints(content); profilePanel:Hide()

local pInfo = profilePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
pInfo:SetPoint("TOPLEFT", profilePanel, "TOPLEFT", 16, -16)
pInfo:SetPoint("RIGHT", profilePanel, "RIGHT", -16, 0); pInfo:SetJustifyH("LEFT")

local pLbl = profilePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
pLbl:SetPoint("TOPLEFT", profilePanel, "TOPLEFT", 16, -120)
pLbl:SetText("Pairing-code (dal sito wow.jeevesaicloud.com):")

local pEb = CreateFrame("EditBox", nil, profilePanel, "InputBoxTemplate")
pEb:SetSize(220, 24); pEb:SetPoint("TOPLEFT", profilePanel, "TOPLEFT", 18, -140); pEb:SetAutoFocus(false)
pEb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

local pSave = CreateFrame("Button", nil, profilePanel, "UIPanelButtonTemplate")
pSave:SetSize(90, 24); pSave:SetPoint("LEFT", pEb, "RIGHT", 8, 0); pSave:SetText("Salva")
pSave:SetScript("OnClick", function()
  local code = (pEb:GetText() or ""):gsub("%s+", "")
  CounselorDB.pairing_code = (code ~= "" and code) or nil
  refresh("pairing")
  print("|cff33ff99Counselor:|r pairing-code salvato. Fai /reload o esci: il companion lo userà al prossimo upload.")
end)

local pHint = profilePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
pHint:SetPoint("BOTTOMLEFT", profilePanel, "BOTTOMLEFT", 16, 14)
pHint:SetPoint("RIGHT", profilePanel, "RIGHT", -16, 0); pHint:SetJustifyH("LEFT")
pHint:SetText("I dati vengono caricati dal companion desktop al /reload o al logout (l'addon non ha rete).")

function CounselorUI.Update()
  local e = CounselorDB.envelope or {}
  local c = e.character or {}
  local played = c.played_total_s and string.format("%.1f h", c.played_total_s / 3600) or "n/d"
  pInfo:SetText(string.format(
    "Personaggio: |cffffd100%s|r (L%s %s)\nGilda: %s — grado: %s\nGear: %d pezzi · /played: %s · quest: %s\nUltima raccolta: %s",
    c.name or "?", tostring(c.level or "?"), c.class or "?",
    c.guild or "—", c.guild_rank or "—",
    e.gear and #e.gear or 0, played, tostring(e.quests_completed or "n/d"),
    CounselorDB.last_collected and date("%H:%M:%S", CounselorDB.last_collected) or "mai"))
  if CounselorDB.pairing_code then pEb:SetText(CounselorDB.pairing_code) end
end

-- ================= PANNELLO DANNI LIVE (C_DamageMeter) =================
local mTitle = meterPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
mTitle:SetPoint("TOP", meterPane, "TOP", 0, -8)
mTitle:SetText("|cffe8b85eDANNI (live)|r")

local DM_OK = (C_DamageMeter ~= nil and type(C_DamageMeter.GetCombatSessionFromType) == "function"
  and Enum ~= nil and Enum.DamageMeterType ~= nil and Enum.DamageMeterSessionType ~= nil)

-- OVERHEAL: supportato SOLO se il server lo espone. Verifica difensiva (pcall + nil-check),
-- nessun enum inventato usato senza guardia. Se non esiste, resta nil e nulla cambia a video.
local DM_OVERHEAL_TYPE = nil
if DM_OK then
  local okOH, oh = pcall(function()
    local e = Enum.DamageMeterType
    return e.Overhealing or e.OverHealing or e.Overheal
  end)
  if okOH and oh ~= nil then DM_OVERHEAL_TYPE = oh end
end

local function dmSecret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function dmNum(v)
  if v == nil or dmSecret(v) then return nil end
  return tonumber(v)
end
local function dmAbbrev(n)
  n = n or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6)
  elseif n >= 1e3 then return string.format("%.1fk", n / 1e3)
  else return string.format("%d", math.floor(n + 0.5)) end
end

local MET_MAX = 12
local meterMode = "dmg"   -- "dmg" | "heal"

local mMode = CreateFrame("Button", nil, meterPane, "UIPanelButtonTemplate")
mMode:SetSize(80, 20); mMode:SetPoint("TOPLEFT", meterPane, "TOPLEFT", 8, -28); mMode:SetText("Danno")
local mStat = meterPane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
mStat:SetPoint("TOPRIGHT", meterPane, "TOPRIGHT", -8, -32); mStat:SetJustifyH("RIGHT")

local meterBars = {}
local function dmBar(i)
  local b = meterBars[i]
  if not b then
    b = CreateFrame("StatusBar", nil, meterPane)
    b:SetSize(182, 18); b:SetStatusBarTexture(WHITE)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(1, 1, 1, 0.06)
    b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.left:SetPoint("LEFT", 5, 0); b.left:SetJustifyH("LEFT")
    b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.right:SetPoint("RIGHT", -5, 0); b.right:SetJustifyH("RIGHT")
    if i == 1 then b:SetPoint("TOPLEFT", meterPane, "TOPLEFT", 8, -54)
    else b:SetPoint("TOPLEFT", meterBars[i - 1], "BOTTOMLEFT", 0, -2) end
    meterBars[i] = b
  end
  return b
end

local function meterRefresh()
  if not DM_OK then
    for _, b in ipairs(meterBars) do b:Hide() end
    mStat:SetText("|cffff6666n/d|r")
    return
  end
  local mtype
  if meterMode == "heal" then mtype = Enum.DamageMeterType.HealingDone
  elseif meterMode == "overheal" and DM_OVERHEAL_TYPE then mtype = DM_OVERHEAL_TYPE
  else mtype = Enum.DamageMeterType.DamageDone end
  local stype = UnitAffectingCombat("player") and Enum.DamageMeterSessionType.Current or Enum.DamageMeterSessionType.Overall
  local ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, stype, mtype)
  if (not ok or not s or type(s.combatSources) ~= "table" or #s.combatSources == 0)
     and stype ~= Enum.DamageMeterSessionType.Overall then
    stype = Enum.DamageMeterSessionType.Overall
    ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, stype, mtype)
  end
  local srcs = (ok and s and type(s.combatSources) == "table") and s.combatSources or {}
  local dur
  if C_DamageMeter.GetSessionDurationSeconds then
    local okd, d = pcall(C_DamageMeter.GetSessionDurationSeconds, stype)
    if okd then dur = dmNum(d) end
  end
  local maxAmt = 1
  if srcs[1] then local m = dmNum(srcs[1].totalAmount); if m and m > 0 then maxAmt = m end end
  local n = math.min(#srcs, MET_MAX)
  for i = 1, n do
    local src = srcs[i]
    local b = dmBar(i)
    local amt = dmNum(src.totalAmount) or 0
    local ps  = dmNum(src.amountPerSecond)
    if src.name ~= nil then b.left:SetText(src.name) else b.left:SetText("?") end
    if ps then b.right:SetText(dmAbbrev(amt) .. "  " .. dmAbbrev(ps) .. "/s")
    else b.right:SetText(dmAbbrev(amt)) end
    b:SetMinMaxValues(0, maxAmt); b:SetValue(amt)
    local cls = src.classFilename
    if cls ~= nil and not dmSecret(cls) and type(cls) == "string" then
      local hex = classColorHex(cls)
      local r  = (tonumber(hex:sub(3, 4), 16) or 232) / 255
      local g  = (tonumber(hex:sub(5, 6), 16) or 184) / 255
      local bl = (tonumber(hex:sub(7, 8), 16) or 94)  / 255
      b:SetStatusBarColor(r, g, bl)
    else
      b:SetStatusBarColor(GUILD_GOLD[1], GUILD_GOLD[2], GUILD_GOLD[3])
    end
    b:Show()
  end
  for i = n + 1, #meterBars do meterBars[i]:Hide() end
  local lbl = (meterMode == "heal") and "Cure (HPS)"
    or (meterMode == "overheal") and "Overheal (OPS)"
    or "Danno (DPS)"
  if dur and dur > 0 then mStat:SetText(string.format("%s · %ds", lbl, math.floor(dur)))
  else mStat:SetText(lbl) end
end

mMode:SetScript("OnClick", function()
  -- Ciclo: Danno -> Cure -> Overheal (solo se il server lo espone) -> Danno
  if meterMode == "dmg" then meterMode = "heal"
  elseif meterMode == "heal" then meterMode = DM_OVERHEAL_TYPE and "overheal" or "dmg"
  else meterMode = "dmg" end
  mMode:SetText((meterMode == "heal") and "Cure"
    or (meterMode == "overheal") and "Overheal"
    or "Danno")
  meterRefresh()
end)

-- ---------- Rilevazione DPS del raid (capo raid → companion legge il file) ----------
local function raidSessionOpen()
  local s = CounselorDB.perf_sessions
  if type(s) ~= "table" then return nil end
  for i = #s, 1, -1 do
    if type(s[i]) == "table" and s[i].stop == nil then return s[i] end
  end
  return nil
end

local raidNote = meterPane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
raidNote:SetPoint("BOTTOMLEFT", meterPane, "BOTTOMLEFT", 8, 36)
raidNote:SetPoint("RIGHT", meterPane, "RIGHT", -8, 0); raidNote:SetJustifyH("LEFT")

local raidBtn = CreateFrame("Button", nil, meterPane, "UIPanelButtonTemplate")
raidBtn:SetSize(182, 22); raidBtn:SetPoint("BOTTOMLEFT", meterPane, "BOTTOMLEFT", 8, 10)
raidBtn:SetText("Avvia rilevazione raid")

local function raidMeterUpdate()
  local canLead = IsInRaid() and UnitIsGroupLeader("player") and true or false
  local open = raidSessionOpen()
  raidBtn:SetText(open and "Ferma rilevazione raid" or "Avvia rilevazione raid")
  local enabled = canLead or open
  if enabled then raidBtn:Enable() else raidBtn:Disable() end
  if open then
    raidNote:SetText("|cff66ff66Rilevazione raid ATTIVA — il companion registra il DPS del raid.|r")
  elseif canLead then
    raidNote:SetText("Avvia per registrare il DPS dell'intero raid (via companion).")
  else
    raidNote:SetText("|cffaaaaaaRilevazione raid: solo il capo raid.|r")
  end
end

local function raidMeterStart()
  if raidSessionOpen() then raidMeterUpdate(); return end
  CounselorDB.perf_sessions = CounselorDB.perf_sessions or {}
  local me = UnitName("player")
  CounselorDB.perf_sessions[#CounselorDB.perf_sessions + 1] = { id = me .. "-" .. time(), start = time(), stop = nil, by = me }
  local logging = false
  if pcall(LoggingCombat, true) then
    local ok, st = pcall(LoggingCombat)
    if ok then logging = st and true or false end
  end
  if logging then
    print("|cff33ff99Counselor:|r rilevazione raid ATTIVA — il companion registrera' il DPS del raid.")
  else
    print("|cff33ff99Counselor:|r rilevazione raid ATTIVA. |cffffff00Attiva /combatlog manualmente|r (logging su file non attivabile dall'addon).")
  end
  refresh("raidmeter"); raidMeterUpdate()
end

local function raidMeterStop()
  local open = raidSessionOpen()
  if not open then raidMeterUpdate(); return end
  open.stop = time()
  pcall(LoggingCombat, false)
  print("|cff33ff99Counselor:|r rilevazione raid terminata.")
  refresh("raidmeter"); raidMeterUpdate()
end

raidBtn:SetScript("OnClick", function()
  if raidSessionOpen() then raidMeterStop()
  elseif IsInRaid() and UnitIsGroupLeader("player") then raidMeterStart()
  else print("|cff33ff99Counselor:|r solo il capo raid (dentro un raid) puo' avviare la rilevazione."); raidMeterUpdate() end
end)

-- ================= NAVIGAZIONE =================
local curNav = 1
function hubSelect(i)
  curNav = i
  local nav = NAV[i]
  for j, b in ipairs(navBtns) do
    local on = (j == i)
    b._active = on
    b.fs:SetTextColor(on and GUILD_GOLD[1] or GUILD_DIM[1], on and GUILD_GOLD[2] or GUILD_DIM[2], on and GUILD_GOLD[3] or GUILD_DIM[3])
    if on then b.sel:Show(); b.acc:Show() else b.sel:Hide(); b.acc:Hide() end
  end
  statsPanel:Hide(); jeevesPanel:Hide(); profilePanel:Hide()
  if nav.kind == "stats" then
    statsPanel:Show(); renderStats(nav.tab)
  elseif nav.kind == "jeeves" then
    jeevesPanel:Show()
    echo:SetChecked(CounselorDB.jeeves_echo and true or false)
    consent:SetChecked(CounselorDB.chat_consent and true or false)
    jsay(jpick("greet"))
  else
    profilePanel:Show(); CounselorUI.Update()
  end
end

local function hubStatus()
  local snap = curSnap()
  if type(snap) == "table" and snap.updated_at then
    statusFS:SetText("dati aggiornati alle " .. date("%H:%M del %d/%m", snap.updated_at))
  else
    statusFS:SetText("|cffe8b85eIn attesa dei dati della gilda (app Companion) — compaiono al prossimo accesso.|r")
  end
end

-- ================= APERTURA / TOGGLE =================
local function hubOpen(navIndex)
  refresh("open"); hubStatus()
  if IsInGuild() then                                   -- richiedi il roster di gioco per "Gilda ORA"
    if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster)
    elseif GuildRoster then pcall(GuildRoster) end
  end
  hubSelect(navIndex or curNav or 1)
  meterRefresh()
  hub:Show()
end

function CounselorToggleHub()
  if hub:IsShown() then hub:Hide() else hubOpen() end
end
function CounselorToggleStats()
  if hub:IsShown() and NAV[curNav] and NAV[curNav].kind == "stats" then hub:Hide() else hubOpen(1) end
end
function CounselorToggleJeeves()
  if hub:IsShown() and NAV[curNav] and NAV[curNav].kind == "jeeves" then hub:Hide() else hubOpen(6) end
end
function CounselorToggleMeter()
  -- il meter e' sempre nel pannello destro dell'hub: apre l'hub e aggiorna
  if hub:IsShown() then meterRefresh() else hubOpen() end
end
CounselorStatsSelect = function(i) hubOpen(i) end   -- retrocompat

hub:SetScript("OnShow", function() hubStatus(); meterRefresh() end)

-- aggiornamento live del meter + stato pulsante raid
-- ---------- HARVEST per-giocatore (fine combattimento, nomi PLAIN) ----------
-- A PLAYER_REGEN_ENABLED siamo FUORI combat: i .name tornano PLAIN e sono
-- serializzabili. Leggiamo la sessione Overall (DamageDone + HealingDone),
-- aggreghiamo per giocatore e accodiamo un record in CounselorDB.perf_live.
local PERF_LIVE_MAX = 30
local function perfLiveHarvest()
  if not DM_OK then return end
  local overall = Enum.DamageMeterSessionType.Overall

  -- durata encounter
  local dur
  if C_DamageMeter.GetSessionDurationSeconds then
    local okd, d = pcall(C_DamageMeter.GetSessionDurationSeconds, overall)
    if okd then dur = dmNum(d) end
  end
  dur = dur and math.floor(dur) or 0
  if dur < 5 then return end                      -- encounter insignificante

  local byName, order = {}, {}                    -- fusione per NOME (plain fuori combat)
  local function plainCls(src)
    local cls = src.classFilename
    if cls ~= nil and not dmSecret(cls) and type(cls) == "string" then return cls end
    return nil
  end
  local function getRec(nm, cls)
    local rec = byName[nm]
    if not rec then
      rec = { name = nm, dmg = 0, dps = 0, heal = 0, hps = 0, cls = cls }
      byName[nm] = rec; order[#order + 1] = nm
    elseif cls and not rec.cls then rec.cls = cls end
    return rec
  end

  -- DANNO
  local anyDmg = false
  local okD, sD = pcall(C_DamageMeter.GetCombatSessionFromType, overall, Enum.DamageMeterType.DamageDone)
  if okD and sD and type(sD.combatSources) == "table" then
    for _, src in ipairs(sD.combatSources) do
      local nm = src.name
      if nm ~= nil and not dmSecret(nm) and type(nm) == "string" then   -- salta se ancora secret
        local rec = getRec(nm, plainCls(src))
        rec.dmg = dmNum(src.totalAmount) or 0
        rec.dps = dmNum(src.amountPerSecond) or 0
        if rec.dmg > 0 then anyDmg = true end
      end
    end
  end
  if not anyDmg then return end                   -- nessun danno -> scarta

  -- CURE (fuse per nome sulle entry esistenti; healer puri -> nuova entry)
  local okH, sH = pcall(C_DamageMeter.GetCombatSessionFromType, overall, Enum.DamageMeterType.HealingDone)
  if okH and sH and type(sH.combatSources) == "table" then
    for _, src in ipairs(sH.combatSources) do
      local nm = src.name
      if nm ~= nil and not dmSecret(nm) and type(nm) == "string" then
        local rec = getRec(nm, plainCls(src))
        rec.heal = dmNum(src.totalAmount) or 0
        rec.hps  = dmNum(src.amountPerSecond) or 0
      end
    end
  end

  local players = {}
  for _, nm in ipairs(order) do players[#players + 1] = byName[nm] end
  if #players == 0 then return end

  local zone = (GetRealZoneText and GetRealZoneText()) or nil
  if zone == "" then zone = nil end

  CounselorDB.perf_live = CounselorDB.perf_live or {}
  local buf = CounselorDB.perf_live
  buf[#buf + 1] = {
    ts = time(),
    zone = zone,
    dur = dur,
    by = UnitName("player"),
    players = players,
  }
  while #buf > PERF_LIVE_MAX do table.remove(buf, 1) end
end

local meterEv = CreateFrame("Frame")
if DM_OK then
  meterEv:RegisterEvent("DAMAGE_METER_CURRENT_SESSION_UPDATED")
  meterEv:RegisterEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED")
  meterEv:RegisterEvent("DAMAGE_METER_RESET")
end
meterEv:RegisterEvent("PLAYER_REGEN_DISABLED")
meterEv:RegisterEvent("PLAYER_REGEN_ENABLED")
meterEv:RegisterEvent("GROUP_ROSTER_UPDATE")
meterEv:RegisterEvent("PARTY_LEADER_CHANGED")
meterEv:RegisterEvent("PLAYER_ENTERING_WORLD")
meterEv:RegisterEvent("GUILD_ROSTER_UPDATE")       -- per aggiornare "Gilda ORA" in diretta
meterEv:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_ENABLED" then
    -- fine combat: nomi PLAIN -> raccogli il riepilogo per giocatore e riscrivi il payload
    local ok = pcall(perfLiveHarvest)
    if ok then refresh("perflive") end
  end
  if not hub:IsShown() then return end
  meterRefresh(); raidMeterUpdate()
  local nav = NAV[curNav]                           -- se e' aperta una scheda 'live', riaggiornala
  if nav and nav.kind == "stats" then
    local t = STATS_TABS[nav.tab]
    if t and t.live then renderStats(nav.tab) end
  end
end)
raidMeterUpdate()

-- ---------- icona minimappa ----------
CounselorDB.minimap = CounselorDB.minimap or { angle = 210 }
local mbtn = CreateFrame("Button", "CounselorMinimapButton", Minimap)
mbtn:SetSize(31, 31); mbtn:SetFrameStrata("MEDIUM"); mbtn:SetFrameLevel(8)
mbtn:RegisterForClicks("LeftButtonUp", "RightButtonUp"); mbtn:RegisterForDrag("LeftButton")
local mover = mbtn:CreateTexture(nil, "OVERLAY")
mover:SetSize(53, 53); mover:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); mover:SetPoint("TOPLEFT")
local micon = mbtn:CreateTexture(nil, "BACKGROUND")
micon:SetSize(20, 20); micon:SetTexture("Interface\\Icons\\INV_Misc_Book_09"); micon:SetPoint("TOPLEFT", 7, -6)
local function mupdate()
  local a = math.rad(CounselorDB.minimap.angle or 210)
  mbtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
end
mbtn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function()
  local mx, my = Minimap:GetCenter(); local px, py = GetCursorPosition(); local s = Minimap:GetEffectiveScale()
  local atan2 = math.atan2 or math.atan
  CounselorDB.minimap.angle = math.deg(atan2(py / s - my, px / s - mx)); mupdate()
end) end)
mbtn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mbtn:SetScript("OnClick", function(_, button)
  if IsControlKeyDown() then CounselorToggleHub()
  elseif IsShiftKeyDown() then hubOpen(1)
  elseif button == "RightButton" then hubOpen(7)        -- clic dx → Profilo
  else hubOpen(6) end                                   -- clic sx → Jeeves
end)
mbtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("Counselor · Jeeves")
  GameTooltip:AddLine("Clic sx: Jeeves · Clic dx: Profilo", 1, 1, 1)
  GameTooltip:AddLine("Shift: statistiche · Ctrl: apri/chiudi hub", 1, 1, 1)
  GameTooltip:Show()
end)
mbtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
mupdate()

-- slash
SLASH_COUNSELOR1 = "/counselor"; SLASH_COUNSELOR2 = "/co"
SlashCmdList["COUNSELOR"] = function(msg)
  msg = msg or ""
  local pcode = msg:match("^%s*[Pp][Aa][Ii][Rr]%s+(%S+)")
  if pcode then
    pcode = pcode:gsub("%s+", ""):upper()
    CounselorDB.pairing_code = pcode
    refresh("pairing")
    print("|cff33ff99Counselor:|r pairing-code impostato (" .. pcode .. "). Ora fai |cffffff00/reload|r o esci: il companion lo userà.")
    return
  end
  local m = msg:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if m == "sync" then refresh("manual"); print("|cff33ff99Counselor:|r dati raccolti.")
  elseif m == "jeeves" or m == "j" then hubOpen(6)
  elseif m == "stats" or m == "s" or m == "statistiche" then hubOpen(1)
  elseif m == "meter" or m == "dps" or m == "m" then CounselorToggleMeter()
  elseif m == "profilo" or m == "profile" or m == "p" then hubOpen(7)
  else CounselorToggleHub() end
end
SLASH_JEEVES1 = "/jeeves"
SlashCmdList["JEEVES"] = function() hubOpen(6) end

print("|cff33ff99Counselor|r caricato. Icona minimappa · /co hub · /co stats · /co meter · /jeeves.")
