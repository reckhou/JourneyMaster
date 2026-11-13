-- Offline harness for the whole JourneyMaster add-on: loads its files in TOC order with stand-ins for the game's API
-- (tests/wow_stubs.lua), plays through a session of events shaped like the ones the Phase 0 probe saw in game, and
-- checks the record, the settings, the commands, the window and the reload prompt.
-- Run: python scripts/run_lua_tests.py
local W = dofile("tests/wow_stubs.lua")
local ns = W.LoadAddOn()
local Core = ns.Core

local fails = 0
local function check(cond, msg)
    if not cond then
        fails = fails + 1
        print("FAIL: " .. msg)
    end
end
local function eq(a, b, msg) check(a == b, msg .. ": expected [" .. tostring(b) .. "], got [" .. tostring(a) .. "]") end
local function fire(...) W.Fire(ns, ...) end
local function last() return Core.Last(ns.Recorder.Char()) end
local function count() return #ns.Recorder.Char().entries end
local function tick(s) W.now = W.now + (s or 5) end

check(ns.frame.events.CHAT_MSG_SAY and ns.frame.events.PLAYER_DEAD and ns.frame.events.QUEST_TURNED_IN, "events registered")
check(not ns.frame.events.CHAT_MSG_WHISPER, "player whispers never registered")
check(not ns.frame.events.CHAT_MSG_CHANNEL and not ns.frame.events.CHAT_MSG_GUILD, "numbered channels and guild never registered")

-- Login ------------------------------------------------------------------------------------------------------------
JourneyMasterDB = nil
fire("PLAYER_LOGIN")
local c = ns.Recorder.Char()
check(c ~= nil, "character created")
eq(c.name, "Baldrake Cavendell", "name") eq(c.class, "Warlock", "class") eq(c.race, "Human", "race") eq(c.sex, 2, "sex")
check(JourneyMasterDB.characters["Baldrake Cavendell-LivingFlame"] == c, "saved under Name-Realm")
check(W.chatLogging, "chat logging turned on at login")
fire("PLAYER_ENTERING_WORLD", true, false)
eq(c.entries[1].k, "login", "login entry") eq(c.entries[2].k, "zone", "zone entry")
eq(c.entries[2].z, "Elwynn Forest", "zone name")
W.RunTimers() -- first visit screenshot
eq(W.shots, 1, "first visit to a zone: screenshot")
eq(last().k, "shot", "screenshot recorded")

-- Chat -------------------------------------------------------------------------------------------------------------
tick()
fire("CHAT_MSG_SAY", "Does anyone know where the Bowyer is round here?", "Shelly Whitemoon", "", "", "Shelly Whitemoon", "", 0, 0, "", 0, 1, "Player-1-AAA")
eq(last().k, "chat", "say recorded") eq(last().who, "Shelly Whitemoon", "speaker") eq(last().ch, "say", "channel")
fire("CHAT_MSG_PARTY_LEADER", "|cffff8040|Hquest:181:0|h[Look to the Stars]|h|r you do this one?", "Baldrake Cavendell")
eq(last().text, "[Look to the Stars] you do this one?", "links cleaned") eq(last().ch, "party", "party leader is party")
fire("CHAT_MSG_TEXT_EMOTE", "Jeyna Rimmer blows Norak Traax a kiss.", "Jeyna Rimmer")
check(last().stock, "stock emote marked")
c.settings.chatYell = false
local n = count()
fire("CHAT_MSG_YELL", "COME SING", "Malakar Threadbane")
eq(count(), n, "yell switched off: not recorded")
c.settings.chatYell = true
local hidden = "secret line"
W.secret[hidden] = true
fire("CHAT_MSG_PARTY", hidden, "Seph")
fire("CHAT_MSG_PARTY", hidden, "Seph")
eq(last().k, "gap", "secret chat becomes a gap") eq(last().n, 2, "gap counts lines")

-- NPC speech -------------------------------------------------------------------------------------------------------
tick()
fire("CHAT_MSG_MONSTER_SAY", "Help a poor bloke out?", "Topper McNabb")
n = count()
tick(60)
fire("CHAT_MSG_MONSTER_SAY", "Help a poor bloke out?", "Topper McNabb")
eq(count(), n, "repeated NPC line recorded once")
fire("CHAT_MSG_MONSTER_EMOTE", "%s begins translating ...", "Sirra Von'Indi", "", "", "Baldrake")
eq(last().text, "Sirra Von'Indi begins translating ...", "NPC emote names its speaker")
c.settings.npcSpeech = false
n = count()
fire("CHAT_MSG_MONSTER_YELL", "Forward!", "Town Crier")
eq(count(), n, "NPC speech switched off")
c.settings.npcSpeech = true

