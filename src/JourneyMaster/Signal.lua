-- JourneyMaster signals to the app, with no reload: "open this session's screenshots" and "this session is finished".
-- A signal is a hidden system line in the chat log, followed by about 48 KiB of hidden padding, which makes the game
-- write WoWChatLog.txt to disk about a second later; the app watches the end of that file. The method and the code
-- that hides the lines come from RPMaster (its ADR 0001, "text capture through the padded chat log", and writeToLog).
-- Measured on retail; on WoW: Forever it is not yet measured. Line formats are in Core (Core.SignalLines).
-- Abbreviations: ADR = architecture decision record; KiB = kibibyte (1,024 bytes).
local _, ns = ...
local Core = ns.Core
local Signal = {}
ns.Signal = Signal

local TICK, PER_TICK = 0.05, 10 -- system lines written per tick: about a second for a whole signal
local writing                    -- the signal being written, or nil
local count = 0
local loginStamp = tostring(time and time() or 0)

local function rec() return ns.Recorder end

-- Where chat is restricted (instances) the game skips add-on chat filters, so the filter below cannot hide the lines.
-- The chat windows then stop listening for system messages until the signal is written. Never saved.
local quietWindows, quietWrites = nil, 0

local function chatRestricted()
    if IsInInstance and IsInInstance() then return true end
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() and true or false
end

local function quietSystemChat()
    quietWrites = quietWrites + 1
    if quietWindows or not chatRestricted() then return end
    quietWindows = {}
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        if cf and cf.IsEventRegistered and cf:IsEventRegistered("CHAT_MSG_SYSTEM") then
            cf:UnregisterEvent("CHAT_MSG_SYSTEM")
            quietWindows[#quietWindows + 1] = cf
        end
    end
end

-- A moment later, so the last lines have arrived first; a signal started meanwhile keeps the windows quiet.
local function restoreSystemChat()
    local write = quietWrites
    local function restore()
        if write ~= quietWrites or not quietWindows then return end
        for _, cf in ipairs(quietWindows) do cf:RegisterEvent("CHAT_MSG_SYSTEM") end
        quietWindows = nil
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.5, restore) else restore() end
end

-- Hides signal and padding lines from the chat windows; the chat log still records them.
local function hideLines(_, _, msg, ...)
    if issecretvalue and issecretvalue(msg) then return false end
    if type(msg) == "string" and msg:find("^JM[SP]:") then return true end
    return false, msg, ...
end
if ChatFrame_AddMessageEventFilter then ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", hideLines) end
Signal.HideLines = hideLines

function Signal.IsWriting() return writing ~= nil end

local queue = {} -- signals waiting for the one being written: { kind, arg, onDone }

-- Sends a signal (arg: a session number, or "field=value" for SET) for the current character. onDone runs once the
-- last line is written. A signal sent while another is being written waits for it. Returns false when the game cannot
-- write system lines.
function Signal.Send(kind, arg, onDone)
    if type(SendSystemMessage) ~= "function" then return false end
    local c = rec().Char()
    if not c then return false end
    if writing then
        queue[#queue + 1] = { kind, arg, onDone }
        return true
    end
    local function finished()
        if onDone then onDone() end
        local nextOne = table.remove(queue, 1)
        if nextOne then Signal.Send(nextOne[1], nextOne[2], nextOne[3]) end
    end
    if LoggingChat and not (C_ChatInfo and C_ChatInfo.IsLoggingChat and C_ChatInfo.IsLoggingChat()) then
        rec().Try("turning on chat logging", LoggingChat, true)
    end
    count = count + 1
    local id = loginStamp .. "-" .. count
    writing = { lines = Core.SignalLines(id, kind, arg, Core.CharKey(c.name, c.realm)), nextLine = 1, id = id }
    quietSystemChat()
    local function step()
        for _ = 1, PER_TICK do
            local line = writing.lines[writing.nextLine]
            if not line then
                if writing.ticker then writing.ticker:Cancel() end
                writing = nil
                restoreSystemChat()
                finished()
                return true
            end
            SendSystemMessage(line)
            writing.nextLine = writing.nextLine + 1
        end
    end
    if C_Timer and C_Timer.NewTicker then
        writing.ticker = C_Timer.NewTicker(TICK, rec().Guard("sending a signal to the app", step))
    else
        while not step() do end
    end
    return true, id
end

-- Changing the AI model or effort under Settings: saved per character, and sent to the app, which uses it from its
-- next AI call. field: "model" or "effort".
function Signal.SetAI(field, value)
    local c = rec().Char()
    if not c then return false end
    c.settings[field == "model" and "aiModel" or "aiEffort"] = value
    return Signal.Send("SET", field .. "=" .. value)
end

-- Renaming a session: kept in the saved file and shown at once, and sent to the app, which rewrites the title in the
-- session's file (or uses it when it summarises the session). Returns false and the reason when the title is empty.
function Signal.RenameSession(s, text)
    local c = rec().Char()
    if not c then return false, "no character loaded yet." end
    local title = Core.CleanTitle(text)
    if not title then return false, "a title needs at least one letter." end
    Signal.Send("TITLE", Core.RenameSession(c, s, title, time()))
    return true
end

-- Deleting a session: hidden at once, and sent to the app, which moves the session's summary, record, screenshots
-- and entries to its deleted folder, from where they can be restored.
function Signal.DeleteSession(s)
    local c = rec().Char()
    if not c then return false, "no character loaded yet." end
    Signal.Send("DELETE", Core.DeleteSession(c, s, time()))
    return true
end

-- Finishing the session (/jm end, or the window's Finish session button): an "end" entry closes it, the next entry
-- starts a new one, and a signal tells the app. The app summarises the session once the game has written the record
-- to disk, so the player is then offered a reload. Returns false and the reason when there is nothing to finish.
function Signal.FinishSession()
    local c = rec().Char()
    if not c or #Core.SessionEntries(c.entries or {}, c.session) == 0 then return false, "nothing recorded in this session yet." end
    local s = c.session
    rec().Add({ k = "end" })
    c.endSession = true
    Signal.Send("END", s, function()
        if StaticPopupDialogs and StaticPopup_Show then
            StaticPopupDialogs.JOURNEYMASTER_FINISHED = StaticPopupDialogs.JOURNEYMASTER_FINISHED or {
                text = "JourneyMaster: session finished. Reload the interface now? The game then writes the record to disk, and the app on your PC summarises the session.",
                button1 = "Reload", button2 = "Later",
                OnAccept = function() ReloadUI() end,
                timeout = 0, whileDead = true, hideOnEscape = true,
            }
            StaticPopup_Show("JOURNEYMASTER_FINISHED")
        end
    end)
    return true
end
