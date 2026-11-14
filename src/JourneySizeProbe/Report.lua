-- JourneySizeProbe, last file: checks what arrived, prints and records the result, and tests how the game draws it.
--
-- Commands: /jmsize (check again), /jmsize show <name> (one font string), /jmsize blocks <name> (stacked paragraphs), /jmsize hide.
-- The result goes to the chat window and, after /reload or logout, to JourneySizeProbeDB; run
-- scripts\size_probe.py report to read it.
local _, ns = ...
ns.Stamp("report")

local MOD, WEIGHTS = 65521, 251

-- A checksum that depends on every byte and its place, so a cut, a repeat or a changed byte shows. The generator
-- (scripts/size_probe.py) computes the same number.
function ns.Checksum(s)
    local sum, n = 0, #s
    for i = 1, n, 4096 do
        local bytes = { s:byte(i, math.min(i + 4095, n)) }
        for j = 1, #bytes do
            sum = (sum + bytes[j] * ((i + j - 2) % WEIGHTS + 1)) % MOD
        end
    end
    return sum
end

local function out(msg)
    local line = "|cff66ccffJourneySizeProbe|r " .. msg
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(line) else print(line) end
end
ns.out = out

local function stampTimes(name)
    for i, s in ipairs(ns.stamps) do
        if s.name == name then return s, ns.stamps[i - 1] end
    end
end