-- Quests -----------------------------------------------------------------------------------------------------------
tick()
W.quest = { title = "Worgen in the Woods", text = "Here you go, Baldrake. Bring this message to Master Carevin.",
    obj = "Kill 6 Nightbane Shadow Weavers.", giver = "Calor", byId = { [223] = "Worgen in the Woods" } }
fire("QUEST_DETAIL")
fire("QUEST_ACCEPTED", 223)
local q = last()
eq(q.k, "quest", "quest entry") eq(q.act, "accept", "accepted") eq(q.giver, "Calor", "giver")
eq(q.text, "Here you go, Baldrake. Bring this message to Master Carevin.", "quest text kept")
eq(q.obj, "Kill 6 Nightbane Shadow Weavers.", "objective kept") eq(q.id, 223, "quest id")
tick()
W.quest = { title = "Worgen in the Woods", giver = "Jonathan Carevin", reward = "You have done well.", byId = {} }
fire("QUEST_COMPLETE")
fire("QUEST_TURNED_IN", 223, 3150, 0)
q = last()
eq(q.act, "turnin", "handed in") eq(q.title, "Worgen in the Woods", "title from the hand-in window")
eq(q.giver, "Jonathan Carevin", "hand-in NPC") eq(q.xp, 3150, "xp") eq(q.reward, "You have done well.", "reward text")

-- Deaths -----------------------------------------------------------------------------------------------------------
tick()
W.zone, W.sub = "Duskwood", ""
fire("ZONE_CHANGED_NEW_AREA")
W.RunTimers()
W.recap[1] = { { timestamp = 5, sourceName = "Stitches", event = "SWING_DAMAGE", overkill = 120 } }
fire("PLAYER_DEAD")
W.RunTimers()
eq(last().k, "death", "death recorded") eq(last().killer, "Stitches", "killer from the death recap")
eq(last().recap, "ok", "recap state") eq(last().z, "Duskwood", "place of death")
tick()
W.recap[2] = { { timestamp = 9, sourceName = "Nightbane Shadow Weaver", spellName = "Shadow Bolt", event = "SPELL_DAMAGE", overkill = 3 } }
fire("PLAYER_DEAD")
W.RunTimers()
eq(last().killer, "Nightbane Shadow Weaver", "second death reads the newer recap") eq(last().spell, "Shadow Bolt", "spell")
tick()
fire("PLAYER_DEAD")
W.RunTimers()
eq(last().killer, nil, "no new recap: no killer invented") eq(last().recap, "empty", "recap state empty")

-- Dungeon entry and exit, bosses --------------------------------------------------------------------------------------
tick()
W.instance, W.name, W.zone = { true, "party" }, "The Stockade", "The Stockade"
fire("PLAYER_ENTERING_WORLD", false, false)
local enter
for i = #c.entries, 1, -1 do if c.entries[i].k == "enter" then enter = c.entries[i] break end end
check(enter and enter.inst == "The Stockade", "dungeon entry recorded")
tick()
fire("BOSS_KILL", 1, "Bazil Thredd")
fire("ENCOUNTER_END", 1, "Bazil Thredd", 1, 5, 1)
local bosses = 0
for _, e in ipairs(c.entries) do if e.k == "boss" then bosses = bosses + 1 end end
eq(bosses, 1, "one boss kill recorded once")
tick()
W.instance, W.name, W.zone = { false, "none" }, "Eastern Kingdoms", "Stormwind City"
fire("PLAYER_ENTERING_WORLD", false, false)
local leave
for i = #c.entries, 1, -1 do if c.entries[i].k == "leave" then leave = c.entries[i] break end end
check(leave and leave.inst == "The Stockade", "dungeon exit recorded")

