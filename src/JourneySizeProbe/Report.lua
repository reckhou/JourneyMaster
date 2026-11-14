-- JourneySizeProbe, last file: checks what arrived, prints and records the result, and tests how the game draws it.
--
-- Commands: /jmsize (check again), /jmsize show <name> (draw one level's text in a scroll window), /jmsize hide.
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
    out("To see how the game draws a level: /jmsize show <name>. Then scroll to the end: the last line should read END MARKER.")
end

-- Draws one level's text the way the journal window does (a wrapped font string in a scroll area).
function ns.ShowTest(name)
    local text = ns.text[name]
    if not text then out("No text loaded for " .. tostring(name)); return end
    if not CreateFrame then return end
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
        ns.window = { frame = f, scroll = scroll, child = child, fs = fs }
    end
    local w = ns.window
    w.frame:Show()
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
    ns.db = ns.db or JourneySizeProbeDB or { levels = {}, display = {} }
    ns.db.display = ns.db.display or {}
    ns.db.display[#ns.db.display + 1] = r
    JourneySizeProbeDB = ns.db
    if ok then
        out(string.format("%s drawn: SetText %.0f ms, height %.0f px (measured in %.0f ms), text read back %s bytes (%s). Scroll to the end and check the END MARKER line.",
            name, r.setTextMs, r.height or 0, r.measureMs or 0, tostring(r.gotLen), r.gotOk and "same" or "DIFFERENT"))
    else
        out(name .. " could not be drawn: " .. tostring(r.err))
    end
    return r
end

function ns.Slash(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "show" then
        ns.ShowTest(rest)
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
