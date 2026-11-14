-- JourneyMaster recorder: listens for game events and appends entries to the character's table in JourneyMasterDB
-- (see Core.lua for the entry format). It never changes anything in the game, apart from turning chat logging on at
-- login so the app can fill dungeons and raids from WoWChatLog.txt, and taking a screenshot at milestones when that
-- setting is on.
--
-- Abbreviations: SV = SavedVariables. NPC = non-player character. GUID = the game's unique identifier for a unit.
local _, ns = ...
local Core = ns.Core
local Rec = {}
ns.Recorder = Rec

local char                 -- the current character's saved table
local recent = {}          -- NPC lines seen lately (not saved), for Core.SeenRecently
local pendingDetail = {}   -- quest title -> { text, obj, giver, t } from the quest window, until the quest is accepted
local lastDetail           -- the newest of those
local pendingComplete      -- { title, giver, reward, t } from the hand-in window, until QUEST_TURNED_IN
local lastBoss             -- { name, t }: BOSS_KILL and ENCOUNTER_END both fire for one kill
local quietUntil = 0       -- gear changes during the first seconds after login are the game loading, not the player
local recapUsed = 0        -- the newest death recap already read this login

Rec.state = function() return { char = char, pendingDetail = pendingDetail, pendingComplete = pendingComplete } end

-- Helpers -------------------------------------------------------------------------------------------------------