-- Level, loot, gear, group, progress ---------------------------------------------------------------------------------
tick(20)
fire("PLAYER_LEVEL_UP", 27)
eq(last().k, "level", "level entry")
fire("TIME_PLAYED_MSG", 360000, 3000)
eq(last().played, 360000, "played time on the level entry")
fire("CHAT_MSG_LOOT", "You receive loot: |cff0070dd|Hitem:1|h[Cutlass]|h|r.")
eq(last().item, "[Cutlass]", "rare loot recorded") eq(last().q, 3, "quality")
n = count()
fire("CHAT_MSG_LOOT", "You receive loot: |cff1eff00|Hitem:2|h[Boots]|h|r.")
fire("CHAT_MSG_LOOT", "Seph Stormbrewer receives loot: |cffa335ee|Hitem:3|h[Epic]|h|r.")
eq(count(), n, "uncommon loot and other players' loot not recorded")
tick(20)
W.gear = { [5] = "|cff1eff00|Hitem:9|h[Green Robe]|h|r" }
fire("PLAYER_EQUIPMENT_CHANGED", 5, false)
eq(last().item, "[Green Robe]", "gear change recorded") eq(last().slot, "chest", "slot")
W.group = { "Magiczny Krzysztof" }
fire("GROUP_ROSTER_UPDATE")
eq(last().k, "group", "group entry") eq(last().act, "join", "join") eq(last().who, "Magiczny Krzysztof", "member")
W.group = {}
fire("GROUP_ROSTER_UPDATE")
eq(last().act, "leave", "leave")
W.money = 123456
fire("PLAYER_MONEY")
eq(last().k, "money", "money milestone") eq(last().copper, 100000, "10 gold")
n = count()
fire("PLAYER_MONEY")
eq(count(), n, "same milestone once")
fire("CHAT_MSG_SKILL", "Your skill in Tailoring has increased to 75.")
eq(last().skill, "Tailoring", "skill milestone")
n = count()
fire("CHAT_MSG_SKILL", "Your skill in Tailoring has increased to 76.")
eq(count(), n, "skill between milestones ignored")
fire("CHAT_MSG_SYSTEM", "You are now Friendly with Stormwind.")
eq(last().k, "rep", "standing change") eq(last().standing, "Friendly", "standing")

