-- JourneyMaster journal model: the session list that drives both tabs of the window. It joins the app's snapshot
-- (JournalSnapshot.lua: summaries, newest in full and older ones by date and title only) with the sessions still in the
-- add-on's own record. No widget code here, so tests/addon_harness.lua can check it offline.
--
-- A listed session has: s (session number), title, first and last (epoch seconds), zones, levelFrom and levelTo,
-- state ("full": summary text in the snapshot; "brief": summarised, text only on the PC; "pending": recorded, not yet
-- summarised), requested (a pending session whose summary was asked for a few minutes ago), inProgress (a pending session
-- that has not been finished), text, file (the Markdown file's path under the app's data folder) and entries (count in the
-- add-on).
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
                requested = Core.SummaryRequested(c, sess.s, time()),
                inProgress = c ~= nil and sess.s == c.session and not c.endSession,
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
            blocks[#blocks + 1] = { text = table.concat(para, " "), gap = 4, para = true }
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
            blocks[#blocks + 1] = { text = GOLD .. heading .. "|r", font = #level <= 1 and "GameFontNormalLarge" or "GameFontNormal", gap = 8, heading = #level }
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

-- Pages ---------------------------------------------------------------------------------------------------------------
-- A long text is shown one page at a time. A page is a run of whole blocks; a page taller than the window scrolls inside
-- itself. Pages are cut by content (words), never by the height of the window, so the same text always gives the same
-- pages. See docs/plans/journal-paging.md.
Journal.PAGE = {
    summaryWords = 1000,    -- a session summary: about this many words a page
    overviewWords = 2000,   -- the Overview: at most this many words a page, and
    overviewSections = 3,   --   at most this many whole sessions (a session's section is never split)
    logWords = 1500,        -- the Log
    imageWords = 100,       -- a picture counts as this many words
    tailShare = 0.3,        -- a last page under this share of a page is joined to the one before
}

-- The words in a block (colour codes are not words); a picture counts as PAGE.imageWords.
function Journal.BlockWords(b)
    if b.image then return Journal.PAGE.imageWords end
    local s = tostring(b.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local n = 0
    for _ in s:gmatch("%S+") do n = n + 1 end
    return n
end

local function wordsOf(blocks)
    local n = 0
    for _, b in ipairs(blocks) do n = n + Journal.BlockWords(b) end
    return n
end

-- Pages of about `limit` words, cut between blocks. A heading stays with the block after it, and a picture with its
-- caption. A last page smaller than tailShare of a page is joined to the one before it.
local function packBlocks(blocks, limit)
    local pages, page, words = {}, {}, 0
    for _, b in ipairs(blocks) do
        local w = Journal.BlockWords(b)
        local last = page[#page]
        if #page > 0 and words + w > limit and not (last and (last.heading or last.image)) then
            pages[#pages + 1] = page
            page, words = {}, 0
        end
        page[#page + 1] = b
        words = words + w
    end
    if #page > 0 then pages[#pages + 1] = page end
    if #pages > 1 and wordsOf(pages[#pages]) < Journal.PAGE.tailShare * limit then
        local tail = table.remove(pages)
        for _, b in ipairs(tail) do pages[#pages][#pages[#pages] + 1] = b end
    end
    return pages
end

-- Pages of whole sections. A section starts at a heading block of the given level; the blocks before the first one
-- (the Overview's title line) go with the first section. A page takes sections while it holds fewer than maxSections
-- and stays within `limit` words; a section too big for that has a page to itself.
local function packSections(blocks, limit, maxSections, level)
    local units, cur = {}, nil
    for _, b in ipairs(blocks) do
        if not cur or (b.heading == level and cur.started) then
            cur = {}
            units[#units + 1] = cur
        end
        if b.heading == level then cur.started = true end
        cur[#cur + 1] = b
    end
    local pages, page, words, n = {}, {}, 0, 0
    for _, u in ipairs(units) do
        local w = wordsOf(u)
        if #page > 0 and (n >= maxSections or words + w > limit) then
            pages[#pages + 1] = page
            page, words, n = {}, 0, 0
        end
        for _, b in ipairs(u) do page[#page + 1] = b end
        words, n = words + w, n + 1
    end
    if #page > 0 then pages[#pages + 1] = page end
    return pages
end

-- The pages of a tab's blocks ("journal", "overview" or "log"): a list of lists of blocks, never empty.
function Journal.PagesFor(tab, blocks)
    local P = Journal.PAGE
    local pages
    if tab == "overview" then
        local sections = false
        for _, b in ipairs(blocks) do if b.heading == 2 then sections = true break end end
        pages = sections and packSections(blocks, P.overviewWords, P.overviewSections, 2) or packBlocks(blocks, P.overviewWords)
    elseif tab == "log" then
        pages = packBlocks(blocks, P.logWords)
    else
        pages = packBlocks(blocks, P.summaryWords)
    end
    if #pages == 0 then pages = { {} } end
    return pages
end

-- What the page bar shows for page `current` of `total`: page numbers, and "gap" where some are left out, for example
-- 1 gap 5 6 7 gap 12. The first page, the last page and the current page with its neighbours always show.
function Journal.PageNumbers(current, total)
    local keep = {}
    for _, n in ipairs({ 1, total, current - 1, current, current + 1 }) do
        if n >= 1 and n <= total then keep[n] = true end
    end
    local out, previous = {}, 0
    for n = 1, total do
        if keep[n] then
            if n - previous == 2 then out[#out + 1] = n - 1 end -- a gap of one number shows the number
            if n - previous > 2 then out[#out + 1] = "gap" end
            out[#out + 1] = n
            previous = n
        end
    end
    return out
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
    elseif item.requested then
        blocks[#blocks + 1] = { gap = 8, text = "Summary requested." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "The app on your PC is writing it, which takes a few minutes. When the app says it has "
            .. "finished, click Reload to see it here. If nothing arrives, check that the app is running: the Summarise button "
            .. "comes back after ten minutes.|r" }
    elseif item.inProgress then
        blocks[#blocks + 1] = { gap = 8, text = "Not summarised yet." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "This session is still in progress, and only a finished session can be summarised. Click "
            .. "Finish session (below, or /jm end): it ends this session and starts a new one. Then click Summarise. Nothing is "
            .. "summarised on its own. The Log tab shows this session's record now.|r" }
    else
        blocks[#blocks + 1] = { gap = 8, text = "Not summarised yet." }
        blocks[#blocks + 1] = { gap = 4, text = GREY .. "Nothing is summarised on its own. Click Summarise (below) and the app on your PC "
            .. "writes this session's summary. The button reloads the interface so the game writes the record to disk. The app must "
            .. "be running, and can stay in the background. The summary shows here after one more reload. The Log tab shows this "
            .. "session's record now.|r" }
    end
    return blocks
end

-- The Overview tab's blocks: the journey so far, from the app's overview (the snapshot's overview text: one section
-- for each session, headed by its title, with one picture, whose thumbnails are the snapshot's overviewShots), or a note when the app has not written one yet.
function Journal.OverviewBlocks(c, key)
    local snapChar = Journal.SnapChar(key)
    local name = c and c.name or "?"
    local blocks = { { text = GOLD .. "The journey of " .. tostring(name) .. " so far|r", font = "GameFontNormalLarge" } }
    local text = snapChar and snapChar.overview
    if text and text ~= "" then
        for _, b in ipairs(Journal.Blocks(text, snapChar.overviewShots)) do blocks[#blocks + 1] = b end
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