-- True when add-on code may read a value. Inside dungeons and raids Forever hides chat as "secret" values.
function Rec.Readable(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return false end
    if canaccessvalue and not canaccessvalue(v) then return false end
    return true
end
local Readable = Rec.Readable

local function now() return time() end

-- Errors ---------------------------------------------------------------------------------------------------------
-- An error must never stop the recorder, and must never pass unseen. The game hides Lua errors unless the player has
-- turned script errors on, so each new error is said in chat once; repeats are only counted. /jm errors lists them.
Rec.errors = {}            -- in the order first seen: { where, msg, count }
local errorIndex = {}      -- where .. msg -> the entry in Rec.errors
local ERRORS_MAX = 50

function Rec.Error(where, err)
    local msg = tostring(err)
    local key = tostring(where) .. "\0" .. msg
    local e = errorIndex[key]
    if e then
        e.count = e.count + 1
        return
    end
    if #Rec.errors >= ERRORS_MAX then
        Rec.errors[ERRORS_MAX].count = Rec.errors[ERRORS_MAX].count + 1
        return
    end
    e = { where = where, msg = msg, count = 1 }
    errorIndex[key] = e
    Rec.errors[#Rec.errors + 1] = e
    local line = "error in " .. tostring(where) .. " (part of the record may be missing; /jm errors lists every error): " .. msg
    if ns.Say then ns.Say(line) else print("JourneyMaster: " .. line) end
end

-- Runs fn(...) and reports any error under the name `where`. Returns true when fn ran without error.
function Rec.Try(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Rec.Error(where, err) end
    return ok
end

-- Wraps fn so that an error inside it is reported, for timer and event callbacks.
function Rec.Guard(where, fn)
    return function(...) return Rec.Try(where, fn, ...) end
end

-- Calls a game function. A function this client lacks gives nil (the add-on is built to do without it); a function
-- that fails is reported, then gives nil.
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e = pcall(fn, ...)
    if ok then return a, b, c, d, e end
    Rec.Error("a game call", a)
    return nil
end

local function text(v, max)
    if type(v) ~= "string" or not Readable(v) then return nil end
    local s = Core.CleanText(v, max or Core.TEXT_MAX)
    if s == "" then return nil end
    return s
end

local function where()
    return text(call(GetRealZoneText), 80), text(call(GetSubZoneText), 80) or ""
end

-- The outdoor zone the player is in, for the first-visit screenshot (owner's decision, 13 November 2026: ignore interior
-- names). Inside an inn or a town hall the game's zone name is the building's ("Scarlet Raven Tavern"), which would
-- end the wait for the zone around it. The player's map says which zone it is: a building on the zone's own map gives
-- that zone's name, and a map of its own (a micro map) is followed up to its parent zone. Dungeons and raids keep their
-- own name. Without the map calls, or when they answer nothing, this is the game's zone name, as before.
-- (Outdoor places on one map, such as Darkshire in Duskwood, are subzones; they never changed the zone.)
local ZONE_MAP_TYPE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

function Rec.StayZone()
    local z = where()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo) then return z end
    local _, itype = call(IsInInstance)
    if itype == "party" or itype == "raid" then return z end
    local id = call(C_Map.GetBestMapForUnit, "player")
    for _ = 1, 6 do
        if type(id) ~= "number" or id == 0 then break end
        local info = call(C_Map.GetMapInfo, id)
        if type(info) ~= "table" then break end
        local parent = info.parentMapID
        if type(info.mapType) == "number" and info.mapType > ZONE_MAP_TYPE and type(parent) == "number" and parent ~= 0 then
            id = parent -- a micro map, an interior, a dungeon map: its zone is above it
        else
            return text(info.name, 80) or z
        end
    end
    return z
end

local function short(name)
    if type(name) ~= "string" or not Readable(name) or name == "" then return nil end
    if Ambiguate then
        local ok, s = pcall(Ambiguate, name, "short")
        if not ok then Rec.Error("Ambiguate", s)
        elseif type(s) == "string" and s ~= "" then return s end
    end
    return name
end

function Rec.Setting(key)
    if not char then return Core.DEFAULTS[key] end
    local v = char.settings[key]
    if v == nil then return Core.DEFAULTS[key] end
    return v
end

-- Appends an entry, filling in the zone and subzone when it has none.
function Rec.Add(entry)
    if not char then return nil end
    if entry.z == nil then entry.z, entry.sz = where() end
    local e = Core.Append(char, entry, now())
    if e and ns.Window and ns.Window.OnNewEntry then ns.Window.OnNewEntry(e) end
    return e
end
local Add = Rec.Add

-- Takes a screenshot a moment after a milestone (so the level-up glow or the boss's body is on screen) and records
-- it, so the app can link the picture from the session's summary.
-- No screenshot while flying (owner's decision, 13 November 2026): on a flight path, or airborne on a flying mount.
function Rec.Flying()
    return (call(UnitOnTaxi, "player") or call(IsFlying)) and true or false
end

local SHOT_RETRY, SHOT_TRIES = 5, 24 -- while flying, try again every 5 seconds for up to 2 minutes, then give up

-- A zone screenshot passes the outdoor zone (zone): it is taken only if the player is still there, and its entry names
-- that zone even when the player has stepped into a building. A subzone screenshot also passes the subzone (sub), which
-- must not have changed either. done(taken) is called once: true after the screenshot, false when it is given up.
function Rec.Shot(why, zone, done, sub)
    local function finish(taken) if done then done(taken) end end
    if not Rec.Setting("screenshots") or type(Screenshot) ~= "function" then return finish(false) end
    local tries = 0
    local take
    take = function()
        if zone and Rec.StayZone() ~= zone then return finish(false) end
        if sub and select(2, where()) ~= sub then return finish(false) end
        if Rec.Flying() then
            tries = tries + 1
            if tries < SHOT_TRIES and C_Timer and C_Timer.After then
                C_Timer.After(SHOT_RETRY, Rec.Guard("screenshot", take))
            else
                finish(false)
            end
            return
        end
        if Rec.Try("screenshot", Screenshot) then
            local e = { k = "shot", why = why }
            if zone then e.z, e.sz = zone, (select(2, where())) end
            Add(e)
            return finish(true)
        end
        finish(false)
    end
    if C_Timer and C_Timer.After then C_Timer.After(1.5, Rec.Guard("screenshot", take)) else Rec.Try("screenshot", take) end
end

-- Character, login and logout ------------------------------------------------------------------------------------

-- Finds or creates the current character's table and fills in the facts the summary may state.
function Rec.Start(db)
    local name = short(call(UnitName, "player")) or "Unknown"
    local realm = call(GetRealmName) or "Realm"
    char = Core.Char(db, Core.CharKey(name, realm))
    char.name, char.realm = name, realm
    char.class = call(UnitClass, "player") or char.class
    char.race = call(UnitRace, "player") or char.race
    char.sex = call(UnitSex, "player") or char.sex -- 2 male, 3 female: so the summary need not guess a pronoun
    char.faction = call(UnitFactionGroup, "player") or char.faction
    char.level = call(UnitLevel, "player") or char.level
    -- Entries the app has stored, as the snapshot says, can go.
    local snap = ns.journalSnapshot and ns.journalSnapshot.characters and ns.journalSnapshot.characters[Core.CharKey(name, realm)]
    if snap and tonumber(snap.confirmed) then
        char.confirmed = math.max(char.confirmed or 0, tonumber(snap.confirmed))
        Core.Trim(char, char.confirmed, Rec.Setting("keepSessions"))
    end
    if char.moneyMark == 0 then char.moneyMark = Core.MoneyMilestone(call(GetMoney) or 0) or 0 end
    -- Without chat logging the app cannot fill dungeons and raids, so a failure here must be seen.
    if LoggingChat then Rec.Try("turning on chat logging", LoggingChat, true) end
    return char
end

function Rec.Char() return char end

local function onEnteringWorld(isLogin, isReload)
    quietUntil = now() + 10
    if isLogin or isReload then
        -- PLAYER_LOGOUT fires at a /reload too; the "logout" it left is not one.
        local last = Core.Last(char)
        if isReload and last and last.k == "logout" and now() - last.t < 600 then table.remove(char.entries) end
        Add({ k = "login", reload = (not isLogin) and true or nil, lvl = call(UnitLevel, "player") })
        char.sinceReload = now()
        recapUsed = 0
    end
    -- Dungeon and raid entry and exit: the app reads the chat log between these two times.
    local _, itype = call(IsInInstance)
    itype = itype or "none"
    local name = text(call(GetInstanceInfo), 80)
    local was = char.inst
    local inside = itype == "party" or itype == "raid"
    if was and (not inside or was.name ~= name) then
        Add({ k = "leave", inst = was.name, itype = was.itype })
        char.inst = nil
    end
    if inside and not char.inst then
        char.inst = { name = name, itype = itype }
        Add({ k = "enter", inst = name, itype = itype })
        Rec.Shot("dungeon")
    end
    Rec.CheckZone()
    Rec.CheckRoster(true)
    Rec.StartSubzones()
end

-- Zones ----------------------------------------------------------------------------------------------------------

-- Two kinds of zone screenshot (owner's decision, 13 November 2026):
-- 1. First visit ("new zone"): taken on arriving in an outdoor zone the character has never been in. zonesVisited keeps
--    the time of that screenshot. A zone in zonesSeen counts as visited too (saved before zonesVisited existed). While
--    flying it waits for the landing, as other screenshots do; if the player has left the zone by then, none is taken
--    and the next arrival tries again. Dungeons and raids take none: they have their own entry screenshot.
-- 2. Stay ("zone"): the screenshot of a stay waits until the player has stayed in the zone for ZONE_STAY seconds, so
--    passing through, or crossing it on a flight path, takes none. A zone gets no new stay screenshot for ZONE_COOLDOWN
--    seconds after one: zonesSeen keeps the time of the last. A player who stays on in the zone gets the next one as
--    soon as that time is over, with no new wait and no zone change needed (owner's decision, 14 November 2026: 45
--    minutes, down from an hour). Leaving the zone before the screenshot means the next visit tries again. Saved
--    values of true count as long ago.
-- After any flight seen during the wait, the screenshot also waits LANDED seconds on the ground (owner's decision,
-- 13 November 2026), so it shows the place and not the dismount. The wait is checked every ZONE_POLL seconds, which is how flight is noticed.
Rec.ZONE_STAY, Rec.ZONE_LANDED, Rec.ZONE_POLL, Rec.ZONE_COOLDOWN = 300, 60, 15, 2700
local zoneWait -- { z = zone, due = time the screenshot is due, flew = time last seen flying, token }

local zoneShotDue

-- Starts the wait for a stay screenshot in zone z, due at the time given.
local function startZoneWait(z, due)
    if not (Rec.Setting("screenshots") and C_Timer and C_Timer.After) then return end
    local token = {}
    zoneWait = { z = z, due = due, flew = Rec.Flying() and now() or nil, token = token }
    C_Timer.After(Rec.ZONE_POLL, Rec.Guard("the zone screenshot", function() zoneShotDue(token) end))
end

zoneShotDue = function(token)
    if not zoneWait or zoneWait.token ~= token then return end -- left the zone, or a newer wait began
    local z = Rec.StayZone()
    if z ~= zoneWait.z then zoneWait = nil return end
    local t = now()
    if Rec.Flying() then zoneWait.flew = t end
    if t < zoneWait.due or (zoneWait.flew and t - zoneWait.flew < Rec.ZONE_LANDED) then
        C_Timer.After(Rec.ZONE_POLL, Rec.Guard("the zone screenshot", function() zoneShotDue(token) end))
        return
    end
    zoneWait = nil
    char.zonesSeen[z] = t
    Rec.Shot("zone", z)
    startZoneWait(z, t + Rec.ZONE_COOLDOWN) -- still here when the time is over: the next one at once
end

local arriving -- the zone whose first-visit screenshot is on its way

local function firstVisit(z)
    if char.zonesVisited[z] or char.zonesSeen[z] or arriving == z then return end
    local _, itype = call(IsInInstance)
    if itype == "party" or itype == "raid" then return end
    arriving = z
    Rec.Shot("new zone", z, function(taken)
        if arriving == z then arriving = nil end
        if taken then char.zonesVisited[z] = now() end
    end)
end

function Rec.CheckZone()
    local z, sz = where()
    if not z then return end
    local e = Core.AddZone(char, z, sz, now())
    if e and ns.Window and ns.Window.OnNewEntry then ns.Window.OnNewEntry(e) end
    local stay = Rec.StayZone() -- the outdoor zone: a step into a building does not end the wait
    if not stay then return end
    firstVisit(stay)
    if zoneWait and zoneWait.z ~= stay then zoneWait = nil end
    if not zoneWait then
        -- At least ZONE_STAY seconds here, and not before ZONE_COOLDOWN seconds after the zone's last stay screenshot.
        local last = char.zonesSeen[stay]
        local due = now() + Rec.ZONE_STAY
        if type(last) == "number" then due = math.max(due, last + Rec.ZONE_COOLDOWN) end
        startZoneWait(stay, due)
    end
end
Rec.ZoneWait = function() return zoneWait end

-- Subzones (owner's decision, 14 November 2026). A subzone is the game's place name inside an outdoor zone, such as
-- Dun Modr in the Wetlands; it is kept as "<zone>/<subzone>".
-- 1. First visit ("new subzone"): taken once the player has stayed in a subzone the character has never had one of
--    for SUB_FIRST seconds without a break. subzonesVisited keeps the time of that screenshot.
-- 2. Stay ("subzone"): within one session, taken once the player's time in a subzone adds up to SUB_TOTAL seconds,
--    over any number of visits. subStay keeps the session's times; one such screenshot per subzone per session.
-- Time is counted every SUB_POLL seconds. Time flying does not count, and a flight breaks a stay. Dungeons and raids,
-- and places with no subzone name, are left out. A gap between checks counts as at most SUB_GAP seconds (a loading
-- screen or a stalled timer must not add a lump of time).
Rec.SUB_FIRST, Rec.SUB_TOTAL, Rec.SUB_POLL, Rec.SUB_GAP = 300, 1200, 15, 60
local subHere -- { key, since }: the subzone the player is in, and since when without a break
local subLast -- time of the last check
local subPending = {} -- key -> true while a subzone screenshot is on its way

function Rec.SubzoneTick()
    if not char then return end
    local t = now()
    local dt = subLast and math.max(0, math.min(t - subLast, Rec.SUB_GAP)) or 0
    subLast = t
    local _, itype = call(IsInInstance)
    local z = Rec.StayZone()
    local _, sz = where()
    if itype == "party" or itype == "raid" or not z or not sz or sz == "" or Rec.Flying() then subHere = nil return end
    local key = z .. "/" .. sz
    local st = char.subStay
    if type(st) ~= "table" or st.s ~= char.session then
        st = { s = char.session, t = {}, shot = {} }
        char.subStay = st
    end
    if subHere and subHere.key == key then
        st.t[key] = (st.t[key] or 0) + dt
    else
        subHere = { key = key, since = t }
    end
    if subPending[key] then return end
    local why
    if not char.subzonesVisited[key] and t - subHere.since >= Rec.SUB_FIRST then why = "new subzone"
    elseif not st.shot[key] and (st.t[key] or 0) >= Rec.SUB_TOTAL then why = "subzone" end
    if not why then return end
    subPending[key] = true
    Rec.Shot(why, z, function(taken)
        subPending[key] = nil
        if not taken then return end
        if why == "new subzone" then char.subzonesVisited[key] = now() else st.shot[key] = true end
    end, sz)
end

-- The checks run for as long as the game runs, from the first time the player enters the world.
local subTicking
local function subzoneLoop()
    C_Timer.After(Rec.SUB_POLL, Rec.Guard("the subzone screenshots", subzoneLoop)) -- first, so an error cannot end it
    Rec.SubzoneTick()
end
function Rec.StartSubzones()
    if subTicking or not (C_Timer and C_Timer.After) then return end
    subTicking = true
    C_Timer.After(Rec.SUB_POLL, Rec.Guard("the subzone screenshots", subzoneLoop))
end

-- Quests ---------------------------------------------------------------------------------------------------------

local function questGiver()
    return short(call(UnitName, "questnpc")) or short(call(UnitName, "npc"))
end

local function onQuestDetail()
    local title = text(call(GetTitleText), 120)
    if not title then return end
    local d = {
        title = title,
        text = text(call(GetQuestText), Core.QUEST_TEXT_MAX),
        obj = text(call(GetObjectiveText), Core.QUEST_TEXT_MAX),
        giver = questGiver(),
        t = now(),
    }
    pendingDetail[title] = d
    lastDetail = d
end

local function questTitle(id)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then return text(call(C_QuestLog.GetTitleForQuestID, id), 120) end
end

local function onQuestAccepted(a, b)
    local id = tonumber(b) or tonumber(a)
    local title = questTitle(id)
    local d = (title and pendingDetail[title]) or (lastDetail and now() - lastDetail.t < 30 and lastDetail) or nil
    title = title or (d and d.title)
    if not title then return end
    Add({ k = "quest", act = "accept", id = id, title = title, text = d and d.text, obj = d and d.obj, giver = d and d.giver })
    if d then pendingDetail[d.title] = nil end
end

local function onQuestComplete()
    pendingComplete = {
        title = text(call(GetTitleText), 120),
        giver = questGiver(),
        reward = text(call(GetRewardText), Core.QUEST_TEXT_MAX),
        t = now(),
    }
end

local function onQuestTurnedIn(id, xp, money)
    local p = pendingComplete and now() - pendingComplete.t < 60 and pendingComplete or nil
    local title = (p and p.title) or questTitle(id)
    if not title then return end
    Add({ k = "quest", act = "turnin", id = id, title = title, giver = p and p.giver, reward = p and p.reward,
          xp = tonumber(xp), money = tonumber(money) })
    pendingComplete = nil
end

-- Chat and NPC speech ---------------------------------------------------------------------------------------------

local function onChat(event, msg, speaker)
    local spec = Core.CHAT[event]
    if not spec or not Rec.Setting(spec.setting) then return end
    if not Readable(msg) then
        Core.AddGap(char, "chat lines", now(), (where()))
        return
    end
    local body = text(msg)
    if not body then return end
    Add({ k = "chat", ch = spec.ch, who = short(speaker), text = body, stock = spec.stock or nil })
end

local function onNpc(event, msg, speaker)
    local ch = Core.NPC[event]
    if not ch or not Rec.Setting("npcSpeech") then return end
    if not Readable(msg) then
        Core.AddGap(char, "NPC lines", now(), (where()))
        return
    end
    local who = short(speaker)
    local body = text(msg)
    if not body then return end
    if body:find("%s", 1, true) then body = body:gsub("%%s", who or "Someone") end -- emotes name their speaker as %s
    if Core.SeenRecently(recent, who, body, now()) then return end
    Add({ k = "npc", ch = ch, who = who, text = body })
end

-- Deaths and bosses -----------------------------------------------------------------------------------------------

-- The newest death recap the game holds, after `after`: its number and events.
local function newestRecap(after)
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then return nil end
    local found, events, misses = nil, nil, 0
    for id = math.max(1, after + 1), after + 200 do
        local ev = call(C_DeathRecap.GetRecapEvents, id)
        if type(ev) == "table" and #ev > 0 then
            found, events, misses = id, ev, 0
        else
            misses = misses + 1
            if misses >= 3 and (found or id > after + 20) then break end
        end
    end
    return found, events
end

function Rec.OnDeath()
    local z, sz = where()
    local function record()
        local entry = { k = "death", z = z, sz = sz, recap = "missing" }
        local id, events = newestRecap(recapUsed)
        if id then
            recapUsed = id
            local killer, spell, state = Core.KillerFromRecap(events, Readable)
            entry.killer, entry.spell, entry.recap = killer and Core.CleanText(killer, 80), spell and Core.CleanText(spell, 80), state
        elseif C_DeathRecap and C_DeathRecap.GetRecapEvents then
            entry.recap = "empty"
        end
        Add(entry)
    end
    -- The recap is built just after death; wait a moment for it.
    if C_Timer and C_Timer.After then C_Timer.After(1, Rec.Guard("death", record)) else Rec.Try("death", record) end
end

local function onBoss(name)
    name = text(name, 80)
    if not name then return end
    if lastBoss and lastBoss.name == name and now() - lastBoss.t < 30 then return end
    lastBoss = { name = name, t = now() }
    Add({ k = "boss", name = name })
    Rec.Shot("boss")
end

-- Level, loot, gear, group and progress ---------------------------------------------------------------------------

local lastLevel

local function onLevel(level)
    lastLevel = Add({ k = "level", level = tonumber(level) })
    char.level = tonumber(level) or char.level
    Rec.Shot("level")
    if RequestTimePlayed then Rec.Try("RequestTimePlayed", RequestTimePlayed) end
end

local function onTimePlayed(total)
    if lastLevel and now() - lastLevel.t < 60 then lastLevel.played = tonumber(total) end
    lastLevel = nil
end

local function itemQuality(link)
    local q = Core.LinkQuality(link)
    if q then return q end
    if C_Item and C_Item.GetItemQualityByID then
        local v = call(C_Item.GetItemQualityByID, link)
        if v then return v end
    end
    if GetItemInfo then return select(3, call(GetItemInfo, link)) end
end

local function onLoot(msg)
    if not Readable(msg) then return end
    local link, count = Core.ParseLoot(msg)
    if not link then return end
    local q = itemQuality(link)
    if not q or q < 3 then return end -- rare or better only
    Add({ k = "loot", item = Core.CleanText(link, 120), q = q, n = count > 1 and count or nil })
end

local SLOT_NAMES = { [1] = "head", [2] = "neck", [3] = "shoulder", [5] = "chest", [6] = "waist", [7] = "legs",
    [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger", [12] = "finger", [13] = "trinket", [14] = "trinket",
    [15] = "back", [16] = "main hand", [17] = "off hand", [18] = "ranged" }

local function onEquip(slot)
    if now() < quietUntil or not SLOT_NAMES[slot] then return end
    local link = call(GetInventoryItemLink, "player", slot)
    if not link or not Readable(link) then return end
    local q = itemQuality(link)
    if not q or q < 2 then return end -- uncommon or better
    local item = Core.CleanText(link, 120)
    local last = Core.Last(char)
    if last and last.k == "gear" and last.item == item then return end
    Add({ k = "gear", item = item, slot = SLOT_NAMES[slot], q = q })
end

-- Compares the group with the last one saved and records who joined and left. At login the saved list is the one
-- from before, so a reload records nothing new.
function Rec.CheckRoster()
    if not char then return end
    local names = {}
    local n = call(GetNumGroupMembers) or 0
    local prefix = (call(IsInRaid) and "raid") or "party"
    for i = 1, (prefix == "raid" and n or math.max(0, n - 1)) do
        local who = short(call(UnitName, prefix .. i))
        if who and who ~= char.name and who ~= UNKNOWNOBJECT and who ~= "Unknown" then names[who] = true end
    end
    local old = char.roster or {}
    for who in pairs(names) do if not old[who] then Add({ k = "group", act = "join", who = who }) end end
    for who in pairs(old) do if not names[who] then Add({ k = "group", act = "leave", who = who }) end end
    char.roster = names
end

local function onSkill(msg)
    if not Readable(msg) then return end
    local skill, value = Core.ParseSkill(msg)
    if not skill or not Core.SkillMilestone(value) then return end
    if (char.skills[skill] or 0) >= value then return end
    char.skills[skill] = value
    Add({ k = "skill", skill = skill, value = value })
end

local function onSystem(msg)
    if not Readable(msg) then return end
    local faction, standing = Core.ParseStanding(msg)
    if faction then Add({ k = "rep", faction = faction, standing = standing }) end
end

local function onMoney()
    local mark = Core.MoneyMilestone(call(GetMoney) or 0)
    if mark and mark > (char.moneyMark or 0) then
        char.moneyMark = mark
        Add({ k = "money", copper = mark })
    end
end

-- A note the player types (/jm note ...).
function Rec.Note(msg)
    local body = Core.CleanText(msg, Core.TEXT_MAX)
    if not body or body == "" then return nil end
    return Add({ k = "note", text = body })
end

-- Events ---------------------------------------------------------------------------------------------------------

Rec.EVENTS = {
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "QUEST_DETAIL", "QUEST_ACCEPTED", "QUEST_COMPLETE", "QUEST_TURNED_IN",
    "PLAYER_DEAD", "BOSS_KILL", "ENCOUNTER_END",
    "PLAYER_LEVEL_UP", "TIME_PLAYED_MSG", "CHAT_MSG_LOOT", "PLAYER_EQUIPMENT_CHANGED", "GROUP_ROSTER_UPDATE",
    "CHAT_MSG_SKILL", "CHAT_MSG_SYSTEM", "CHAT_MSG_COMBAT_FACTION_CHANGE", "PLAYER_MONEY", "PLAYER_LOGOUT",
}
for event in pairs(Core.CHAT) do Rec.EVENTS[#Rec.EVENTS + 1] = event end
for event in pairs(Core.NPC) do Rec.EVENTS[#Rec.EVENTS + 1] = event end

function Rec.OnEvent(event, ...)
    if not char then return end
    if Core.CHAT[event] then return onChat(event, ...) end
    if Core.NPC[event] then return onNpc(event, ...) end
    if event == "PLAYER_ENTERING_WORLD" then onEnteringWorld(...)
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then Rec.CheckZone()
    elseif event == "QUEST_DETAIL" then onQuestDetail()
    elseif event == "QUEST_ACCEPTED" then onQuestAccepted(...)
    elseif event == "QUEST_COMPLETE" then onQuestComplete()
    elseif event == "QUEST_TURNED_IN" then onQuestTurnedIn(...)
    elseif event == "PLAYER_DEAD" then Rec.OnDeath()
    elseif event == "BOSS_KILL" then local _, name = ... onBoss(name)
    elseif event == "ENCOUNTER_END" then
        local _, name, _, _, success = ...
        if success == 1 or success == true then onBoss(name) end
    elseif event == "PLAYER_LEVEL_UP" then onLevel(...)
    elseif event == "TIME_PLAYED_MSG" then onTimePlayed(...)
    elseif event == "CHAT_MSG_LOOT" then onLoot(...)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then onEquip(...)
    elseif event == "GROUP_ROSTER_UPDATE" then Rec.CheckRoster()
    elseif event == "CHAT_MSG_SKILL" then onSkill(...)
    elseif event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then onSystem(...)
    elseif event == "PLAYER_MONEY" then onMoney()
    elseif event == "PLAYER_LOGOUT" then
        Add({ k = "logout" })
        char.level = call(UnitLevel, "player") or char.level
    end
end
