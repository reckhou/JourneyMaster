-- JourneyMaster core: the pure logic of the recorder, with no game calls, so tests/core_harness.lua can run it offline.
-- Entry format, play sessions, merging of rapid zone changes, the size cap, trimming of entries the app has stored,
-- text cleaning, chat-message parsing, the killer from a death recap, and the lines the Log tab shows.
--
-- Abbreviations: SV = SavedVariables (the file the game writes for the add-on at /reload or logout). NPC = non-player
-- character. GUID = the game's unique identifier for a unit.
--
-- An entry is a small table: i (its number, counting up per character), s (its play-session number), t (epoch seconds),
-- k (its kind), z and sz (zone and subzone), plus the fields of its kind (see Core.KINDS).
local _, ns = ...
ns = ns or {}
local Core = {}
ns.Core = Core

Core.SCHEMA = 1
Core.CAP = 30000               -- most entries kept per character; a 50,000-entry file gave no noticeable logout pause
Core.SESSION_GAP = 30 * 60     -- a gap this long between two entries starts a new play session
Core.ZONE_MERGE = 60           -- zone changes closer together than this are merged into one entry
Core.REPEAT_WINDOW = 10 * 60   -- the same NPC line from the same speaker within this time is recorded once
Core.TEXT_MAX = 600            -- characters kept from one chat or NPC line
Core.QUEST_TEXT_MAX = 2000     -- characters kept from a quest's own text

-- Every kind of entry, its label in the Log tab and its filter chip, in the order of the chips. Colours follow the
-- game's own chat colours (owner's decision, 13 November 2026): `chat` names the game's chat type, whose colour the
-- game holds in ChatTypeInfo (the player's chat settings, Blizzard's defaults unless changed), and `hex` is the colour
-- used where the game gives none. Notes are white, at the owner's request.
Core.KINDS = {
    { key = "zone", label = "Zone", chat = "CHANNEL_NOTICE", hex = "ffc0c0" },
    { key = "quest", label = "Quest", chat = "SYSTEM", hex = "ffff00" },
    { key = "chat", label = "Chat", chat = "SAY", hex = "ffffff" },
    { key = "emote", label = "Emote", chat = "EMOTE", hex = "ff8040" },
    { key = "npc", label = "NPC speech", chat = "MONSTER_SAY", hex = "ffff9f" },
    { key = "death", label = "Death", global = "RED_FONT_COLOR", hex = "ff2020" },
    { key = "boss", label = "Boss", chat = "RAID_BOSS_EMOTE", hex = "ffdd00" },
    { key = "loot", label = "Loot", chat = "LOOT", hex = "00aa00" },
    { key = "level", label = "Level", chat = "COMBAT_XP_GAIN", hex = "6f6fff" },
    { key = "group", label = "Group", chat = "PARTY", hex = "aaaaff" },
    { key = "note", label = "Note", hex = "ffffff" },
}
Core.KIND = {}
for _, kind in ipairs(Core.KINDS) do Core.KIND[kind.key] = kind end

-- The colours of single channels and kinds within a chip: chat type and the colour used where the game gives none.
Core.CHANNEL_COLOUR = {
    chat = { say = { "SAY", "ffffff" }, yell = { "YELL", "ff4040" }, party = { "PARTY", "aaaaff" },
        raid = { "RAID", "ff7f00" }, instance = { "INSTANCE_CHAT", "ff7f00" }, emote = { "EMOTE", "ff8040" } },
    npc = { say = { "MONSTER_SAY", "ffff9f" }, yell = { "MONSTER_YELL", "ff4040" }, emote = { "MONSTER_EMOTE", "ff8040" },
        whisper = { "MONSTER_WHISPER", "ffb5eb" }, party = { "MONSTER_PARTY", "aaaaff" } },
}
Core.KIND_COLOUR = {
    money = { "MONEY", "ffff00" }, skill = { "SKILL", "5555ff" }, rep = { "COMBAT_FACTION_CHANGE", "8080ff" },
    gear = { "LOOT", "00aa00" }, gap = { nil, "9d9d9d" },
}
-- Item quality colours (poor to heirloom), where the game gives none.
Core.QUALITY_HEX = { [0] = "9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000", "e6cc80", "00ccff" }
-- Kinds that have no chip of their own are shown under one of the chips above.
Core.CHIP_OF = {
    zone = "zone", enter = "zone", leave = "zone", login = "zone", logout = "zone", ["end"] = "zone",
    quest = "quest", chat = "chat", gap = "chat", npc = "npc", death = "death", boss = "boss",
    loot = "loot", gear = "loot", money = "loot", level = "level", skill = "level", rep = "level",
    group = "group", note = "note", shot = "note",
}

