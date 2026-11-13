-- JourneyMaster journal model: the session list that drives both tabs of the window. It joins the app's snapshot
-- (JournalSnapshot.lua: summaries, newest in full and older ones by date and title only) with the sessions still in the
-- add-on's own record. No widget code here, so tests/addon_harness.lua can check it offline.
--
-- A listed session has: s (session number), title, first and last (epoch seconds), zones, levelFrom and levelTo,
-- state ("full": summary text in the snapshot; "brief": summarised, text only on the PC; "pending": recorded, not yet
-- summarised), text, file (the Markdown file's path under the app's data folder) and entries (count in the add-on).
local _, ns = ...
local Core = ns.Core
local Journal = {}
ns.Journal = Journal

Journal.DATA_HINT = "data\\journeys\\"

local function snapshot() return ns.journalSnapshot or { characters = {} } end

-- The snapshot's part for a character key, or nil.
function Journal.SnapChar(key)
    local snap = snapshot()
    return snap.characters and snap.characters[key] or nil
end

-- The sessions of a character, newest first.
function Journal.List(c, key)
    local byS = {}
    local out = {}
    local snapChar = Journal.SnapChar(key)
    for _, s in ipairs(snapChar and snapChar.sessions or {}) do
        local item = {
            s = s.s, title = s.title, first = s.first, last = s.last, zones = s.zones or {},
            levelFrom = s.levelFrom, levelTo = s.levelTo, text = s.text, file = s.file,
            state = s.text and "full" or "brief", entries = 0,
        }
        byS[s.s] = item
        out[#out + 1] = item
    end
    for _, sess in ipairs(Core.Sessions(c and c.entries or {})) do
        local item = byS[sess.s]
        if item then
            item.entries = sess.count
        else
            item = {
                s = sess.s, title = "Not summarised yet", first = sess.first, last = sess.last, zones = sess.zones,
                levelFrom = sess.levelFrom, levelTo = sess.levelTo, state = "pending", entries = sess.count,
            }
            byS[sess.s] = item
            out[#out + 1] = item
        end
    end
    table.sort(out, function(a, b) return (a.s or 0) > (b.s or 0) end)
    return out
end

-- "12 Nov 2026" of the newest summary in the snapshot (any character), or nil.
function Journal.LastSummaryDate()
    local newest
    for _, sc in pairs(snapshot().characters or {}) do
        for _, s in ipairs(sc.sessions or {}) do
            if s.last and (not newest or s.last > newest) then newest = s.last end
        end
    end
    local written = tonumber(snapshot().written) or 0
    if written > 0 then return Core.Clock(written, "%d %b %Y") end
    return newest and Core.Clock(newest, "%d %b %Y") or nil
end

-- The header under a session's title.
function Journal.Header(item)
    return Core.SessionHeader({ first = item.first or 0, last = item.last or item.first or 0, zones = item.zones or {},
        levelFrom = item.levelFrom, levelTo = item.levelTo })
end

-- The path of a session's Markdown file on the PC.
function Journal.FilePath(key, item)
    if item.file then return item.file end
    return Journal.DATA_HINT .. key .. "\\sessions\\"
end

-- Colours of the mock-up (docs/mockups/journey-window.html): titles, notes, paths and Log times. Body text takes
-- the mock-up's parchment white from UI.LayoutBlocks.
local GOLD, GREY, WHITE, TIME = "|cffffd100", "|cffa8997a", "|cffffffff", "|cff7d7260"

-- Turns a summary's Markdown into text blocks for UI.LayoutBlocks: headings in gold, bullets with a dot, emphasis
-- marks removed, pictures as a note. The game cannot show the pictures, so they are named instead.
function Journal.Blocks(markdown)
    local blocks = {}
    local para = {}
    local function flush()
        if #para > 0 then
            blocks[#blocks + 1] = { text = table.concat(para, " "), gap = 4 }
            para = {}
        end
    end
    for line in (tostring(markdown or "") .. "\n"):gmatch("(.-)\r?\n") do
        line = line:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
        line = line:gsub("!%[(.-)%]%((.-)%)", function(alt, path)
            return GREY .. "[Screenshot: " .. (path:match("[^/\\]+$") or path) .. "]|r"
        end)
        line = line:gsub("%[(.-)%]%((.-)%)", "%1")
        local level, heading = line:match("^(#+)%s+(.*)$")
        if heading then
            flush()
            blocks[#blocks + 1] = { text = GOLD .. heading .. "|r", font = #level <= 1 and "GameFontNormalLarge" or "GameFontNormal", gap = 8 }
        elseif line:match("^%s*[-*]%s+") then
            flush()
            blocks[#blocks + 1] = { text = "\226\128\162 " .. line:gsub("^%s*[-*]%s+", ""), gap = 0 }
        elseif line:match("^%s*$") then
            flush()
        else
            para[#para + 1] = line
        end
    end
    flush()
    return blocks
end

-- The Journal tab's blocks for a session.
function Journal.JournalBlocks(key, item)
    local blocks = {
        { text = GOLD .. tostring(item.title) .. "|r", font = "GameFontNormalLarge" },
        { text = GREY .. Journal.Header(item) .. "|r", font = "GameFontHighlightSmall" },
    }
    if item.state == "full" then
        for _, b in ipairs(Journal.Blocks(item.text)) do blocks[#blocks + 1] = b end
    elseif item.state == "brief" then
        blocks[#blocks + 1] = { gap = 8, text = "This older session's summary is kept on your PC, in " .. WHITE
            .. Journal.FilePath(key, item) .. "|r." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "Its record was trimmed from the add-on and is kept under events\\ in the same folder.|r" }
    else
        blocks[#blocks + 1] = { gap = 8, text = "Not summarised yet." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "The summary arrives at the next /reload or login after the session ends "
            .. "(a logout, or 30 minutes without play) and the JourneyMaster app on your PC has run. "
            .. "The Log tab shows this session's record now.|r" }
    end
    return blocks
end

local LOG_CHUNK = 40 -- Log lines per text block

-- The Log tab's blocks for a session: its entries that pass the filter, one line each with the time.
function Journal.LogBlocks(key, item, entries, filter)
    local blocks = {
        { text = GOLD .. tostring(item.title) .. "|r", font = "GameFontNormalLarge" },
        { text = GREY .. Journal.Header(item) .. "|r", font = "GameFontHighlightSmall" },
    }
    local shown = Core.Filter(entries or {}, filter)
    if #(entries or {}) == 0 then
        blocks[#blocks + 1] = { gap = 8, text = "This session's record was trimmed from the add-on after the app stored it. "
            .. "It is kept on your PC under " .. WHITE .. Journal.DATA_HINT .. key .. "\\events\\|r." }
        return blocks
    end
    if #shown == 0 then
        blocks[#blocks + 1] = { gap = 8, text = GREY .. "No entries of the chosen kinds.|r" }
        return blocks
    end
    local lines = {}
    for _, e in ipairs(shown) do
        local colour = Core.KIND_COLOUR[Core.Chip(e)] or "e8dcc0"
        lines[#lines + 1] = TIME .. Core.Clock(e.t) .. "|r  |cff" .. colour .. tostring(Core.Describe(e)):gsub("|", "||") .. "|r"
        if #lines == LOG_CHUNK then
            blocks[#blocks + 1] = { text = table.concat(lines, "\n"), gap = 4 }
            lines = {}
        end
    end
    if #lines > 0 then blocks[#blocks + 1] = { text = table.concat(lines, "\n"), gap = 4 } end
    return blocks
end
