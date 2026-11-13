-- JourneyMaster: records what a character does, without the player lifting a finger, so the app on the PC can have
-- the AI write a neutral account of each play session. This file starts the add-on: saved data, events, the minimap
-- button, the /jm command and the optional reload prompt.
--
-- Abbreviations: SV = SavedVariables (JourneyMasterDB, written by the game at /reload or logout). AI = artificial
-- intelligence. UI = user interface.
local addonName, ns = ...
local Core, Rec = ns.Core, ns.Recorder

JourneyMaster = ns -- one global, for /dump and the offline harness
ns.VERSION = "0.1.0"

local function say(msg)
    local line = "|cffffd100JourneyMaster:|r " .. msg
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(line) else print(line) end
end
ns.Say = say

-- The reload prompt --------------------------------------------------------------------------------------------------

local function maybeOfferReload()
    local c = Rec.Char()
    if not c or not Rec.Setting("reloadPrompt") or c.reloadOffered then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local hours = tonumber(Rec.Setting("reloadHours")) or 2
    if time() - (c.sinceReload or time()) < hours * 3600 then return end
    c.reloadOffered = true
    if StaticPopupDialogs and StaticPopup_Show then
        StaticPopupDialogs.JOURNEYMASTER_RELOAD = StaticPopupDialogs.JOURNEYMASTER_RELOAD or {
            text = "JourneyMaster: you have played for a while since the game last saved your journey. Reload the interface now, so a crash cannot lose it?",
            button1 = "Reload", button2 = "Not now",
            OnAccept = function() ReloadUI() end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("JOURNEYMASTER_RELOAD")
    else
        say("you have played for " .. hours .. " hours since the last save. Type /reload to keep the record safe.")
    end
end

-- Slash commands -----------------------------------------------------------------------------------------------------

ns.HELP = {
    "/jm - open or close the journal",
    "/jm log - open the Log tab",
    "/jm note <text> - add a note to the record (what the game cannot see)",
    "/jm minimap - show or hide the minimap button",
    "/jm keep <n> - recent sessions whose record stays in the add-on once the app has stored it (now %s)",
    "/jm reloadhours <n> - hours of play before the reload prompt, when that setting is on (now %s)",
    "/jm status - entries recorded and the last summary",
}

function ns.Command(msg)
    msg = tostring(msg or "")
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local c = Rec.Char()
    if cmd == "" then
        ns.Window.Toggle()
    elseif cmd == "log" then
        ns.Window.ShowTab("log")
    elseif cmd == "note" then
        if Rec.Note(rest) then say("note added.") else say("type the note after /jm note.") end
    elseif cmd == "minimap" then
        c.settings.minimapButton = not Rec.Setting("minimapButton")
        ns.Minimap.Refresh()
        say("minimap button " .. (c.settings.minimapButton and "shown." or "hidden. /jm still opens the journal."))
    elseif cmd == "keep" and tonumber(rest) then
        c.settings.keepSessions = math.max(1, math.floor(tonumber(rest)))
        say("the record of the newest " .. c.settings.keepSessions .. " sessions stays in the add-on.")
    elseif cmd == "reloadhours" and tonumber(rest) then
        c.settings.reloadHours = math.max(0.5, tonumber(rest))
        say("reload prompt after " .. c.settings.reloadHours .. " hours" .. (Rec.Setting("reloadPrompt") and "." or " (the prompt is off; turn it on under Settings)."))
    elseif cmd == "status" then
        local sessions = Core.Sessions(c.entries)
        say(#c.entries .. " entries in " .. #sessions .. " sessions. Last summary: " .. (ns.Journal.LastSummaryDate() or "none yet") .. ".")
        if (c.dropped or 0) > 0 then say(c.dropped .. " entries were dropped at the size cap.") end
    else
        for _, line in ipairs(ns.HELP) do
            say(line:format(tostring(Rec.Setting("keepSessions")), tostring(Rec.Setting("reloadHours"))))
        end
    end
end

SLASH_JOURNEYMASTER1 = "/jm"
SLASH_JOURNEYMASTER2 = "/journeymaster"
SlashCmdList = SlashCmdList or {}
SlashCmdList.JOURNEYMASTER = function(msg) ns.Command(msg) end

-- Start-up -----------------------------------------------------------------------------------------------------------

function ns.OnLogin()
    JourneyMasterDB = JourneyMasterDB or {}
    Rec.Start(JourneyMasterDB)
    ns.Minimap.Create()
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(300, maybeOfferReload) end
end

local frame = CreateFrame and CreateFrame("Frame")
ns.frame = frame
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    for _, event in ipairs(Rec.EVENTS) do
        -- An event this client does not know raises an error; skip it rather than stop the add-on.
        pcall(frame.RegisterEvent, frame, event)
    end
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_LOGIN" then
            ns.OnLogin()
            return
        end
        local ok, err = pcall(Rec.OnEvent, event, ...)
        if not ok and ns.debug then say("error in " .. event .. ": " .. tostring(err)) end
    end)
end