-- Settings and their defaults. Each recorded chat channel has its own switch.
Core.DEFAULTS = {
    minimapButton = true,
    chatSay = true, chatYell = true, chatEmote = true, chatParty = true, chatRaid = true, chatInstance = true,
    npcSpeech = true,
    screenshots = true,
    reloadPrompt = false,  -- after a long session, offer a /reload so a crash cannot lose it
    reloadHours = 2,
    keepSessions = 5,      -- newest sessions whose raw entries stay in the add-on after the app has stored them
    aiModel = "opus",      -- the AI model the app summarises with (a `claude` command alias)
    aiEffort = "low",      -- and its effort level
}

-- The choices for the AI model and effort under Settings: the `claude` command's aliases and effort levels.
Core.AI_MODELS = { { "opus", "Opus" }, { "sonnet", "Sonnet" }, { "haiku", "Haiku" }, { "fable", "Fable" } }
Core.AI_EFFORTS = { { "low", "Low" }, { "medium", "Medium" }, { "high", "High" }, { "xhigh", "Extra high" }, { "max", "Max" } }

-- The choice after `value` in a list of choices (wrapping round), and the label of a value.
function Core.NextChoice(list, value)
    for i, c in ipairs(list) do if c[1] == value then return list[i % #list + 1][1] end end
    return list[1][1]
end
function Core.ChoiceLabel(list, value)
    for _, c in ipairs(list) do if c[1] == value then return c[2] end end
    return tostring(value)
end

-- Chat events, the channel name recorded and the setting that switches it. Whispers are never recorded.
Core.CHAT = {
    CHAT_MSG_SAY = { ch = "say", setting = "chatSay" },
    CHAT_MSG_YELL = { ch = "yell", setting = "chatYell" },
    CHAT_MSG_EMOTE = { ch = "emote", setting = "chatEmote" },
    CHAT_MSG_TEXT_EMOTE = { ch = "emote", setting = "chatEmote", stock = true },
    CHAT_MSG_PARTY = { ch = "party", setting = "chatParty" },
    CHAT_MSG_PARTY_LEADER = { ch = "party", setting = "chatParty" },
    CHAT_MSG_RAID = { ch = "raid", setting = "chatRaid" },
    CHAT_MSG_RAID_LEADER = { ch = "raid", setting = "chatRaid" },
    CHAT_MSG_RAID_WARNING = { ch = "raid", setting = "chatRaid" },
    CHAT_MSG_INSTANCE_CHAT = { ch = "instance", setting = "chatInstance" },
    CHAT_MSG_INSTANCE_CHAT_LEADER = { ch = "instance", setting = "chatInstance" },
}
-- NPC speech events and the channel recorded.
Core.NPC = {
    CHAT_MSG_MONSTER_SAY = "say", CHAT_MSG_MONSTER_YELL = "yell", CHAT_MSG_MONSTER_EMOTE = "emote",
    CHAT_MSG_MONSTER_WHISPER = "whisper", CHAT_MSG_MONSTER_PARTY = "party",
    CHAT_MSG_RAID_BOSS_EMOTE = "emote", CHAT_MSG_RAID_BOSS_WHISPER = "whisper",
}

-- Money milestones in copper: 1, 10, 50, 100, 250, 500 and 1,000 gold, then every 1,000 gold.
Core.MONEY_MARKS = { 10000, 100000, 500000, 1000000, 2500000, 5000000, 10000000 }

-- Item quality from the colour of an item link (poor to legendary), for links that carry no quality number.
Core.QUALITY_COLOURS = {
    ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6,
}

-- Text ------------------------------------------------------------------------------------------------------------

-- Plain text from a game string: item, quest and channel links become their visible "[Name]", colour codes, textures
-- and line breaks go, runs of spaces become one. Cut to max characters (on a whole UTF-8 character) when given.
function Core.CleanText(s, max)
    if type(s) ~= "string" then return nil end
    s = s:gsub("|H.-|h(.-)|h", "%1")       -- links: keep the visible part
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")   -- colour start
    s = s:gsub("|cn[%w_]+:", "")           -- named colour start (newer clients)
    s = s:gsub("|r", "")
    s = s:gsub("|T.-|t", "")               -- inline textures
    s = s:gsub("|A.-|a", "")               -- inline atlas icons
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("  +", " ")
    s = s:gsub("^ ", ""):gsub(" $", "")
    if max and #s > max then
        local cut = max
        while cut > 0 do
            local b = s:byte(cut + 1)
            if not b or b < 0x80 or b >= 0xC0 then break end -- stop on a character's first byte
            cut = cut - 1
        end
        s = s:sub(1, cut) .. "..."
    end
    return s
end

-- The quality (0 poor to 6) an item link's colour shows, or nil.
function Core.LinkQuality(link)
    if type(link) ~= "string" then return nil end
    local n = link:match("|cnIQ(%d):")
    if n then return tonumber(n) end
    local hex = link:match("|c%x%x(%x%x%x%x%x%x)")
    return hex and Core.QUALITY_COLOURS[hex:lower()] or nil
end

-- "You receive loot: [Item]x3." -> the item link and the count. Only the player's own loot matches.
function Core.ParseLoot(text)
    if type(text) ~= "string" then return nil end
    local body = text:match("^You receive loot: (.+)$") or text:match("^You receive item: (.+)$")
    if not body then return nil end
    body = body:gsub("%.$", "")
    local link, count = body:match("^(.-)x(%d+)$")
    if not link then link, count = body, 1 end
    return link, tonumber(count)
end

-- "Your skill in Tailoring has increased to 75." -> "Tailoring", 75.
function Core.ParseSkill(text)
    if type(text) ~= "string" then return nil end
    local skill, value = text:match("^Your skill in (.+) has increased to (%d+)%.?$")
    if skill then return skill, tonumber(value) end
end

-- A skill value worth recording: every 25 points, which covers the rank caps 75, 150, 225 and 300.
function Core.SkillMilestone(value)
    return type(value) == "number" and value > 0 and value % 25 == 0
end

-- "You are now Friendly with Stormwind." -> "Stormwind", "Friendly".
function Core.ParseStanding(text)
    if type(text) ~= "string" then return nil end
    local standing, faction = text:match("^You are now (.-) with (.+)%.$")
    if standing then return faction, standing end
end

-- The highest money milestone (in copper) that `copper` has reached, or nil when it has not reached the first.
function Core.MoneyMilestone(copper)
    if type(copper) ~= "number" then return nil end
    local best
    for _, mark in ipairs(Core.MONEY_MARKS) do
        if copper >= mark then best = mark end
    end
    local top = Core.MONEY_MARKS[#Core.MONEY_MARKS]
    if copper >= top then best = math.floor(copper / top) * top end
    return best
end

-- "1,234g 5s 6c" style text for copper.
function Core.Money(copper)
    copper = tonumber(copper) or 0
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

-- The killer from a death recap: the event that dealt the overkill, else the latest event. `readable` says whether a
-- value may be read (secret values may not). Returns killer (a name, or an environmental cause such as "Falling"),
-- the spell or attack, and a state: "ok", "empty" (no events), or "hidden" (the events were there but secret).
function Core.KillerFromRecap(events, readable)
    readable = readable or function(v) return v ~= nil end
    if type(events) ~= "table" or #events == 0 then return nil, nil, "empty" end
    local pick, pickTime
    for _, e in ipairs(events) do
        if type(e) == "table" then
            local over = readable(e.overkill) and tonumber(e.overkill) or nil
            if over and over > 0 then pick = e break end
            local ts = readable(e.timestamp) and tonumber(e.timestamp) or nil
            if ts and (not pickTime or ts > pickTime) then pick, pickTime = e, ts end
        end
    end
    pick = pick or events[#events]
    if type(pick) ~= "table" then return nil, nil, "hidden" end
    local name = readable(pick.sourceName) and pick.sourceName or nil
    if type(name) ~= "string" or name == "" then name = nil end
    local spell
    if pick.event == "SWING_DAMAGE" then
        spell = "melee"
    elseif readable(pick.spellName) and type(pick.spellName) == "string" and pick.spellName ~= "" then
        spell = pick.spellName
    end
    if not name and readable(pick.environmentalType) and type(pick.environmentalType) == "string" then
        local env = pick.environmentalType:lower()
        name = env:sub(1, 1):upper() .. env:sub(2)
        spell = nil
    end
    if not name and not spell then return nil, nil, "hidden" end
    return name, spell, "ok"
end

-- Characters and entries ------------------------------------------------------------------------------------------

-- The key of a character: "Name-Realm".
function Core.CharKey(name, realm)
    local r = tostring(realm or "?"):gsub("%s", "")
    return tostring(name or "?") .. "-" .. r
end

-- The saved table of one character, created when missing; missing settings get their defaults.
function Core.Char(db, key)
    db.schema = db.schema or Core.SCHEMA
    db.characters = db.characters or {}
    local c = db.characters[key]
    if not c then
        c = { seq = 0, session = 0, lastT = 0, entries = {}, dropped = 0, trimmed = 0, settings = {}, zonesSeen = {},
              zonesVisited = {}, subzonesVisited = {}, moneyMark = 0, skills = {} }
        db.characters[key] = c
    end
    c.entries = c.entries or {}
    c.settings = c.settings or {}
    c.zonesSeen = c.zonesSeen or {}
    c.zonesVisited = c.zonesVisited or {}
    c.subzonesVisited = c.subzonesVisited or {}
    c.skills = c.skills or {}
    for k, v in pairs(Core.DEFAULTS) do
        if c.settings[k] == nil then c.settings[k] = v end
    end
    return c
end

-- Appends an entry to a character at time `now`, numbering it and placing it in a play session. A gap of SESSION_GAP,
-- or the player finishing the session (c.endSession, set by /jm end), starts a new session. A login does not: logging
-- out and back in within SESSION_GAP stays in one session (owner's decision, 13 November 2026). At the cap, the oldest entries the app has already stored
-- (number up to c.confirmed) make room; when there are none, the new entry is dropped and counted. Returns the entry.
function Core.Append(c, entry, now)
    now = now or entry.t or 0
    if #c.entries >= Core.CAP then
        local confirmed = c.confirmed or 0
        if c.entries[1] and c.entries[1].i <= confirmed then
            table.remove(c.entries, 1)
            c.trimmed = (c.trimmed or 0) + 1
        else
            c.dropped = (c.dropped or 0) + 1
            return nil
        end
    end
    local newSession = (c.session or 0) == 0
        or c.endSession
        or (now - (c.lastT or 0) > Core.SESSION_GAP)
    if newSession then c.session = (c.session or 0) + 1 end
    c.endSession = nil
    c.seq = (c.seq or 0) + 1
    entry.i = c.seq
    entry.s = c.session
    entry.t = now
    c.lastT = now
    c.entries[#c.entries + 1] = entry
    return entry
end

-- The last entry, or nil.
function Core.Last(c)
    return c.entries[#c.entries]
end

-- Records a zone change. A change within ZONE_MERGE seconds of the previous zone entry, with nothing between them,
-- replaces it (running through a town does not leave a trail of subzones). A change to the same place as the last zone
-- entry is ignored. Returns the entry written or updated, or nil.
function Core.AddZone(c, zone, sub, now)
    if not zone or zone == "" then return nil end
    sub = sub or ""
    local last = Core.Last(c)
    local lastZone
    for i = #c.entries, 1, -1 do
        if c.entries[i].k == "zone" then lastZone = c.entries[i] break end
    end
    if lastZone and lastZone.z == zone and (lastZone.sz or "") == sub and lastZone.s == c.session
        and now - (c.lastT or 0) <= Core.SESSION_GAP then
        return nil
    end
    if last and last.k == "zone" and now - last.t < Core.ZONE_MERGE and now - (c.lastT or 0) <= Core.SESSION_GAP then
        last.z, last.sz, last.t = zone, sub, now
        c.lastT = now
        return last
    end
    return Core.Append(c, { k = "zone", z = zone, sz = sub }, now)
end

-- Records a line of text that the game hides from add-ons (a secret value). Lines close together are counted in one
-- "gap" entry rather than one entry each.
function Core.AddGap(c, what, now, z)
    local last = Core.Last(c)
    if last and last.k == "gap" and last.what == what and now - last.t < 300 then
        last.n = (last.n or 1) + 1
        return last
    end
    return Core.Append(c, { k = "gap", what = what, n = 1, z = z }, now)
end

-- True when the same speaker said the same line within REPEAT_WINDOW (recent: an in-memory table, not saved).
function Core.SeenRecently(recent, who, text, now)
    local key = tostring(who) .. "\0" .. tostring(text)
    local seen = recent[key]
    recent[key] = now
    return seen ~= nil and now - seen < Core.REPEAT_WINDOW
end

-- Removes entries the app has stored (number up to `confirmed`), except those in the newest `keep` sessions, so the
-- Log tab can still show recent sessions. Returns how many were removed.
function Core.Trim(c, confirmed, keep)
    confirmed = tonumber(confirmed) or 0
    if confirmed <= 0 then return 0 end
    keep = keep or Core.DEFAULTS.keepSessions
    local sessions = {}
    for _, e in ipairs(c.entries) do sessions[e.s] = true end
    local list = {}
    for s in pairs(sessions) do list[#list + 1] = s end
    table.sort(list, function(a, b) return a > b end)
    local kept = {}
    for i = 1, math.min(keep, #list) do kept[list[i]] = true end
    local out, removed = {}, 0
    for _, e in ipairs(c.entries) do
        if e.i <= confirmed and not kept[e.s] then removed = removed + 1 else out[#out + 1] = e end
    end
    c.entries = out
    c.trimmed = (c.trimmed or 0) + removed
    return removed
end

-- Play sessions in the entries, oldest first: s, first and last time, entry count, the zones in order of first visit,
-- and the level at the start and end (from level entries).
function Core.Sessions(entries)
    local byS, order = {}, {}
    for _, e in ipairs(entries) do
        local s = byS[e.s]
        if not s then
            s = { s = e.s, first = e.t, last = e.t, count = 0, zones = {}, zoneSeen = {} }
            byS[e.s] = s
            order[#order + 1] = s
        end
        s.count = s.count + 1
        if e.t < s.first then s.first = e.t end
        if e.t > s.last then s.last = e.t end
        local z = e.z
        if z and z ~= "" and not s.zoneSeen[z] then
            s.zoneSeen[z] = true
            s.zones[#s.zones + 1] = z
        end
        if e.k == "level" then
            s.levelTo = e.level
            if not s.levelFrom then s.levelFrom = (e.level or 1) - 1 end
        end
        if e.lvl and not s.startLevel then s.startLevel = e.lvl end
    end
    table.sort(order, function(a, b) return a.s < b.s end)
    for _, s in ipairs(order) do s.zoneSeen = nil end
    return order
end

-- The entries of one session.
function Core.SessionEntries(entries, s)
    local out = {}
    for _, e in ipairs(entries) do if e.s == s then out[#out + 1] = e end end
    return out
end

-- Display ---------------------------------------------------------------------------------------------------------

-- "21:15" from epoch seconds. Uses the game's date() when there, else os.date.
local function clock(t, fmt)
    local d = date or os.date
    return d(fmt or "%H:%M", t)
end
Core.Clock = clock

local function place(e)
    if e.sz and e.sz ~= "" and e.sz ~= e.z then return e.z .. ", " .. e.sz end
    return e.z or "?"
end

local function q(text) return "\"" .. tostring(text) .. "\"" end

-- One line of the Log tab for an entry, without the time.
function Core.Describe(e)
    local k = e.k
    if k == "zone" then return "Entered " .. place(e)
    elseif k == "enter" then return "Entered the " .. (e.itype == "raid" and "raid " or "dungeon ") .. tostring(e.inst)
    elseif k == "leave" then return "Left " .. tostring(e.inst)
    elseif k == "login" then return e.reload and "Interface reloaded" or "Logged in"
    elseif k == "logout" then return "Logged out"
    elseif k == "end" then return "Finished the session"
    elseif k == "quest" then
        if e.act == "accept" then
            return "Accepted " .. q(e.title) .. (e.giver and (" from " .. e.giver) or "")
        elseif e.act == "turnin" then
            local extra = {}
            if e.xp and e.xp > 0 then extra[#extra + 1] = e.xp .. " XP" end
            if e.money and e.money > 0 then extra[#extra + 1] = Core.Money(e.money) end
            return "Handed in " .. q(e.title) .. (e.giver and (" to " .. e.giver) or "")
                .. (#extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or "")
        end
        return "Quest " .. q(e.title)
    elseif k == "npc" then
        if e.ch == "emote" then return e.text end
        return tostring(e.who) .. " " .. (e.ch == "yell" and "yells" or e.ch == "whisper" and "whispers" or "says") .. ": " .. tostring(e.text)
    elseif k == "chat" then
        if e.ch == "emote" then return e.stock and e.text or (tostring(e.who) .. " " .. tostring(e.text)) end
        local label = ({ say = "says", yell = "yells", party = "[Party]", raid = "[Raid]", instance = "[Instance]" })[e.ch] or e.ch
        if e.ch == "say" or e.ch == "yell" then return tostring(e.who) .. " " .. label .. ": " .. tostring(e.text) end
        return label .. " " .. tostring(e.who) .. ": " .. tostring(e.text)
    elseif k == "gap" then return (e.n or 1) .. " " .. tostring(e.what) .. " hidden by the game"
    elseif k == "death" then
        local by = e.killer and (" (killed by " .. e.killer .. (e.spell and e.spell ~= "melee" and (", " .. e.spell) or "") .. ")") or ""
        return "Died in " .. place(e) .. by
    elseif k == "boss" then return "Defeated " .. tostring(e.name)
    elseif k == "loot" then return "Looted " .. tostring(e.item) .. ((e.n or 1) > 1 and (" x" .. e.n) or "")
    elseif k == "gear" then return "Equipped " .. tostring(e.item)
    elseif k == "money" then return "Reached " .. Core.Money(e.copper)
    elseif k == "level" then return "Reached level " .. tostring(e.level)
    elseif k == "skill" then return tostring(e.skill) .. " reached " .. tostring(e.value)
    elseif k == "rep" then return tostring(e.standing) .. " with " .. tostring(e.faction)
    elseif k == "group" then return tostring(e.who) .. (e.act == "join" and " joined the group" or " left the group")
    elseif k == "note" then return "Note: " .. tostring(e.text)
    elseif k == "shot" then return "Screenshot (" .. tostring(e.why) .. ")"
    end
    return tostring(k)
end

-- The chip an entry belongs to. Player emotes have their own chip, apart from chat.
function Core.Chip(e)
    if e.k == "chat" and e.ch == "emote" then return "emote" end
    return Core.CHIP_OF[e.k] or "note"
end

local function hexOf(c)
    if type(c) ~= "table" or type(c.r) ~= "number" then return nil end
    local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return ("%02x%02x%02x"):format(byte(c.r), byte(c.g or 0), byte(c.b or 0))
end

-- "rrggbb" of one of the game's chat types (from ChatTypeInfo, the player's chat colours), or `fallback`.
function Core.ChatHex(chatType, fallback)
    local info = chatType and type(ChatTypeInfo) == "table" and ChatTypeInfo[chatType]
    return hexOf(info) or fallback
end

-- "rrggbb" of a chip.
function Core.KindHex(key)
    local kind = Core.KIND[key]
    if not kind then return "ffffff" end
    if kind.global then return hexOf(_G and _G[kind.global]) or kind.hex end
    return Core.ChatHex(kind.chat, kind.hex)
end

-- "rrggbb" of an item quality (0 poor to 7 heirloom), from the game's ITEM_QUALITY_COLORS where it has them.
function Core.QualityHex(q)
    q = tonumber(q)
    if not q then return nil end
    local c = type(ITEM_QUALITY_COLORS) == "table" and ITEM_QUALITY_COLORS[q]
    return hexOf(c) or Core.QUALITY_HEX[q]
end

-- "rrggbb" of an entry in the Log: the game's colour for its exact channel or kind, its item's quality for loot,
-- otherwise its chip's colour.
function Core.EntryHex(e)
    local byChannel = Core.CHANNEL_COLOUR[e.k]
    local pick = byChannel and byChannel[e.ch] or Core.KIND_COLOUR[e.k]
    if pick then return Core.ChatHex(pick[1], pick[2]) end
    if e.k == "loot" and e.q then return Core.QualityHex(e.q) or Core.KindHex("loot") end
    return Core.KindHex(Core.Chip(e))
end

-- The entries of a session that pass the chip filter (filter[chip] == false hides a chip).
function Core.Filter(entries, filter)
    local out = {}
    for _, e in ipairs(entries) do
        if not filter or filter[Core.Chip(e)] ~= false then out[#out + 1] = e end
    end
    return out
end

-- A session's header: "12 Nov 2026 · 21:45-00:35 · level 26-27 · Stormwind City, Duskwood".
function Core.SessionHeader(s)
    local parts = { clock(s.first, "%d %b %Y"), clock(s.first) .. "-" .. clock(s.last) }
    if s.levelTo then parts[#parts + 1] = "level " .. (s.levelFrom or "?") .. "-" .. s.levelTo end
    if #s.zones > 0 then parts[#parts + 1] = table.concat(s.zones, ", ") end
    return table.concat(parts, " \194\183 ")
end

-- Signals to the app through the chat log (the method of RPMaster's ADR 0001, "text capture through the padded chat
-- log"). The game writes WoWChatLog.txt only in 48 KiB blocks or at exit, so a signal line is followed by about 48 KiB
-- of padding lines, which makes the game write it about a second later. No line may hold "|", which the log cuts at.
Core.PAD_BYTES, Core.PAD_LEN = 48 * 1024, 200

-- "JMS:<id>:<KIND>:<arg>:<character key>". The arg is a session number (OPEN, END) or "field=value" (SET); it may not
-- hold a colon. The key goes last, as it is the only field that could hold one.
function Core.SignalLine(id, kind, arg, key)
    arg = tostring(arg or ""):gsub(":", "_")
    return (("JMS:%s:%s:%s:%s"):format(tostring(id), tostring(kind), arg, tostring(key or "?")):gsub("[|\r\n]", "_"))
end

function Core.PadLine(id, n)
    local head = ("JMP:%s:%05d:"):format(tostring(id), n)
    return head .. ("."):rep(Core.PAD_LEN - #head)
end

-- Renaming and deleting sessions -----------------------------------------------------------------------------------
-- The add-on keeps each change (c.titles[s] = { text, t }; c.deleted[s] = t, t the time of the change) and sends it to
-- the app as a signal. The saved file carries it too, in case the signal is lost. The app lists the changes it has
-- handled in the snapshot (seenTitle, seenDelete: session -> t), so the game then shows the snapshot's version again.

Core.TITLE_MAX = 80 -- bytes

-- A title as typed: no escape codes or bars (the chat log cuts a line at "|"), one line, at most TITLE_MAX bytes.
-- nil when nothing is left.
function Core.CleanTitle(text)
    local s = Core.CleanText(text)
    if not s then return nil end
    s = s:gsub("|", ""):gsub("%c", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if #s > Core.TITLE_MAX then
        local cut = Core.TITLE_MAX
        while cut > 0 do
            local b = s:byte(cut + 1)
            if not b or b < 0x80 or b >= 0xC0 then break end
            cut = cut - 1
        end
        s = s:sub(1, cut):gsub("%s+$", "")
    end
    return s ~= "" and s or nil
end

function Core.Hex(s)
    return (tostring(s):gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
end

function Core.Unhex(h)
    return (tostring(h):gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

-- Records a rename of session s at time now. Returns the signal's arg: "<s>=<t>=<title in hex>".
function Core.RenameSession(c, s, title, now)
    c.titles = c.titles or {}
    c.titles[s] = { text = title, t = now }
    return ("%d=%d=%s"):format(s, now, Core.Hex(title))
end

-- Records the deletion of session s at time now; a session in progress is finished, so play goes on in a new one.
-- Returns the signal's arg: "<s>=<t>".
function Core.DeleteSession(c, s, now)
    c.deleted = c.deleted or {}
    c.deleted[s] = now
    if s == c.session then c.endSession = true end
    return ("%d=%d"):format(s, now)
end

-- Asking the app to summarise a session (the window's Summarise button): c.summaryRequests[s] = { t = time of the click,
-- sent = whether the app was told }. The app can only read the record after the reload the button causes, so the signal
-- goes out at the next login. The window shows a request as pending for SUMMARY_WAIT seconds, then offers the button again.
Core.SUMMARY_WAIT = 600
Core.SUMMARY_KEEP = 86400 -- a request older than this (a day) is dropped

function Core.RequestSummary(c, s, now)
    c.summaryRequests = c.summaryRequests or {}
    c.summaryRequests[s] = { t = now, sent = false }
end

function Core.SummaryRequested(c, s, now)
    local r = c and c.summaryRequests and c.summaryRequests[s]
    return r ~= nil and (now - (r.t or 0)) < Core.SUMMARY_WAIT
end

-- Drops the changes the snapshot says the app has handled (snapChar: the character's part of the snapshot, or nil).
-- A rename of a session the snapshot does not list yet is kept: the game has no other place to show it.
function Core.PruneChanges(c, snapChar, now)
    for s, r in pairs(c.summaryRequests or {}) do
        if (now or 0) - (r.t or 0) > Core.SUMMARY_KEEP then c.summaryRequests[s] = nil end
    end
    if not snapChar then return end
    local listed = {}
    for _, sess in ipairs(snapChar.sessions or {}) do listed[sess.s] = true end
    for s in pairs(c.summaryRequests or {}) do if listed[s] then c.summaryRequests[s] = nil end end
    for s, t in pairs(c.deleted or {}) do
        if (snapChar.seenDelete and snapChar.seenDelete[s] or 0) >= t then c.deleted[s] = nil end
    end
    for s, o in pairs(c.titles or {}) do
        if listed[s] and (snapChar.seenTitle and snapChar.seenTitle[s] or 0) >= (o.t or 0) then c.titles[s] = nil end
    end
end

-- The lines of one signal: the signal, then the padding.
function Core.SignalLines(id, kind, arg, key)
    local lines = { Core.SignalLine(id, kind, arg, key) }
    for n = 1, math.ceil(Core.PAD_BYTES / Core.PAD_LEN) do lines[#lines + 1] = Core.PadLine(id, n) end
    return lines
end

return Core
