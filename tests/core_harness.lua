-- Offline harness for src/JourneyMaster/Core.lua and Journal.lua: entries, sessions, zone merging, the cap, trimming,
-- text cleaning, chat parsing, the killer from a death recap, and the session list. Run: python scripts/run_lua_tests.py
date, time = os.date, os.time
local ns = {}
local function load(file) assert(loadfile("src/JourneyMaster/" .. file))("JourneyMaster", ns) end
load("Core.lua")
load("Journal.lua")
local Core, Journal = ns.Core, ns.Journal

local fails = 0
local function check(cond, msg)
    if not cond then
        fails = fails + 1
        print("FAIL: " .. msg)
    end
end
local function eq(a, b, msg) check(a == b, msg .. ": expected [" .. tostring(b) .. "], got [" .. tostring(a) .. "]") end

-- Text -----------------------------------------------------------------------------------------------------------
eq(Core.CleanText("|cffff8040|Hquest:181:0|h[Look to the Stars]|h|r you do this one?"), "[Look to the Stars] you do this one?", "quest link cleaned")
eq(Core.CleanText("a\n b  c|T123:0|t"), "a b c", "breaks, spaces and textures")
eq(Core.CleanText(string.rep("x", 20), 10), string.rep("x", 10) .. "...", "cut")
eq(Core.CleanText("caf\195\169 au lait", 4), "caf...", "cut never splits a UTF-8 character")
eq(Core.CleanText(nil), nil, "nil stays nil")
eq(Core.LinkQuality("|cff0070dd|Hitem:1:0|h[Blue]|h|r"), 3, "rare colour")
eq(Core.LinkQuality("|cnIQ4:|Hitem:1|h[Epic]|h|r"), 4, "named quality colour")
eq(Core.LinkQuality("plain"), nil, "no colour")

local link, n = Core.ParseLoot("You receive loot: |cff0070dd|Hitem:1|h[Cutlass]|h|rx2.")
eq(link, "|cff0070dd|Hitem:1|h[Cutlass]|h|r", "loot link")
eq(n, 2, "loot count")
link, n = Core.ParseLoot("You receive loot: |cff1eff00|Hitem:2|h[Boots]|h|r.")
eq(n, 1, "single loot")
eq(Core.ParseLoot("Seph Stormbrewer receives loot: Tin Ore."), nil, "other players' loot ignored")

local skill, value = Core.ParseSkill("Your skill in Tailoring has increased to 75.")
eq(skill, "Tailoring", "skill name") eq(value, 75, "skill value")
check(Core.SkillMilestone(75) and Core.SkillMilestone(150) and not Core.SkillMilestone(76), "skill milestones")
local faction, standing = Core.ParseStanding("You are now Friendly with Stormwind.")
eq(faction, "Stormwind", "faction") eq(standing, "Friendly", "standing")
eq(Core.MoneyMilestone(5000), nil, "under 1 gold")
eq(Core.MoneyMilestone(123456), 100000, "10 gold milestone")
eq(Core.MoneyMilestone(25000000), 20000000, "every 1,000 gold above the top")
eq(Core.Money(1234567), "123g 45s 67c", "money text")
eq(Core.Money(0), "0c", "no money")

