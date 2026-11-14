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

-- Whether the snapshot lists session s of a character, so the app has summarised it.
function Journal.IsSummarised(key, s)
    local snapChar = Journal.SnapChar(key)
    for _, sess in ipairs(snapChar and snapChar.sessions or {}) do
        if sess.s == s then return true end
    end
    return false
end

-- Whether session s is deleted: by a change in the game the app has not handled yet, else by the snapshot.
function Journal.IsDeleted(c, snapChar, s)
    local t = c and c.deleted and c.deleted[s]
    if t and (snapChar and snapChar.seenDelete and snapChar.seenDelete[s] or 0) < t then return true end
    for _, d in ipairs(snapChar and snapChar.deleted or {}) do if d == s then return true end end
    return false
end

-- A session's title: a rename in the game the app has not handled yet (or of a session not summarised yet), else
-- the title given.
function Journal.Title(c, snapChar, s, title, summarised)
    local o = c and c.titles and c.titles[s]
    if o and (not summarised or (snapChar and snapChar.seenTitle and snapChar.seenTitle[s] or 0) < (o.t or 0)) then
        return o.text
    end
    return title
end

-- The sessions of a character, newest first, without the deleted ones.
function Journal.List(c, key)
    local byS = {}
    local out = {}
    local snapChar = Journal.SnapChar(key)
    for _, s in ipairs(snapChar and snapChar.sessions or {}) do
        local item = {
            s = s.s, title = Journal.Title(c, snapChar, s.s, s.title, true), first = s.first, last = s.last, zones = s.zones or {},
            levelFrom = s.levelFrom, levelTo = s.levelTo, text = s.text, file = s.file, shots = s.shots,
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
                s = sess.s, title = Journal.Title(c, snapChar, sess.s, "Not summarised yet", false), first = sess.first, last = sess.last, zones = sess.zones,
                levelFrom = sess.levelFrom, levelTo = sess.levelTo, state = "pending", entries = sess.count,
            }
            byS[sess.s] = item
            out[#out + 1] = item
        end
    end
    local kept = {}
    for _, item in ipairs(out) do
        if not Journal.IsDeleted(c, snapChar, item.s) then kept[#kept + 1] = item end
    end
    table.sort(kept, function(a, b) return (a.s or 0) > (b.s or 0) end)
    return kept
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

-- Turns a summary's Markdown into blocks for UI.LayoutBlocks: headings in gold, bullets with a dot, emphasis marks
-- removed. A picture on its own line becomes its thumbnail with the caption under it, when the snapshot lists one for
-- it in shots (the app's thumbnails: name, thumb, w, h); otherwise it is named in a note.
function Journal.Blocks(markdown, shots)
    local thumbs = {}
    for _, shot in ipairs(shots or {}) do if shot.name then thumbs[shot.name] = shot end end
    local blocks = {}
    local para = {}
    local function flush()
        if #para > 0 then
            blocks[#blocks + 1] = { text = table.concat(para, " "), gap = 4 }
            para = {}
        end
    end
    for line in (tostring(markdown or "") .. "\n"):gmatch("(.-)\r?\n") do
        local alt, path = line:match("^%s*!%[(.-)%]%((.-)%)%s*$")
        local shot = path and thumbs[path:match("[^/\\]+$") or path]
        if shot then
            flush()
            blocks[#blocks + 1] = { image = shot.thumb, w = shot.w, h = shot.h, gap = 6 }
            blocks[#blocks + 1] = { text = GREY .. alt .. "|r", font = "GameFontHighlightSmall", gap = 0 }
            line = ""
        end
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
        for _, b in ipairs(Journal.Blocks(item.text, item.shots)) do blocks[#blocks + 1] = b end
    elseif item.state == "brief" then
        blocks[#blocks + 1] = { gap = 8, text = "This older session's summary is kept on your PC, in " .. WHITE
            .. Journal.FilePath(key, item) .. "|r." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "Its record was trimmed from the add-on and is kept under events\\ in the same folder.|r" }
    else
        blocks[#blocks + 1] = { gap = 8, text = "Not summarised yet." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "The JourneyMaster app on your PC summarises a session when you finish "
            .. "it (the Finish session button, or /jm end, then a reload), or 30 minutes after you last played once the game "
            .. "is closed. Logging out and back in within 30 minutes keeps the same session. The summary shows here at your "
            .. "next /reload or login. The Log tab shows this session's record now.|r" }
    end
    return blocks
end

-- The Overview tab's blocks: the journey so far, from the app's overview (the snapshot's overview text: one section
-- for each session, headed by its title), or a note when the app has not written one yet.
function Journal.OverviewBlocks(c, key)
    local snapChar = Journal.SnapChar(key)
    local name = c and c.name or "?"
    local blocks = { { text = GOLD .. "The journey of " .. tostring(name) .. " so far|r", font = "GameFontNormalLarge" } }
    local text = snapChar and snapChar.overview
    if text and text ~= "" then
        for _, b in ipairs(Journal.Blocks(text, nil)) do blocks[#blocks + 1] = b end
    else
        blocks[#blocks + 1] = { gap = 8, text = "No overview yet." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "The JourneyMaster app on your PC writes the overview after it summarises a session. "
            .. "It shows here at your next /reload or login.|r" }
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
        lines[#lines + 1] = TIME .. Core.Clock(e.t) .. "|r  |cff" .. Core.EntryHex(e) .. tostring(Core.Describe(e)):gsub("|", "||") .. "|r"
        if #lines == LOG_CHUNK then
            blocks[#blocks + 1] = { text = table.concat(lines, "\n"), gap = 4 }
            lines = {}
        end
    end
    if #lines > 0 then blocks[#blocks + 1] = { text = table.concat(lines, "\n"), gap = 4 } end
    return blocks
end
