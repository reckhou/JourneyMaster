-- JourneyProbe: the throwaway Phase 0 probe for JourneyMaster.
-- It only watches. It records what Forever's add-on API lets an add-on see into JourneyProbeDB, which the game writes
-- at /reload or logout. scripts/probe_report.py turns that file into the results for docs/investigations/.
-- It also turns chat logging on at login (LoggingChat(true)), as the real add-on will, so check 7 and check 8 have a
-- chat log to compare with.
--
-- Abbreviations: SV = SavedVariables. NPC = non-player character. CLEU = COMBAT_LOG_EVENT_UNFILTERED, the combat log
-- event. API = application programming interface. GUID = globally unique identifier of a game object.
--
-- Commands: /jmp (status), /jmp mark <text>, /jmp api, /jmp fill <n>, /jmp reset.

JourneyProbe = JourneyProbe or {}
local P = JourneyProbe

local CAP = 30000      -- most entries kept; later ones are counted in db.dropped
local SAMPLE = 80      -- characters of text kept from any one line
local CLEU_KEYS = 80   -- most distinct combat log sub-event counters

P.VERSION = "0.1.0"

-- Chat events whose readability and payload check 4 and check 6 need. Whispers from players are left out on purpose,
-- as the real add-on will never record them. NPC whispers are kept: they are NPC speech.
P.CHAT_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE",
    "CHAT_MSG_MONSTER_PARTY", "CHAT_MSG_MONSTER_WHISPER",
    "CHAT_MSG_RAID_BOSS_EMOTE", "CHAT_MSG_RAID_BOSS_WHISPER",
}

-- Chat events that carry deaths and kills as text (check 3).
P.DEATH_TEXT_EVENTS = {
    "CHAT_MSG_COMBAT_HOSTILE_DEATH", "CHAT_MSG_COMBAT_FRIENDLY_DEATH", "CHAT_MSG_COMBAT_XP_GAIN",
}

-- Game events for deaths, bosses, levels, quests and zones (checks 2, 3, 7).
P.GAME_EVENTS = {
    "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "BOSS_KILL", "ENCOUNTER_START", "ENCOUNTER_END",
    "PLAYER_LEVEL_UP",
    "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_GREETING", "GOSSIP_SHOW",
    "QUEST_ACCEPTED", "QUEST_TURNED_IN",
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "PLAYER_LOGOUT",
}

-- Quest text getters (check 2). Forever's own quest window calls these; the generated API documentation does not list them.
P.QUEST_GETTERS = {
    "GetTitleText", "GetGreetingText", "GetQuestText", "GetProgressText", "GetObjectiveText", "GetRewardText",
}

-- Functions whose existence the probe reports once per login (checks 1 to 3, 6, 8, 10).
P.API_NAMES = {
    "GetTitleText", "GetGreetingText", "GetQuestText", "GetProgressText", "GetObjectiveText", "GetRewardText",
    "LoggingChat", "issecretvalue", "canaccessvalue", "canaccessallvalues", "GetMinimapShape",
    "CombatLogGetCurrentEventInfo", "IsInInstance", "GetInstanceInfo", "GetServerTime", "UnitGUID",
    "C_ChatInfo.InChatMessagingLockdown", "C_Secrets.HasSecretRestrictions", "C_RestrictedActions.IsAddOnRestrictionActive",
    "C_DeathRecap.GetRecapLink", "C_DeathRecap.GetRecapEvents", "C_GossipInfo.GetText",
    "C_QuestLog.GetTitleForQuestID", "C_Map.GetBestMapForUnit",
}

local db, frame, lastInstanceType, lastHit

-- ---------------------------------------------------------------------------------------------------------------------
-- Pure helpers (no game calls beyond the optional secret-value checks), covered by tests/probe_harness.lua

