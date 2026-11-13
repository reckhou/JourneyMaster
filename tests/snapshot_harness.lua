-- Offline harness for Phase 3, the contract between app and add-on: a JournalSnapshot.lua written by the app's own
-- writer (tests/fixtures/JournalSnapshot.lua, made by New-JournalSnapshotLua in src/App/JourneyMasterApp.psm1) is loaded
-- in place of the empty one the add-on ships, and the window shows its sessions under both tabs.
-- Run: python scripts/run_lua_tests.py
local W = dofile("tests/wow_stubs.lua")
local ns = W.LoadAddOn()
assert(loadfile("tests/fixtures/JournalSnapshot.lua"))("JourneyMaster", ns) -- as if the app had replaced the file
local Core, Journal = ns.Core, ns.Journal

local fails = 0
local function check(cond, msg)
    if not cond then
        fails = fails + 1
        print("FAIL: " .. msg)
    end
end
local function eq(a, b, msg) check(a == b, msg .. ": expected [" .. tostring(b) .. "], got [" .. tostring(a) .. "]") end
local function texts(blocks)
    local out = {}
    for _, b in ipairs(blocks) do out[#out + 1] = b.text end
    return table.concat(out, "\n")
end

eq(ns.journalSnapshot.revision, 7, "revision read")
local KEY = "Baldrake Cavendell-LivingFlame"
eq(ns.journalSnapshot.characters[KEY].confirmed, 68, "confirmed read")

-- Log in with entries already numbered up to 70: those up to 68 are stored by the app; the newest session stays.
W.now = 1794533400
JourneyMasterDB = { schema = 1, characters = { [KEY] = { seq = 70, session = 3, lastT = W.now - 100, entries = {
    { i = 66, s = 2, t = 1794524300, k = "login", z = "Duskwood" },
    { i = 67, s = 2, t = 1794524400, k = "level", level = 27, z = "Duskwood" },
    { i = 68, s = 2, t = 1794527000, k = "logout", z = "Duskwood" },
    { i = 69, s = 3, t = W.now - 200, k = "login", z = "Duskwood" },
    { i = 70, s = 3, t = W.now - 100, k = "note", text = "Back again", z = "Duskwood" },
}, settings = { keepSessions = 1 } } } }
W.Fire(ns, "PLAYER_LOGIN")
local c = ns.Recorder.Char()
eq(c.confirmed, 68, "confirmed taken from the snapshot")
eq(#c.entries, 2, "stored session trimmed, newest kept")

local items = Journal.List(c, KEY)
eq(#items, 3, "three sessions listed")
eq(items[1].state, "pending", "newest: not summarised yet")
eq(items[2].title, "Worgen in the Woods", "summarised title")
eq(items[2].state, "full", "summarised in full")
eq(items[3].state, "brief", "older: title only")

local j = texts(Journal.JournalBlocks(KEY, items[2]))
check(j:find("came out into Darkshire.", 1, true) ~= nil, "summary text shown, emphasis removed")
check(j:find("Screenshot: 2026-11-12_231845-level.jpg", 1, true) ~= nil, "screenshot named")
check(j:find("level 26-27", 1, true) ~= nil, "header shows levels")
check(j:find("Duskwood, Scarlet Raven Tavern", 1, true) ~= nil, "header shows zones")
local b = texts(Journal.JournalBlocks(KEY, items[3]))
check(b:find("2026-11-11-1.md", 1, true) ~= nil, "older session points to its file")
local l = texts(Journal.LogBlocks(KEY, items[2], Core.SessionEntries(c.entries, items[2].s), nil))
check(l:find("trimmed", 1, true) ~= nil, "trimmed session's Log says where the record is")
local l3 = texts(Journal.LogBlocks(KEY, items[1], Core.SessionEntries(c.entries, items[1].s), nil))
check(l3:find("Note: Back again", 1, true) ~= nil, "pending session's Log shows its entries")

-- The window: the same session is selected under both tabs.
ns.Window.Show()
ns.Window.Select(2)
eq(ns.Window.State().selected, 2, "session chosen")
ns.Window.SelectTab("log")
eq(ns.Window.State().selected, 2, "same session under the Log tab")
ns.Window.SelectTab("journal")
eq(ns.Window.State().selected, 2, "and back under the Journal tab")
check(ns.Minimap.Summary():find("Last summary: " .. os.date("%d %b %Y", 1794533300), 1, true) ~= nil, "tooltip shows the last summary date")

if fails > 0 then error(fails .. " snapshot checks failed") end
print("snapshot harness: all checks passed")
