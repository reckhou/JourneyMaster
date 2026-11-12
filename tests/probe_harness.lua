-- Offline harness for JourneyProbe: stubs the few game functions it uses and fires events.
-- Run with: python scripts/run_lua_tests.py
time, date = os.time, os.date
local inInstance, instType, lockdown = false, "none", false
IsInInstance = function() return inInstance, instType end
C_ChatInfo = { InChatMessagingLockdown = function() return lockdown end }
GetRealZoneText = function() return "Elwynn Forest" end
GetSubZoneText = function() return "Goldshire" end
GetTitleText = function() return "A Fine Quest" end
GetQuestText = function() return "Bring me three boars." end
UnitName = function(u) return u == "questnpc" and "Marshal Dughan" or nil end
UnitGUID = function() return "Player-1-AAA" end
local secret = {}
issecretvalue = function(v) return secret[v] == true end
LoggingChat = (function() local on = false return function(v) if v ~= nil then on = v end return on end end)()
GetBuildInfo = function() return "1.60.1", "70532", "Nov 1 2026", 16001 end

dofile("src/JourneyProbe/JourneyProbe.lua")
local P = JourneyProbe
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end end

-- Helpers
check(P.Readable("x"), "plain string readable")
secret["hidden"] = true
check(not P.Readable("hidden"), "secret string unreadable")
check(P.Sample("hidden") == nil, "secret has no sample")
check(#P.Sample(string.rep("a", 200)) == 83, "sample truncated to 80 + ...")
check(P.GuidKind("Creature-0-1-2") == "Creature", "guid kind")
check(P.GuidKind("hidden") == nil, "secret guid has no kind")
check(P.CountKey("E", "raid", true, "secret") == "E|raid|lock|secret", "count key")
check(P.Stamp(os.time{year=2026, month=11, day=8, hour=21, min=15, sec=3}) == "11/8 21:15:03", "stamp matches chat-log style")

-- Login: loads increment across a simulated file round trip
JourneyProbeDB = nil
P.OnLogin()
check(JourneyProbeDB.loads == 1, "first load is 1")
local saved = JourneyProbeDB          -- the game would write this table to disk and read it back
JourneyProbeDB = saved
P.OnLogin()
check(JourneyProbeDB.loads == 2, "second load is 2")
check(JourneyProbeDB.log[2].previousLoads == 1, "login entry records previousLoads")
check(JourneyProbeDB.log[1].chatLoggingNow == true, "chat logging turned on")
check(JourneyProbeDB.api["issecretvalue"] == "function", "api table lists issecretvalue")
check(JourneyProbeDB.api["C_DeathRecap.GetRecapLink"] == "missing", "missing api reported")

-- Chat: open world readable, then dungeon lockdown with secret text
P.chatSet = { CHAT_MSG_SAY = "chat", CHAT_MSG_COMBAT_HOSTILE_DEATH = "death" }
P.OnEvent(nil, "CHAT_MSG_SAY", "hello there", "Alice", "", "", "", "", 0, 0, "", 0, 1, "Player-1-BBB")
local e = JourneyProbeDB.log[#JourneyProbeDB.log]
check(e.chat == "CHAT_MSG_SAY" and e.text == "hello there" and e.whoOk and e.guidKind == "Player", "open-world chat recorded")
inInstance, instType, lockdown = true, "party", true
P.OnEvent(nil, "CHAT_MSG_SAY", "hidden", "hidden", "", "", "", "", 0, 0, "", 0, 1, "hidden")
e = JourneyProbeDB.log[#JourneyProbeDB.log]
check(e.textOk == false and e.text == nil and e.inst == "party" and e.lock == true, "lockdown chat recorded as unreadable")
check(JourneyProbeDB.counts["CHAT_MSG_SAY|party|lock|secret"] == 1, "lockdown counter")
check(JourneyProbeDB.counts["CHAT_MSG_SAY|none|open|text"] == 1, "open counter")
-- Sampling cap: the 26th unreadable line is counted but not stored
local before = #JourneyProbeDB.log
for _ = 1, 40 do P.OnEvent(nil, "CHAT_MSG_SAY", "hidden", "hidden", "", "", "", "", 0, 0, "", 0, 1, "hidden") end
check(#JourneyProbeDB.log - before == 24, "only the first 25 unreadable lines are stored")

-- Quest text
inInstance, instType, lockdown = false, "none", false
P.OnEvent(nil, "QUEST_DETAIL")
e = JourneyProbeDB.log[#JourneyProbeDB.log]
check(e.GetQuestText.ok and e.GetQuestText.len == 21 and e.questnpc == "Marshal Dughan", "quest text and giver recorded")
check(e.GetGreetingText.ok == true and e.GetGreetingText.type == "nil" or e.GetGreetingText.ok == false, "missing getter reported, no error")

-- Death with last hit, boss, zone change
P.OnEvent(nil, "PLAYER_DEAD")
check(JourneyProbeDB.log[#JourneyProbeDB.log].ev == "death", "death recorded")
P.OnEvent(nil, "BOSS_KILL", 639, "Edwin VanCleef", 1, 5)
e = JourneyProbeDB.log[#JourneyProbeDB.log]
check(e.ev == "boss" and e.name == "Edwin VanCleef", "boss kill recorded")
inInstance, instType = true, "party"
P.OnEvent(nil, "PLAYER_ENTERING_WORLD", false, false)
check(JourneyProbeDB.log[#JourneyProbeDB.log].changed == true, "entering an instance is marked as a change")

-- Cap
JourneyProbeDB.log = {}
for i = 1, 30001 do P.Record("mark", { note = "x" }) end
check(#JourneyProbeDB.log == 30000 and JourneyProbeDB.dropped == 1, "log capped, overflow counted")
print("probe harness passed")