-- Death recap ----------------------------------------------------------------------------------------------------
local events = {
    { timestamp = 10, sourceName = "Nightbane Vile Fang", spellName = "Bite", event = "SPELL_DAMAGE", overkill = -1 },
    { timestamp = 12, sourceName = "Nightbane Shadow Weaver", spellName = "Shadow Bolt", event = "SPELL_DAMAGE", overkill = 40 },
    { timestamp = 11, sourceName = "Nightbane Vile Fang", event = "SWING_DAMAGE", overkill = -1 },
}
local killer, spell, state = Core.KillerFromRecap(events)
eq(killer, "Nightbane Shadow Weaver", "killer is the overkill blow") eq(spell, "Shadow Bolt", "killing spell") eq(state, "ok", "state ok")
killer, spell = Core.KillerFromRecap({ { timestamp = 1, sourceName = "A", event = "SWING_DAMAGE" }, { timestamp = 3, sourceName = "B", event = "SWING_DAMAGE" } })
eq(killer, "B", "no overkill: latest blow") eq(spell, "melee", "melee")
killer, spell = Core.KillerFromRecap({ { timestamp = 1, event = "ENVIRONMENTAL_DAMAGE", environmentalType = "FALLING", overkill = 5 } })
eq(killer, "Falling", "environmental death")
local _, _, s2 = Core.KillerFromRecap({})
eq(s2, "empty", "no events")
local secret = {}
local hidden = { { timestamp = secret, sourceName = secret, spellName = secret, event = "SPELL_DAMAGE" } }
_, _, s2 = Core.KillerFromRecap(hidden, function(v) return v ~= nil and v ~= secret end)
eq(s2, "hidden", "secret recap")