-- Compares every level the manifest lists with what loaded. Returns the record that is also saved.
function ns.Run()
    local db = { levels = {}, display = (ns.db and ns.db.display) or {} }
    if GetBuildInfo then
        local version, build, _, toc = GetBuildInfo()
        db.build = { version = version, build = build, toc = toc }
    end
    for _, want in ipairs(ns.expected or {}) do
        local r = { name = want.name, expectedBytes = want.textBytes, sourceBytes = want.sourceBytes }
        local text = ns.text[want.name]
        r.loaded = text ~= nil
        local here, before = stampTimes(want.name)
        if here and before then r.parseMs = here.t - before.t end
        if text then
            r.bytes = #text
            r.lenOk = (#text == want.textBytes)
            local t0 = ns.now()
            r.sumOk = (ns.Checksum(text) == want.sum)
            r.checksumMs = ns.now() - t0
        end
        db.levels[#db.levels + 1] = r
    end
    local first, last = ns.stamps[1], ns.stamps[#ns.stamps]
    if first and last then
        db.totalLoadMs = last.t - first.t
        db.memStartKB, db.memEndKB = first.mem, last.mem
    end
    if GetAddOnMemoryUsage then
        if UpdateAddOnMemoryUsage then pcall(UpdateAddOnMemoryUsage) end
        local ok, kb = pcall(GetAddOnMemoryUsage, "JourneySizeProbe")
        if ok then db.addonMemKB = kb end
    end
    db.stamps = ns.stamps
    ns.db = db
    JourneySizeProbeDB = db
    return db
end

function ns.Print(db)
    out(string.format("Loaded in %.0f ms; the add-on holds %.0f KB. One line for each level:", db.totalLoadMs or 0, db.addonMemKB or db.memEndKB or 0))
    for _, r in ipairs(db.levels) do
        local verdict = (not r.loaded) and "|cffff4040DID NOT LOAD|r"
            or ((r.lenOk and r.sumOk) and "|cff40ff40intact|r" or "|cffff4040ARRIVED CHANGED|r")
        out(string.format("%s: text %s bytes, file %s bytes, read in %s ms, %s",
            r.name, tostring(r.bytes or r.expectedBytes), tostring(r.sourceBytes),
            r.parseMs and string.format("%.0f", r.parseMs) or "?", verdict))
    end
    out("To see how the game draws a level: /jmsize show <name> or /jmsize blocks <name>. Then scroll to the end: the last line should read END MARKER.")
end

-- The scroll window both window tests draw in (made once).
local function getWindow()
    if not ns.window then
        local f = CreateFrame("Frame", "JourneySizeProbeWindow", UIParent)
        f:SetSize(560, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.9)
        local scroll = CreateFrame("ScrollFrame", "JourneySizeProbeScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 8, -8)
        scroll:SetPoint("BOTTOMRIGHT", -28, 8)
        local child = CreateFrame("Frame", nil, scroll)
        child:SetSize(500, 10)
        scroll:SetScrollChild(child)
        local fs = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetWidth(500)
        fs:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
        if UISpecialFrames then table.insert(UISpecialFrames, "JourneySizeProbeWindow") end
        ns.window = { frame = f, scroll = scroll, child = child, fs = fs, pool = {} }
    end
    return ns.window
end

local function saveDisplay(r)
    ns.db = ns.db or JourneySizeProbeDB or { levels = {}, display = {} }
    ns.db.display = ns.db.display or {}
    ns.db.display[#ns.db.display + 1] = r
    JourneySizeProbeDB = ns.db
end

-- Test 1: draws one level's whole text in a single wrapped font string.
function ns.ShowTest(name)
    local text = ns.text[name]
    if not text then out("No text loaded for " .. tostring(name)); return end
    if not CreateFrame then return end
    local w = getWindow()
    w.frame:Show()
    for _, p in ipairs(w.pool) do p:Hide() end
    w.fs:Show()
    local t0 = ns.now()
    local ok, err = pcall(w.fs.SetText, w.fs, text)
    local t1 = ns.now()
    local r = { name = name, ok = ok and true or false, err = (not ok) and tostring(err):sub(1, 120) or nil, setTextMs = t1 - t0 }
    if ok then
        r.height = w.fs:GetStringHeight()
        r.measureMs = ns.now() - t1
        local got = w.fs:GetText()
        r.gotLen = got and #got or nil
        r.gotOk = (r.gotLen == #text)
        w.child:SetHeight((r.height or 0) + 10)
    end
    r.mode = "single"
    saveDisplay(r)
    if ok then
        out(string.format("%s drawn: SetText %.0f ms, height %.0f px (measured in %.0f ms), text read back %s bytes (%s). Scroll to the end and check the END MARKER line.",
            name, r.setTextMs, r.height or 0, r.measureMs or 0, tostring(r.gotLen), r.gotOk and "same" or "DIFFERENT"))
    else
        out(name .. " could not be drawn: " .. tostring(r.err))
    end
    return r
end

-- Runs fn after the game has laid the window out (the scroll range is only right a moment later).
local function later(fn)
    if C_Timer and C_Timer.After then C_Timer.After(0.5, fn) else fn() end
end

-- Test 2: draws one level's text the way the journal does (Journal.Blocks): one font string for each paragraph, stacked
-- down a scroll area. Records the stacked height, whether the game kept that height, and how far the area scrolls.
function ns.BlocksTest(name)
    local text = ns.text[name]
    if not text then out("No text loaded for " .. tostring(name)); return end
    if not CreateFrame then return end
    local w = getWindow()
    w.frame:Show()
    w.fs:SetText("")
    w.fs:Hide()
    local paragraphs = {}
    for p in (text .. "\n\n"):gmatch("(.-)\n\n") do
        if p ~= "" then paragraphs[#paragraphs + 1] = p end
    end
    local t0 = ns.now()
    local y, changed, lastFs = 0, 0, nil
    for i, p in ipairs(paragraphs) do
        local fs = w.pool[i]
        if not fs then
            fs = w.child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetJustifyH("LEFT")
            fs:SetJustifyV("TOP")
            fs:SetWidth(500)
            w.pool[i] = fs
        end
        fs:SetText(p)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", w.child, "TOPLEFT", 0, -y)
        fs:Show()
        if fs:GetText() ~= p then changed = changed + 1 end
        y = y + (fs:GetStringHeight() or 14) + 4
        lastFs = fs
    end
    for i = #paragraphs + 1, #w.pool do w.pool[i]:Hide() end
    w.child:SetHeight(y + 10)
    local r = { name = name, mode = "blocks", ok = true, paragraphs = #paragraphs, changed = changed,
                height = y, setTextMs = ns.now() - t0, lastText = lastFs and lastFs:GetText() or "" }
    r.lastHasMarker = r.lastText:find("END MARKER", 1, true) ~= nil
    r.lastText = nil
    saveDisplay(r)
    out(string.format("%s drawn as %d paragraphs in %.0f ms, stacked height %.0f px, %d paragraphs changed. Measuring the scroll range...",
        name, r.paragraphs, r.setTextMs, y, changed))
    later(function()
        r.childHeight = w.child:GetHeight()
        r.range = w.scroll:GetVerticalScrollRange()
        r.viewHeight = w.scroll:GetHeight()
        -- The last paragraph can be reached when the area scrolls (almost) the whole stacked height.
        r.reach = (r.range or 0) >= (y + 10 - (r.viewHeight or 0) - 2)
        w.scroll:SetVerticalScroll(r.range or 0)
        out(string.format("%s: the game kept a height of %.0f px (asked %.0f); scroll range %.0f px; the end %s. Check the END MARKER line at the bottom.",
            name, r.childHeight or 0, y + 10, r.range or 0, r.reach and "can be reached" or "CANNOT be reached"))
    end)
    return r
end

function ns.Slash(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "show" then
        ns.ShowTest(rest)
    elseif cmd == "blocks" then
        ns.BlocksTest(rest)
    elseif cmd == "hide" then
        if ns.window then ns.window.frame:Hide() end
    else
        ns.Print(ns.Run())
    end
end

if CreateFrame then
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent", function() ns.Print(ns.Run()) end)
    SLASH_JOURNEYSIZEPROBE1 = "/jmsize"
    SlashCmdList["JOURNEYSIZEPROBE"] = ns.Slash
end