-- Commands -------------------------------------------------------------------------------------------------------------
ns.Command("note Met an old friend in the Trade District")
eq(last().k, "note", "note command") eq(last().text, "Met an old friend in the Trade District", "note text")
ns.Command("keep 3")
eq(c.settings.keepSessions, 3, "keep command")
ns.Command("minimap")
eq(c.settings.minimapButton, false, "minimap hidden")
check(not ns.Minimap.button().shown, "button hidden")
ns.Command("minimap")
check(ns.Minimap.button().shown, "button shown again")
ns.Command("help")
check(#W.chat >= #ns.HELP, "help listed")

-- Reload and logout ------------------------------------------------------------------------------------------------------
tick()
local sessionBefore = c.session
fire("PLAYER_LOGOUT")
eq(last().k, "logout", "logout entry")
fire("PLAYER_ENTERING_WORLD", false, true)
local kinds = {}
for i = #c.entries - 1, #c.entries do kinds[#kinds + 1] = c.entries[i].k end
check(kinds[1] ~= "logout", "a reload removes the logout PLAYER_LOGOUT left")
eq(last().k ~= nil and c.entries[#c.entries].s, sessionBefore, "a reload stays in the session")

-- Window -----------------------------------------------------------------------------------------------------------------
ns.Command("")
check(ns.Window.IsShown(), "window opens")
local st = ns.Window.State()
eq(st.tab, "journal", "Journal tab first")
eq(#st.items, 1, "one session listed")
eq(st.items[1].state, "pending", "not summarised yet")
ns.Window.SelectTab("log")
ns.Window.SetChip("chat", false)
eq(ns.Window.State().filter.chat, false, "chip hides chat")
ns.Window.SelectTab("settings")
ns.Window.SelectTab("journal")
ns.Command("")
check(not ns.Window.IsShown(), "window closes")
ns.Command("log")
eq(ns.Window.State().tab, "log", "/jm log opens the Log tab")

-- Snapshot: summaries shown, stored entries trimmed at the next login -----------------------------------------------------
local s1 = c.entries[1].s
ns.journalSnapshot = { schema = 1, revision = 1, written = W.now, characters = {
    ["Baldrake Cavendell-LivingFlame"] = { confirmed = c.seq, sessions = {
        { s = s1, title = "Duskwood by night", first = c.entries[1].t, last = W.now, zones = { "Elwynn Forest", "Duskwood" }, text = "# Duskwood by night\n\nBaldrake went to Duskwood." } } } } }
ns.Window.Refresh()
st = ns.Window.State()
eq(st.items[1].state, "full", "summary from the snapshot")
eq(st.items[1].title, "Duskwood by night", "summary title")
-- Screenshots: a picture with a thumbnail becomes an image block with its caption; one without stays a note.
local shotBlocks = ns.Journal.Blocks("Text.\n\n![Level up, 21:02](../screenshots/a.jpg)\n\n![Boss, 22:00](../screenshots/b.jpg)\n",
    { { name = "a.jpg", thumb = "Interface\\AddOns\\JourneyMaster\\Thumbs\\X\\a", w = 455, h = 256 } })
eq(shotBlocks[2].image, "Interface\\AddOns\\JourneyMaster\\Thumbs\\X\\a", "thumbnail shown")
eq(shotBlocks[2].w, 455, "thumbnail width")
check(shotBlocks[3].text:find("Level up, 21:02", 1, true), "caption under the thumbnail")
check(shotBlocks[4].text:find("[Screenshot: b.jpg]", 1, true), "picture without a thumbnail named")
ns.journalSnapshot.characters["Baldrake Cavendell-LivingFlame"].sessions[1].shots = { { name = "a.jpg", thumb = "T\\a", w = 455, h = 256 } }
ns.journalSnapshot.characters["Baldrake Cavendell-LivingFlame"].sessions[1].text = "Went.\n\n![Level up, 21:02](../screenshots/a.jpg)\n"
ns.Window.Select(s1)
ns.Window.SelectTab("journal")
eq(#ns.Window.State().items[1].shots, 1, "shots reach the session list")
ns.Window.RequestShots()
eq(c.openShots.s, s1, "open request names the session")
eq(c.openShots.t, W.now, "open request carries its time")
eq(W.popup, "JOURNEYMASTER_OPEN_SHOTS", "reload offered for the open request")
-- A new session starts; at the next login the stored session is trimmed, as it is no longer among the newest kept.
c.settings.keepSessions = 1
tick(4000)
fire("PLAYER_ENTERING_WORLD", true, false)
local s2 = c.session
eq(s2, s1 + 1, "new login, new session")
local before = #c.entries
fire("PLAYER_LOGIN")
eq(c.entries[1].s, s2, "stored entries of the older session trimmed at login")
check(#c.entries < before and c.trimmed > 0, "trimmed counted")
ns.Window.Refresh()
st = ns.Window.State()
eq(#st.items, 2, "summarised session and new session both listed")
eq(st.items[2].entries, 0, "trimmed session has no entries left in the add-on")
ns.Window.SelectTab("log")
ns.Window.Select(s1)

-- Reload prompt ------------------------------------------------------------------------------------------------------------
c.settings.reloadPrompt = true
c.sinceReload = W.now - 3 * 3600
W.ticker()
eq(W.popup, "JOURNEYMASTER_RELOAD", "reload offered after a long session")
StaticPopupDialogs.JOURNEYMASTER_RELOAD.OnAccept()
eq(W.reloads, 1, "accepting reloads")

-- Errors are reported, never hidden ---------------------------------------------------------------------------------------
eq(#ns.Recorder.errors, 0, "no errors in the normal run")
W.chat = {}
local realOnEvent = ns.Recorder.OnEvent
ns.Recorder.OnEvent = function() error("boom") end
fire("PLAYER_MONEY")
fire("PLAYER_MONEY")
ns.Recorder.OnEvent = realOnEvent
eq(#W.chat, 1, "a new error is said in chat once")
check(W.chat[1] and W.chat[1]:find("PLAYER_MONEY", 1, true) and W.chat[1]:find("boom", 1, true), "chat line names the event and the error")
eq(#ns.Recorder.errors, 1, "repeats are one error") eq(ns.Recorder.errors[1].count, 2, "repeats counted")
local realShot = Screenshot
Screenshot = function() error("no screenshot") end
c.settings.screenshots = true
n = count()
ns.Recorder.Shot("level")
W.RunTimers()
Screenshot = realShot
eq(count(), n, "failed screenshot not recorded")
eq(#ns.Recorder.errors, 2, "failed screenshot reported")
W.chat = {}
ns.Command("errors")
eq(#W.chat, 2, "/jm errors lists each error")
check(W.chat[1]:find("2 times", 1, true), "/jm errors gives the count")

-- Minimap placement --------------------------------------------------------------------------------------------------------
local x, y = ns.Minimap.Offset(0, 70, false)
check(math.abs(x - 75) < 0.01 and math.abs(y) < 0.01, "button on the circle")
x, y = ns.Minimap.Offset(45, 70, true)
check(math.abs(x - 75) < 0.01 and math.abs(y - 75) < 0.01, "button on a square minimap's corner")
eq(math.floor(ns.Minimap.Angle(0, 10) + 0.5), 90, "angle")

if fails > 0 then error(fails .. " add-on checks failed") end
print("add-on harness: all checks passed")