-- Entries and sessions -------------------------------------------------------------------------------------------
local db = {}
local c = Core.Char(db, Core.CharKey("Baldrake Cavendell", "Living Flame"))
eq(Core.CharKey("Baldrake Cavendell", "Living Flame"), "Baldrake Cavendell-LivingFlame", "character key")
eq(c.settings.chatSay, true, "default setting")
local T = 1794520000
Core.Append(c, { k = "login" }, T)
Core.Append(c, { k = "chat", ch = "say", who = "A", text = "hi" }, T + 10)
eq(c.entries[2].i, 2, "numbered") eq(c.entries[2].s, 1, "first session")
Core.Append(c, { k = "login", reload = true }, T + 20)
eq(c.entries[3].s, 1, "a reload stays in the session")
Core.Append(c, { k = "note", text = "x" }, T + 20 + Core.SESSION_GAP + 1)
eq(c.entries[4].s, 2, "a long gap starts a session")
Core.Append(c, { k = "login" }, T + 20 + Core.SESSION_GAP + 5)
eq(c.entries[5].s, 2, "a login soon after stays in the session")
Core.Append(c, { k = "end" }, T + 20 + Core.SESSION_GAP + 6)
eq(c.entries[6].s, 2, "the end entry closes its own session")
c.endSession = true
Core.Append(c, { k = "login" }, T + 20 + Core.SESSION_GAP + 7)
eq(c.entries[7].s, 3, "a finished session: the next entry starts a new one")
eq(c.endSession, nil, "finish used once")
eq(Core.Chip({ k = "end" }), "zone", "end entries under the zone chip")
-- Signals to the app.
local sig = Core.SignalLines("123-1", "OPEN", 4, "Baldrake Cavendell-LivingFlame")
eq(sig[1], "JMS:123-1:OPEN:4:Baldrake Cavendell-LivingFlame", "signal line")
eq(#sig[2], Core.PAD_LEN, "padding line length")
check((#sig - 1) * Core.PAD_LEN >= Core.PAD_BYTES, "padding fills 48 KiB")
eq(Core.SignalLine("1", "OPEN", 1, "A|B"), "JMS:1:OPEN:1:A_B", "no | in a signal")
-- Colours: the game's chat colours where it has them, Blizzard's defaults otherwise; emotes apart from chat.
eq(Core.Chip({ k = "chat", ch = "emote" }), "emote", "player emotes have their own chip")
eq(Core.Chip({ k = "chat", ch = "say" }), "chat", "say stays chat")
eq(Core.Chip({ k = "npc", ch = "emote" }), "npc", "NPC emotes stay NPC speech")
eq(Core.EntryHex({ k = "chat", ch = "yell" }), "ff4040", "yell colour without the game")
eq(Core.EntryHex({ k = "npc", ch = "emote" }), "ff8040", "NPC emote colour")
eq(Core.EntryHex({ k = "loot", q = 4 }), "a335ee", "loot in its quality colour")
eq(Core.EntryHex({ k = "note", text = "x" }), "ffffff", "notes white")
eq(Core.EntryHex({ k = "death" }), "ff2020", "death red")
ChatTypeInfo = { SAY = { r = 1, g = 0, b = 0 } }
eq(Core.EntryHex({ k = "chat", ch = "say" }), "ff0000", "the player's own chat colour wins")
eq(Core.KindHex("chat"), "ff0000", "chip follows the player's chat colour")
ChatTypeInfo = nil
eq(Core.ParseStanding("RPMT:c1:L:1:say:X:You are now Friendly with Stormwind."), nil, "RPMaster lines are not standing changes")

-- Zones: rapid changes merge, repeats are ignored.
local z = Core.Char({}, "Z-R")
Core.Append(z, { k = "login" }, T)
Core.AddZone(z, "Stormwind City", "Trade District", T + 100)
Core.AddZone(z, "Stormwind City", "Cathedral Square", T + 120)
eq(#z.entries, 2, "zone change within a minute merged")
eq(z.entries[2].sz, "Cathedral Square", "merged entry shows the newest place")
eq(Core.AddZone(z, "Stormwind City", "Cathedral Square", T + 500), nil, "same place again ignored")
Core.AddZone(z, "Elwynn Forest", "", T + 600)
eq(#z.entries, 3, "a real change is kept")
Core.AddGap(z, "chat lines", T + 700)
Core.AddGap(z, "chat lines", T + 710)
eq(z.entries[4].n, 2, "hidden lines counted in one entry")

-- Repeated NPC lines.
local recent = {}
check(not Core.SeenRecently(recent, "Topper McNabb", "Spare change?", T), "first line new")
check(Core.SeenRecently(recent, "Topper McNabb", "Spare change?", T + 60), "repeat within ten minutes")
check(not Core.SeenRecently(recent, "Topper McNabb", "Spare change?", T + 60 + Core.REPEAT_WINDOW + 1), "repeat after ten minutes is new")

-- The cap: stored entries make room; otherwise new entries are dropped and counted.
local saveCap = Core.CAP
Core.CAP = 3
local capped = Core.Char({}, "C-R")
for i = 1, 3 do Core.Append(capped, { k = "note", text = tostring(i) }, T + i) end
eq(Core.Append(capped, { k = "note", text = "4" }, T + 4), nil, "full and nothing stored: dropped")
eq(capped.dropped, 1, "drop counted")
capped.confirmed = 2
Core.Append(capped, { k = "note", text = "5" }, T + 5)
eq(capped.entries[1].text, "2", "oldest stored entry made room")
eq(#capped.entries, 3, "still at the cap")
Core.CAP = saveCap

-- Trimming keeps the newest sessions.
local t = Core.Char({}, "T-R")
for sess = 1, 4 do
    Core.Append(t, { k = "login" }, T + sess * 10000)
    Core.Append(t, { k = "note", text = "s" .. sess }, T + sess * 10000 + 5)
end
eq(Core.Trim(t, 8, 2), 4, "stored entries of older sessions removed")
eq(t.entries[1].s, 3, "newest two sessions kept")
eq(Core.Trim(t, 0, 2), 0, "nothing stored: nothing trimmed")

-- Sessions and display.
local sessions = Core.Sessions(c.entries)
eq(#sessions, 3, "three sessions")
eq(sessions[1].count, 3, "first session's entries")
local d = Core.Char({}, "D-R")
Core.Append(d, { k = "login" }, T)
Core.Append(d, { k = "zone", z = "Duskwood", sz = "Darkshire" }, T + 1)
Core.Append(d, { k = "level", level = 27, z = "Duskwood" }, T + 2)
local ds = Core.Sessions(d.entries)[1]
eq(ds.levelFrom, 26, "level from") eq(ds.levelTo, 27, "level to") eq(ds.zones[1], "Duskwood", "zones in order")
check(Core.SessionHeader(ds):find("level 26%-27") ~= nil, "header shows levels")
eq(Core.Describe({ k = "quest", act = "accept", title = "Worgen in the Woods", giver = "Calor" }), "Accepted \"Worgen in the Woods\" from Calor", "quest line")
eq(Core.Describe({ k = "quest", act = "turnin", title = "Q", giver = "G", xp = 1900, money = 2200 }), "Handed in \"Q\" to G (1900 XP, 22s)", "hand-in line")
eq(Core.Describe({ k = "death", z = "Duskwood", sz = "", killer = "Stitches", spell = "melee" }), "Died in Duskwood (killed by Stitches)", "death line")
eq(Core.Describe({ k = "death", z = "Duskwood" }), "Died in Duskwood", "death without killer")
eq(Core.Describe({ k = "chat", ch = "party", who = "Seph", text = "come to me" }), "[Party] Seph: come to me", "party line")
eq(Core.Describe({ k = "chat", ch = "emote", who = "Baldrake", text = "glances at the exit." }), "Baldrake glances at the exit.", "typed emote")
eq(Core.Describe({ k = "npc", ch = "yell", who = "Town Crier", text = "Forward!" }), "Town Crier yells: Forward!", "NPC yell")
for _, k in ipairs({ "zone", "enter", "leave", "login", "logout", "gap", "boss", "loot", "gear", "money", "level", "skill", "rep", "group", "note", "shot" }) do
    check(type(Core.Describe({ k = k })) == "string", "every kind describes: " .. k)
    check(Core.CHIP_OF[k] ~= nil, "every kind has a chip: " .. k)
end
local filtered = Core.Filter(d.entries, { level = false })
eq(#filtered, 2, "chip filter hides a kind")

-- Journal: snapshot and record joined -------------------------------------------------------------------------------
ns.journalSnapshot = { schema = 1, revision = 3, written = T + 50000, characters = {
    ["D-R"] = { confirmed = 2, sessions = {
        { s = 1, title = "Into Duskwood", first = T, last = T + 2, zones = { "Duskwood" }, text = "# Into Duskwood\n\nBaldrake **walked** on.\n\n- one\n- two\n\n![Level 27](screenshots/a.jpg)", file = "data\\journeys\\D-R\\sessions\\2026-11-12-1.md" },
        { s = 0, title = "Older days", first = T - 90000, last = T - 80000, file = "data\\journeys\\D-R\\sessions\\2026-11-11-1.md" },
    } } } }
Core.Append(d, { k = "login" }, T + 40000)
local items = Journal.List(d, "D-R")
eq(#items, 3, "snapshot and record sessions joined")
eq(items[1].state, "pending", "newest unsummarised session first")
eq(items[2].state, "full", "summarised session") eq(items[2].entries, 3, "its entries counted")
eq(items[3].state, "brief", "older session by title only")
local blocks = Journal.JournalBlocks("D-R", items[2])
local all = {}
for _, b in ipairs(blocks) do all[#all + 1] = b.text end
local joined = table.concat(all, "\n")
check(joined:find("Baldrake walked on.", 1, true) ~= nil, "emphasis removed")
check(joined:find("\226\128\162 one", 1, true) ~= nil, "bullets")
check(joined:find("Screenshot: a.jpg", 1, true) ~= nil, "pictures named")
local brief = table.concat((function() local o = {} for _, b in ipairs(Journal.JournalBlocks("D-R", items[3])) do o[#o + 1] = b.text end return o end)(), "\n")
check(brief:find("2026-11-11-1.md", 1, true) ~= nil, "brief session points to its file")
local pend = Journal.JournalBlocks("D-R", items[1])
check(pend[3].text:find("Not summarised yet", 1, true) ~= nil, "pending session says so")
local logBlocks = Journal.LogBlocks("D-R", items[2], Core.SessionEntries(d.entries, 1), nil)
check(logBlocks[3].text:find("Reached level 27", 1, true) ~= nil, "Log shows the session's entries")
local trimmed = Journal.LogBlocks("D-R", items[3], {}, nil)
check(trimmed[3].text:find("events", 1, true) ~= nil, "trimmed session's Log points to events")
eq(Journal.LastSummaryDate(), os.date("%d %b %Y", T + 50000), "last summary date")

if fails > 0 then error(fails .. " core checks failed") end
print("core harness: all checks passed")