-- True when a value may be read and compared by add-on code. Secret values (Forever's chat lockdown) are not readable.
function P.Readable(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return false end
    if canaccessvalue and not canaccessvalue(v) then return false end
    return true
end

-- A short, readable sample of a string, or nil when the value is secret or not a string.
function P.Sample(v)
    if type(v) ~= "string" or not P.Readable(v) then return nil end
    local s = v:gsub("[\r\n]+", " ")
    if #s > SAMPLE then s = s:sub(1, SAMPLE) .. "..." end
    return s
end

-- The kind of a GUID ("Player", "Creature", ...), or nil when it is secret or empty.
function P.GuidKind(guid)
    if type(guid) ~= "string" or not P.Readable(guid) then return nil end
    return guid:match("^(%a+)%-")
end

-- A counter name for the chat and event tallies.
function P.CountKey(ev, instanceType, lockdown, state)
    return table.concat({ ev, instanceType or "?", lockdown and "lock" or "open", state }, "|")
end

-- Time stamps in the chat log's own style ("11/8 21:15:03"), so entries can be lined up with WoWChatLog.txt by eye.
function P.Stamp(epoch)
    local e = epoch or time()
    return tonumber(date("%m", e)) .. "/" .. tonumber(date("%d", e)) .. " " .. date("%H:%M:%S", e)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Recording

local function ensureDb()
    JourneyProbeDB = JourneyProbeDB or {}
    db = JourneyProbeDB
    db.log = db.log or {}
    db.counts = db.counts or {}
    db.loads = db.loads or 0
    db.sessions = db.sessions or {}
    db.dropped = db.dropped or 0
    return db
end

local function context()
    local inInstance, itype = false, "?"
    if IsInInstance then inInstance, itype = IsInInstance() end
    local lock
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, v = pcall(C_ChatInfo.InChatMessagingLockdown)
        lock = ok and v or nil
    end
    return itype or "?", lock
end

function P.Count(key)
    ensureDb()
    db.counts[key] = (db.counts[key] or 0) + 1
end

-- Appends one entry. t is the epoch second, d the same moment in chat-log style.
function P.Record(ev, fields)
    ensureDb()
    if #db.log >= CAP then
        db.dropped = db.dropped + 1
        return
    end
    local itype, lock = context()
    local entry = fields or {}
    entry.ev = ev
    entry.t = time()
    entry.d = P.Stamp(entry.t)
    entry.inst = itype
    entry.lock = lock and true or false
    db.log[#db.log + 1] = entry
    return entry
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return false, "missing" end
    return pcall(fn, ...)
end

local function resolve(path)
    local obj = _G
    for part in path:gmatch("[^.]+") do
        if type(obj) ~= "table" then return nil end
        obj = obj[part]
    end
    return obj
end

local function zoneFields()
    local f = {}
    if GetRealZoneText then f.zone = P.Sample(GetRealZoneText()) end
    if GetSubZoneText then f.sub = P.Sample(GetSubZoneText()) end
    return f
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Handlers

local function onChat(event, text, speaker, _, _, speaker2, _, _, _, _, _, _, guid)
    local itype, lock = context()
    local textOk = P.Readable(text)
    local speakerOk = P.Readable(speaker)
    P.Count(P.CountKey(event, itype, lock, textOk and "text" or "secret"))
    -- Every line outside lockdown is kept as a sample, and the first 25 of every other combination are kept too, so
    -- the report can show what the payload looks like without the table growing without limit.
    local n = db.counts[P.CountKey(event, itype, lock, textOk and "text" or "secret")]
    if textOk and not lock and n > 200 then return end
    if n > 25 then return end
    P.Record("chat", {
        chat = event,
        text = P.Sample(text), textOk = textOk,
        who = P.Sample(speaker), whoOk = speakerOk,
        who2 = P.Sample(speaker2),
        guidKind = P.GuidKind(guid), guidOk = P.Readable(guid),
    })
end

local function onDeathText(event, text)
    local itype, lock = context()
    P.Count(P.CountKey(event, itype, lock, P.Readable(text) and "text" or "secret"))
    local n = db.counts[P.CountKey(event, itype, lock, P.Readable(text) and "text" or "secret")]
    if n > 60 then return end
    P.Record("deathtext", { chat = event, text = P.Sample(text) })
end

local function questFields(event)
    local f = { quest = event }
    f.title = P.Sample(select(2, safeCall(GetTitleText)))
    for _, name in ipairs(P.QUEST_GETTERS) do
        local ok, value = safeCall(_G[name])
        local info = { ok = ok and true or false, type = type(value) }
        if ok and type(value) == "string" then
            info.len = P.Readable(value) and #value or nil
            info.sample = P.Sample(value)
        elseif not ok then
            info.err = tostring(value):sub(1, 80)
        end
        f[name] = info
    end
    if UnitName then
        f.questnpc = P.Sample(select(2, safeCall(UnitName, "questnpc")))
        f.npc = P.Sample(select(2, safeCall(UnitName, "npc")))
    end
    if event == "GOSSIP_SHOW" then
        local ok, text = safeCall(resolve("C_GossipInfo.GetText"))
        f.gossip = ok and P.Sample(text) or nil
        f.gossipLen = (ok and type(text) == "string" and P.Readable(text)) and #text or nil
    end
    return f
end

local function onCleu()
    if not CombatLogGetCurrentEventInfo then return end
    local ok, ts, sub, _, srcGuid, srcName, _, _, dstGuid, dstName, _, _, a1, a2 = pcall(CombatLogGetCurrentEventInfo)
    if not ok then return end
    ensureDb()
    db.cleuFired = (db.cleuFired or 0) + 1
    if P.Readable(sub) then
        local key = "CLEU|" .. tostring(sub)
        if db.counts[key] or (db.cleuKeys or 0) < CLEU_KEYS then
            if not db.counts[key] then db.cleuKeys = (db.cleuKeys or 0) + 1 end
            db.counts[key] = (db.counts[key] or 0) + 1
        end
        local playerGuid = UnitGUID and UnitGUID("player")
        if dstGuid and playerGuid and P.Readable(dstGuid) and dstGuid == playerGuid
            and (sub == "SWING_DAMAGE" or sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "ENVIRONMENTAL_DAMAGE") then
            lastHit = { src = P.Sample(srcName), sub = sub, spell = (sub ~= "SWING_DAMAGE") and a2 or nil, t = time() }
        end
        if sub == "UNIT_DIED" or sub == "PARTY_KILL" then
            if (db.counts["CLEUSAMPLE|" .. sub] or 0) < 40 then
                db.counts["CLEUSAMPLE|" .. sub] = (db.counts["CLEUSAMPLE|" .. sub] or 0) + 1
                P.Record("cleu", { sub = sub, src = P.Sample(srcName), dst = P.Sample(dstName), dstKind = P.GuidKind(dstGuid) })
            end
        end
    end
end

local function onInstanceMaybeChanged(event, a, b)
    local itype, lock = context()
    local fields = zoneFields()
    fields.game = event
    fields.isLogin, fields.isReload = a, b
    if GetInstanceInfo then
        local ok, name, kind, difficulty, _, _, _, _, instanceId = pcall(GetInstanceInfo)
        if ok then
            fields.instName, fields.instKind, fields.difficulty, fields.instanceId = P.Sample(name), kind, difficulty, instanceId
        end
    end
    -- Every login, reload and zone event is logged; the entry for a change of instance type is marked, because that is
    -- the moment check 7 compares with the chat log.
    fields.changed = (itype ~= lastInstanceType)
    lastInstanceType = itype
    P.Record("zone", fields)
end

local function onEvent(_, event, ...)
    ensureDb()
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        onInstanceMaybeChanged(event, ...)
    elseif event == "PLAYER_DEAD" then
        local f = zoneFields()
        f.lastHit = lastHit
        local recap = resolve("C_DeathRecap.GetRecapEvents")
        if recap then
            local ok, events = safeCall(recap, 1)
            f.recapOk = ok and true or false
            f.recapCount = (ok and type(events) == "table") and #events or nil
        end
        local link = resolve("C_DeathRecap.GetRecapLink")
        if link then
            local ok, value = safeCall(link, 1)
            f.recapLink = (ok and P.Sample(value)) or nil
        end
        P.Record("death", f)
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        P.Record("alive", { game = event })
    elseif event == "BOSS_KILL" or event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
        local id, name, difficulty, size, success = ...
        local f = zoneFields()
        f.game, f.id, f.name, f.difficulty, f.size, f.success = event, id, P.Sample(name), difficulty, size, success
        P.Record("boss", f)
    elseif event == "PLAYER_LEVEL_UP" then
        P.Record("level", { level = (...) })
    elseif event == "QUEST_DETAIL" or event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE"
        or event == "QUEST_GREETING" or event == "GOSSIP_SHOW" then
        P.Record("quest", questFields(event))
    elseif event == "QUEST_ACCEPTED" then
        local a, b = ...
        local f = { game = event, a = a, b = b }
        local fn = resolve("C_QuestLog.GetTitleForQuestID")
        if fn then f.title = P.Sample(select(2, safeCall(fn, b or a))) end
        P.Record("questlog", f)
    elseif event == "QUEST_TURNED_IN" then
        local id, xp, money = ...
        P.Record("questlog", { game = event, id = id, xp = xp, money = money })
    elseif event == "PLAYER_LOGOUT" then
        db.sessions[#db.sessions + 1] = { logout = time(), stamp = P.Stamp(), entries = #db.log }
    else
        -- chat events
        local handler = P.chatSet and P.chatSet[event]
        if handler == "chat" then
            onChat(event, ...)
        elseif handler == "death" then
            onDeathText(event, ...)
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            onCleu()
        end
    end
end
P.OnEvent = onEvent

-- ---------------------------------------------------------------------------------------------------------------------
-- Login report: SV read-back (check 1), API existence, chat logging (check 8)

function P.OnLogin()
    ensureDb()
    local previousLoads = db.loads
    db.loads = db.loads + 1
    local f = { previousLoads = previousLoads, loads = db.loads }
    if GetBuildInfo then
        local version, build, buildDate, toc = GetBuildInfo()
        f.version, f.build, f.buildDate, f.toc = version, build, buildDate, toc
    end
    db.api = {}
    for _, name in ipairs(P.API_NAMES) do
        local obj = resolve(name)
        db.api[name] = obj == nil and "missing" or type(obj)
    end
    if LoggingChat then
        local ok, was = safeCall(LoggingChat)
        f.chatLoggingWas = ok and was or nil
        safeCall(LoggingChat, true)
        local ok2, now = safeCall(LoggingChat)
        f.chatLoggingNow = ok2 and now or nil
    end
    -- Whether a counter written last session survived the file round trip.
    f.countsKeysAtLogin = 0
    for _ in pairs(db.counts) do f.countsKeysAtLogin = f.countsKeysAtLogin + 1 end
    f.logEntriesAtLogin = #db.log
    P.Record("login", f)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The minimap button (check 10). It is built by hand, as the real add-on's will be, and does nothing but print the status.

local function minimapAngle()
    return tonumber(db and db.minimapAngle) or 200
end

function P.MinimapOffset(angle, half)
    local rad = math.rad(angle)
    return math.cos(rad) * (half + 5), math.sin(rad) * (half + 5)
end

function P.CreateMinimapButton()
    ensureDb()
    local f = { attempted = true }
    if not CreateFrame or not Minimap then
        f.created, f.err = false, "no CreateFrame or Minimap"
        db.minimapResult = f
        return
    end
    local ok, err = pcall(function()
        local button = CreateFrame("Button", "JourneyProbeMinimapButton", Minimap)
        button:SetSize(31, 31)
        button:SetFrameStrata("MEDIUM")
        button:SetFrameLevel(8)
        button:RegisterForClicks("LeftButtonUp")
        button:RegisterForDrag("LeftButton")
        local icon = button:CreateTexture(nil, "BACKGROUND")
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER", 0, 1)
        icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
        local border = button:CreateTexture(nil, "OVERLAY")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        local function place()
            local half = (Minimap:GetWidth() or 140) / 2
            local x, y = P.MinimapOffset(minimapAngle(), half)
            button:ClearAllPoints()
            button:SetPoint("CENTER", Minimap, "CENTER", x, y)
        end
        button:SetScript("OnClick", function() P.PrintStatus() end)
        button:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local scale = Minimap:GetEffectiveScale()
                local cx, cy = Minimap:GetCenter()
                local mx, my = GetCursorPosition()
                db.minimapAngle = math.deg(math.atan2(my / scale - cy, mx / scale - cx)) % 360
                place()
            end)
        end)
        button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        place()
        P.button = button
    end)
    f.created = ok and true or false
    f.err = (not ok) and tostring(err):sub(1, 120) or nil
    f.angleAtCreation = minimapAngle()
    f.shape = GetMinimapShape and GetMinimapShape() or nil
    db.minimapResult = f
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Slash commands

function P.PrintStatus()
    ensureDb()
    local out = (DEFAULT_CHAT_FRAME and function(s) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffJourneyProbe|r " .. s) end) or print
    local keys = 0
    for _ in pairs(db.counts) do keys = keys + 1 end
    out(string.format("v%s, loads %d, %d entries (cap %d, dropped %d), %d counters, CLEU fired %d, minimap angle %d",
        P.VERSION, db.loads, #db.log, CAP, db.dropped, keys, db.cleuFired or 0, minimapAngle()))
    out("Play normally, then /reload or log out. /jmp mark <text> adds a note; /jmp fill <n> grows the file; /jmp reset wipes it.")
end

function P.Slash(msg)
    ensureDb()
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "mark" then
        P.Record("mark", { note = rest ~= "" and rest or "(no text)" })
        P.PrintStatus()
    elseif cmd == "api" then
        local line = {}
        for _, name in ipairs(P.API_NAMES) do line[#line + 1] = name .. "=" .. tostring(db.api and db.api[name]) end
        for i = 1, #line, 4 do
            local chunk = table.concat(line, ", ", i, math.min(i + 3, #line))
            if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(chunk) else print(chunk) end
        end
    elseif cmd == "fill" then
        -- Check 5: grows the file with made-up entries of a size like the real ones, so the pause at logout can be timed.
        local n = tonumber(rest) or 0
        db.fill = {}
        for i = 1, n do
            db.fill[i] = { t = i, d = "11/12 00:00:00", ev = "chat", chat = "CHAT_MSG_SAY",
                text = "Filler entry number " .. i .. " with a sentence about as long as a line of real speech.",
                who = "Somebody", zone = "Elwynn Forest", sub = "Goldshire" }
        end
        P.Record("mark", { note = "filled " .. n .. " entries for the size check" })
        P.PrintStatus()
    elseif cmd == "reset" then
        JourneyProbeDB = nil
        ensureDb()
        db.loads = 1
        P.PrintStatus()
    else
        P.PrintStatus()
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Start-up (skipped by the offline harness, which has no CreateFrame)

function P.Start()
    if not CreateFrame then return end
    P.chatSet = {}
    frame = CreateFrame("Frame")
    for _, e in ipairs(P.CHAT_EVENTS) do
        if pcall(frame.RegisterEvent, frame, e) then P.chatSet[e] = "chat" end
    end
    for _, e in ipairs(P.DEATH_TEXT_EVENTS) do
        if pcall(frame.RegisterEvent, frame, e) then P.chatSet[e] = "death" end
    end
    P.registered = {}
    for _, e in ipairs(P.GAME_EVENTS) do
        P.registered[e] = pcall(frame.RegisterEvent, frame, e)
    end
    -- The combat log is not registered. Forever marks COMBAT_LOG_EVENT_UNFILTERED "HasRestrictions" in its API
    -- documentation, and RegisterEvent on it from add-on code raises the "blocked from an action only available to the
    -- Blizzard UI" popup (seen in game on 12 November 2026). pcall does not stop that popup. This answers the plan's open
    -- question: the combat log does not reach add-ons, so onCleu below stays unused and deaths carry no lastHit.
    P.registered.COMBAT_LOG_EVENT_UNFILTERED = "blocked (restricted event, add-on action forbidden)"
    frame:RegisterEvent("ADDON_LOADED")
    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "ADDON_LOADED" then
            if (...) == "JourneyProbe" then
                ensureDb()
                P.OnLogin()
                db.registered = P.registered
                db.chatRegistered = {}
                for e in pairs(P.chatSet) do db.chatRegistered[e] = true end
                P.CreateMinimapButton()
                self:UnregisterEvent("ADDON_LOADED")
            end
            return
        end
        onEvent(self, event, ...)
    end)
    SLASH_JOURNEYPROBE1 = "/jmp"
    SlashCmdList["JOURNEYPROBE"] = P.Slash
end

P.Start()
