-- JourneyMaster window (mock-up revision B in docs/mockups/journey-window.html): two panes, about 700 by 500 pixels.
-- A session list on the left drives the reader on the right; the Journal, Log, Overview and Settings tabs run along the top.
-- Journal shows a session's summary, Overview the journey so far (the whole width, no session list), Log its raw
-- entries with one on/off chip per kind, Settings the switches.
-- The frame, tabs, list, chips and Log lines use the mock-up's colours (UI.C and Core.KINDS), drawn with plain
-- textures rather than the game's frame templates.
-- The foot shows the entries recorded, the date of the last summary and a button that reloads the interface, which
-- loads a new snapshot from the app.
-- Abbreviation: UI = user interface.
local _, ns = ...
local Core, UI, Journal = ns.Core, ns.UI, ns.Journal
local Window = {}
ns.Window = Window

local WIDTH, HEIGHT, LIST_WIDTH, ROW_HEIGHT = 720, 500, 215, 40
local EDGE = 3            -- window border, pixels
local TITLE_H, TABS_H, FOOT_H = 26, 22, 30
local BODY_TOP = EDGE + TITLE_H + 6 + TABS_H + 2 -- title bar, gap, tabs, the line under the tabs
local READER_PAD = 10     -- space round the reader's text and chips
local CHIP_H, CHIP_GAP = 18, 4
local BAR_H, BAR_SLOTS = 26, 7 -- the page bar's height, and how many page numbers or gaps it can show
local C = UI.C
local TABS = { { "journal", "Journal" }, { "log", "Log" }, { "overview", "Overview" }, { "settings", "Settings" } }

local win
local tab = "journal"
local list = { rows = {}, items = {} }
local reader = { pool = {} }
local chips = {}
local filter = {}          -- chip key -> false when hidden (not saved: every opening starts with all kinds shown)
local selected             -- session number shown
local pageOf = {}          -- the page last shown for each text: "overview", or "<tab>:<session>" (kept while the game runs)
local tabButtons, settingsChecks = {}, {}
local footer
Window.widgets = { list = list, reader = reader, chips = chips }

local function rec() return ns.Recorder end
local function charKey()
    local c = rec().Char()
    return c and Core.CharKey(c.name, c.realm) or "?"
end

-- Sessions ---------------------------------------------------------------------------------------------------------

local function currentItem()
    for _, item in ipairs(list.items) do if item.s == selected then return item end end
    return list.items[1]
end

-- The page bar under the reader: shown only when the text has more than one page. The reader's scroll area gives up the
-- bar's height only while the bar shows.
local function setBarLabel(b, text, padding)
    b.label:SetText(text)
    b:SetWidth((b.label:GetStringWidth() or 20) + 2 * padding)
end

local function showPageBar(pkey, page, total)
    local bar = reader.bar
    reader.pageKey, reader.page, reader.total = pkey, page, total
    if not bar then return end
    local show = total > 1
    bar:SetShown(show)
    if reader.barShown ~= show then
        reader.barShown = show
        reader.area.frame:SetPoint("BOTTOMRIGHT", reader.pane, "BOTTOMRIGHT", -4, show and (4 + BAR_H) or 4)
    end
    if not show then return end
    local x = READER_PAD
    bar.prev:ClearAllPoints()
    bar.prev:SetPoint("LEFT", bar, "LEFT", x, 0)
    bar.prev.label:SetTextColor(UI.RGB(page > 1 and C.gold or C.dim))
    x = x + bar.prev:GetWidth() + 6
    local entries = Journal.PageNumbers(page, total)
    for i = 1, BAR_SLOTS do
        local b, e = bar.slots[i], entries[i]
        if not e then
            b:Hide()
        else
            local gap = e == "gap"
            b.page = (not gap) and e or nil
            setBarLabel(b, gap and "..." or tostring(e), gap and 4 or 6)
            b.box.fill:SetColorTexture(UI.RGB(e == page and C.on or C.raised))
            b.label:SetTextColor(UI.RGB(e == page and C.gold or gap and C.dim or C.soft))
            b:ClearAllPoints()
            b:SetPoint("LEFT", bar, "LEFT", x, 0)
            b:Show()
            x = x + b:GetWidth() + 4
        end
    end
    bar.next:ClearAllPoints()
    bar.next:SetPoint("LEFT", bar, "LEFT", x + 2, 0)
    bar.next.label:SetTextColor(UI.RGB(page < total and C.gold or C.dim))
    bar.text:SetText(string.format("Page %d of %d", page, total))
end

local function showReader()
    if not win then return end
    local item = currentItem()
    local key = charKey()
    local blocks
    if tab == "overview" then
        blocks = Journal.OverviewBlocks(rec().Char(), key)
    elseif not item then
        blocks = { { text = "Nothing recorded yet. Play on: the journal fills itself." } }
    elseif tab == "log" then
        local c = rec().Char()
        blocks = Journal.LogBlocks(key, item, Core.SessionEntries(c and c.entries or {}, item.s), filter)
    else
        blocks = Journal.JournalBlocks(key, item)
    end
    -- One page at a time. The page shown is the one last chosen for this text, else the newest sessions' (the last page)
    -- for the Overview and the first page for the others.
    local pages = Journal.PagesFor(tab, blocks)
    local total = #pages
    local pkey = tab == "overview" and "overview" or (tab .. ":" .. tostring(item and item.s or 0))
    local page = math.max(1, math.min(pageOf[pkey] or (tab == "overview" and total or 1), total))
    showPageBar(pkey, page, total)
    UI.LayoutBlocks(reader.area, reader.pool, pages[page])
    local subject = pkey .. "#" .. page
    if reader.subject ~= subject then
        reader.subject = subject
        reader.area:ScrollToTop() -- a new page or session starts at its top; a live refresh of the same page keeps its place
    end
end

-- Shows page n of the text in the reader (kept for the next time this text is shown).
function Window.GoToPage(n)
    if not reader.pageKey then return end
    pageOf[reader.pageKey] = math.max(1, math.min(tonumber(n) or 1, reader.total or 1))
    showReader()
end

local function makeRow(i)
    local row = CreateFrame("Button", nil, list.area.child)
    row:SetHeight(ROW_HEIGHT)
    row.bg = UI.Fill(row, C.on, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:Hide()
    UI.Fill(row, "ffffff", "HIGHLIGHT", 0.06):SetAllPoints()
    -- As in the mock-up: the date small and dim above the title.
    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.sub:SetPoint("TOPLEFT", 10, -5)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetTextColor(UI.RGB(C.dim))
    if row.sub.SetWordWrap then row.sub:SetWordWrap(false) end
    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", row.sub, "BOTTOMLEFT", 0, -3)
    row.title:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.title:SetJustifyH("LEFT")
    if row.title.SetWordWrap then row.title:SetWordWrap(false) end
    row:SetScript("OnClick", function(self)
        selected = self.s
        Window.Refresh()
    end)
    list.rows[i] = row
    return row
end

local function showList()
    list.items = Journal.List(rec().Char(), charKey())
    if selected == nil and list.items[1] then selected = list.items[1].s end
    local y = 0
    for i, item in ipairs(list.items) do
        local row = list.rows[i] or makeRow(i)
        row.s = item.s
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", list.area.child, "TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", list.area.child, "RIGHT", 0, 0)
        local on = item.s == selected
        row.title:SetText(item.title or "?")
        -- Mock-up: the chosen row in gold, older title-only sessions dim, the rest soft gold.
        row.title:SetTextColor(UI.RGB(on and C.gold or item.state == "brief" and C.dim or C.soft))
        local sub = Core.Clock(item.first or 0, "%d %b %Y, %H:%M")
        if item.entries and item.entries > 0 then sub = sub .. " \194\183 " .. item.entries .. " entries" end
        row.sub:SetText(sub)
        row.bg:SetShown(on)
        row:Show()
        y = y + ROW_HEIGHT
    end
    for i = #list.items + 1, #list.rows do list.rows[i]:Hide() end
    list.area:SetContentHeight(y)
end

-- Whether a session has screenshots: thumbnails from the app, or (not summarised yet) screenshot entries.
local function hasShots(item)
    if not item then return false end
    if item.shots and #item.shots > 0 then return true end
    if item.state ~= "pending" then return false end
    local c = rec().Char()
    for _, e in ipairs(Core.SessionEntries(c and c.entries or {}, item.s)) do
        if e.k == "shot" then return true end
    end
    return false
end

-- Whether a session is the one being played (it can be finished early).
local function isCurrent(item)
    local c = rec().Char()
    return item and c and item.state == "pending" and item.s == c.session and not c.endSession or false
end

-- The foot: the counts on the left, then the buttons from the right: Summarise for a session not summarised yet (it takes
-- the place of Reload), else Reload (not for the session in progress); then Finish session, Open screenshots, Delete and
-- Rename when they apply.
local function showFooter()
    local c = rec().Char()
    local n = c and #c.entries or 0
    footer.text:SetText(n .. " entries \194\183 last summary " .. (Journal.LastSummaryDate() or "none yet"))
    local item = currentItem()
    local perSession = tab == "journal" or tab == "log" -- Settings and Overview are about no one session
    local finish = perSession and isCurrent(item)
    local shots = perSession and hasShots(item)
    local edit = perSession and item ~= nil
    local summarise = perSession and item ~= nil and item.state == "pending" and not item.requested and (item.entries or 0) > 0
        and not isCurrent(item) -- only a finished session; the one in progress has Finish session first
    -- A session in progress has no Reload (it has nothing to load yet): Finish session comes first, then Summarise.
    local reload = not summarise and not finish
    footer.summarise:SetShown(summarise)
    footer.reload:SetShown(reload)
    local anchor = summarise and footer.summarise or reload and footer.reload or nil -- the rightmost button shown
    for _, b in ipairs({ { footer.finish, finish }, { footer.shots, shots }, { footer.delete, edit }, { footer.rename, edit } }) do
        b[1]:SetShown(b[2])
        if b[2] then
            if anchor then b[1]:SetPoint("RIGHT", anchor, "LEFT", -6, 0) else b[1]:SetPoint("RIGHT", footer, "RIGHT", -10, -1) end
            anchor = b[1]
        end
    end
    if anchor then footer.text:SetPoint("RIGHT", anchor, "LEFT", -10, 0) else footer.text:SetPoint("RIGHT", footer, "RIGHT", -10, 0) end
end

-- The "Open screenshots" button: the add-on cannot open folders, so it signals the app through the chat log (Signal.lua).
local function requestShots()
    local item = currentItem()
    if not item then return end
    if ns.Signal.Send("OPEN", item.s) then
        ns.Say("asked the app on your PC to open this session's screenshots. It must be running.")
    else
        ns.Say("still sending the last request: try again in a moment.")
    end
end
Window.RequestShots = requestShots

-- The Summarise button, for a finished session: the app summarises nothing on its own. This notes the request and
-- reloads the interface, so the game writes the record to disk; the signal to the app follows at login.
local function summarise()
    local item = currentItem()
    if not item then return end
    local ok, why = ns.Signal.RequestSummary(item.s)
    if not ok then ns.Say(why) return end
    ns.Say("asked the app on your PC to summarise this session. Reloading so the game writes the record to disk; the app must be running. Reload again when the app has finished.")
    if ReloadUI then ReloadUI() end
end
Window.Summarise = summarise

local function finishSession()
    local ok, why = ns.Signal.FinishSession()
    if not ok then ns.Say(why) end
    Window.Refresh()
end
Window.FinishSession = finishSession

-- Rename and Delete: a popup each (the game's StaticPopup), then a signal to the app (Signal.lua). The popup's data is
-- the session number, so a change of selection while it is open does not change which session it acts on.
local function popupEditBox(self)
    return self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
end

local function renameSession(s, text)
    local ok, why = ns.Signal.RenameSession(s, text)
    if not ok then ns.Say(why) end
    Window.Refresh()
end
Window.RenameSession = renameSession

local function deleteSession(s)
    local ok, why = ns.Signal.DeleteSession(s)
    if not ok then ns.Say(why) return end
    if selected == s then selected = nil end
    ns.Say("session deleted. The app on your PC keeps it in the character's deleted folder, from where it can be restored.")
    Window.Refresh()
end
Window.DeleteSession = deleteSession

local function askRename()
    local item = currentItem()
    if not item or not StaticPopup_Show then return end
    StaticPopupDialogs.JOURNEYMASTER_RENAME = StaticPopupDialogs.JOURNEYMASTER_RENAME or {
        text = "JourneyMaster: a new title for this session.",
        button1 = "Rename", button2 = "Cancel",
        hasEditBox = 1, maxLetters = Core.TITLE_MAX, editBoxWidth = 300,
        OnShow = function(self, data)
            local box = popupEditBox(self)
            if box then box:SetText(data and data.title or "") box:HighlightText() box:SetFocus() end
        end,
        OnAccept = function(self, data)
            local box = popupEditBox(self)
            if box and data then renameSession(data.s, box:GetText()) end
        end,
        EditBoxOnEnterPressed = function(box)
            local popup = box:GetParent()
            local data = popup and popup.data
            if data then renameSession(data.s, box:GetText()) end
            if popup then popup:Hide() end
        end,
        EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    local renameable = item.state ~= "pending" or item.title ~= "Not summarised yet"
    StaticPopup_Show("JOURNEYMASTER_RENAME", nil, nil, { s = item.s, title = renameable and item.title or "" })
end
Window.AskRename = askRename

local function askDelete()
    local item = currentItem()
    if not item or not StaticPopup_Show then return end
    StaticPopupDialogs.JOURNEYMASTER_DELETE = StaticPopupDialogs.JOURNEYMASTER_DELETE or {
        text = "JourneyMaster: delete \"%s\"?\n\nThe app on your PC moves its summary, record, screenshots and entries to the character's deleted folder, from where they can be restored.",
        button1 = "Delete", button2 = "Cancel",
        OnAccept = function(_, data) if data then deleteSession(data.s) end end,
        timeout = 0, whileDead = true, hideOnEscape = true, showAlert = 1,
    }
    StaticPopup_Show("JOURNEYMASTER_DELETE", tostring(item.title or "?"), nil, { s = item.s })
end
Window.AskDelete = askDelete

-- Settings ---------------------------------------------------------------------------------------------------------

Window.SETTINGS = {
    { "minimapButton", "Show the minimap button", "Hidden, the journal still opens with /jm or from the add-on menu." },
    { "chatSay", "Record say", "Lines spoken aloud near you, yours included." },
    { "chatYell", "Record yell", nil },
    { "chatEmote", "Record emotes", "Typed emotes and stock emotes such as /wave." },
    { "chatParty", "Record party chat", nil },
    { "chatRaid", "Record raid chat", nil },
    { "chatInstance", "Record instance chat", nil },
    { "npcSpeech", "Record NPC speech", "What non-player characters say, yell and emote near you." },
    { "screenshots", "Screenshots at milestones", "A screenshot at each level-up, boss kill and dungeon entry, and on your first arrival in a zone. Another once you have stayed in a zone for 5 minutes, then every 45 minutes while you stay. In subzones: one after your first 5 minutes in a new one, and one per session after 20 minutes there in total. None while flying: it waits until you land, and a stay screenshot waits a further minute on the ground. The summary places each picture where it was taken." },
    { "reloadPrompt", "Offer a reload after a long session", "The game writes the record only at /reload or logout; a crash loses everything since. After the hours set with /jm reloadhours, JourneyMaster offers a reload." },
}

local function buildSettings(panel)
    local y = -8
    for i, s in ipairs(Window.SETTINGS) do
        local c = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        c:SetPoint("TOPLEFT", 8, y)
        c:SetScript("OnClick", function(self)
            rec().Char().settings[s[1]] = self:GetChecked() and true or false
            if s[1] == "minimapButton" then ns.Minimap.Refresh() end
        end)
        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", c, "RIGHT", 4, 0)
        label:SetText(s[2])
        label:SetTextColor(UI.RGB(C.text))
        if s[3] then UI.Tooltip(c, s[2], s[3]) end
        settingsChecks[s[1]] = c
        y = y - 28
    end
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetTextColor(UI.RGB(C.muted))
    note:SetPoint("TOPLEFT", 12, y - 8)
    note:SetWidth(350) -- the right-hand column holds the AI settings
    note:SetJustifyH("LEFT")
    note:SetText("Settings are kept per character. Whispers, guild, officer and numbered channels are never recorded. "
        .. "/jm help lists the commands, including /jm keep <n> (recent sessions whose record stays in the add-on) and /jm reloadhours <n>.")
end

-- The AI model and effort the app summarises with: one button each, which steps to the next choice on a click. The
-- change goes to the app at once through the chat log (Signal.SetAI) and is kept in the saved data for later runs.
local aiButtons = {}

local function aiLabel(field)
    if field == "model" then return "Model: " .. Core.ChoiceLabel(Core.AI_MODELS, rec().Setting("aiModel")) end
    return "Effort: " .. Core.ChoiceLabel(Core.AI_EFFORTS, rec().Setting("aiEffort"))
end

local function buildAISettings(panel)
    local x = 380
    local head = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", x, -12)
    head:SetText("AI summaries")
    head:SetTextColor(UI.RGB(C.gold))
    local y = -36
    for _, field in ipairs({ "model", "effort" }) do
        local b = UI.FlatButton(panel, "Effort: Extra high", "GameFontNormalSmall", C.raised, C.edge, C.soft, 10, 22)
        b:SetPoint("TOPLEFT", x, y)
        b:SetScript("OnClick", function(self)
            local list = field == "model" and Core.AI_MODELS or Core.AI_EFFORTS
            local value = Core.NextChoice(list, rec().Setting(field == "model" and "aiModel" or "aiEffort"))
            ns.Signal.SetAI(field, value)
            self.label:SetText(aiLabel(field))
        end)
        UI.Tooltip(b, field == "model" and "AI model" or "Effort",
            field == "model" and "The model the app on your PC writes summaries with. Click for the next one. Takes effect at the app's next summary; the app must be running."
                or "How much the model thinks before it writes. Higher is slower and costs more. Click for the next level. Takes effect at the app's next summary.")
        aiButtons[field] = b
        y = y - 30
    end
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetTextColor(UI.RGB(C.muted))
    note:SetPoint("TOPLEFT", x, y - 4)
    note:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    note:SetJustifyH("LEFT")
    note:SetText("Default: Opus, high effort. Kept for this character.")
end
Window.AIButtons = aiButtons

-- Reading: the font, size and spacing of the reader's text (Settings tab, under the AI settings). The settings are
-- kept for the whole account; see UI.Reading. A preview paragraph shows the result, and the reader follows at once.
local reading = { steppers = {} }
Window.Reading = reading
local FONT_ROW_H = 22
local PREVIEW = {
    "The road wound down into the valley, and Baldrake set his pack beside the fire.",
    "Morning found the camp quiet, and the hills just as far away as before.",
}

local function fontName(path)
    for _, f in ipairs(reading.fonts or UI.BuiltinFonts()) do
        if f.path:lower() == tostring(path):lower() then return f.name end
    end
    return (tostring(path):match("([^\/]+)%.%w+$")) or tostring(path)
end

local function refreshReading()
    if not reading.fontButton then return end
    local r = UI.Reading()
    reading.fontButton.label:SetText("Font: " .. fontName(r.font))
    for key, st in pairs(reading.steppers) do st.value:SetText(tostring(r[key])) end
    for i, fs in ipairs(reading.preview) do
        UI.ApplyReading(fs, "body", r)
        fs:SetText(PREVIEW[i])
    end
    -- The second paragraph sits one paragraph spacing below the first, as in the reader.
    reading.preview[2]:ClearAllPoints()
    reading.preview[2]:SetPoint("TOPLEFT", reading.preview[1], "BOTTOMLEFT", 0, -r.paragraph)
end

-- A setting changed: update the Settings tab and the reader.
function Window.ReadingChanged()
    refreshReading()
    if reading.popup and reading.popup:IsShown() then reading.popup:Hide() end
    showReader()
end

-- The pop-up list of fonts, each name drawn in its own font.
function Window.OpenFontList()
    local popup = reading.popup
    if popup and popup:IsShown() then popup:Hide() return end
    if not popup then
        popup = CreateFrame("Frame", nil, win)
        popup:SetFrameStrata("DIALOG")
        popup:SetSize(300, 250)
        UI.Box(popup, C.bg, C.edge, 1)
        popup.area = UI.ScrollArea(popup)
        popup.area.frame:SetPoint("TOPLEFT", 4, -4)
        popup.area.frame:SetPoint("BOTTOMRIGHT", -4, 4)
        popup.rows = {}
        reading.popup = popup
    end
    popup:ClearAllPoints()
    popup:SetPoint("TOPLEFT", reading.fontButton, "BOTTOMLEFT", 0, -2)
    reading.fonts = UI.FontChoices()
    local current = UI.Reading().font:lower()
    for i, f in ipairs(reading.fonts) do
        local row = popup.rows[i]
        if not row then
            row = CreateFrame("Button", nil, popup.area.child)
            row:SetHeight(FONT_ROW_H)
            UI.Fill(row, "ffffff", "HIGHLIGHT", 0.08):SetAllPoints()
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.label:SetPoint("LEFT", 8, 0)
            row:SetScript("OnClick", function(self) UI.SetReading("font", self.path) Window.ReadingChanged() end)
            popup.rows[i] = row
        end
        row.path = f.path
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", popup.area.child, "TOPLEFT", 0, -(i - 1) * FONT_ROW_H)
        row:SetPoint("RIGHT", popup.area.child, "RIGHT", 0, 0)
        row.label:SetFontObject("GameFontHighlight")
        if row.label.SetFont then row.label:SetFont(f.path, 14, "") end
        row.label:SetText(f.name)
        row.label:SetTextColor(UI.RGB(f.path:lower() == current and C.gold or C.text))
        row:Show()
    end
    for i = #reading.fonts + 1, #popup.rows do popup.rows[i]:Hide() end
    popup.area:SetContentHeight(#reading.fonts * FONT_ROW_H)
    popup.area:ScrollToTop()
    popup:Show()
end

local function buildReadingSettings(panel)
    local x = 380
    local head = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", x, -126)
    head:SetText("Reading")
    head:SetTextColor(UI.RGB(C.gold))
    local fb = UI.FlatButton(panel, "Font: Game default", "GameFontNormalSmall", C.raised, C.edge, C.soft, 10, 22)
    fb:SetWidth(300)
    fb:SetPoint("TOPLEFT", x, -148)
    fb:SetScript("OnClick", Window.OpenFontList)
    UI.Tooltip(fb, "Font", "The font of the journal's text. The list holds the game's fonts and any that other add-ons have added through LibSharedMedia. Click for the list.")
    reading.fontButton = fb
    local y = -180
    for _, row in ipairs({
        { "size", "Text size", "How large the text is, in points." },
        { "spacing", "Line spacing", "The space between the lines of a paragraph, in pixels." },
        { "paragraph", "Paragraph spacing", "The space between paragraphs, in pixels." } }) do
        local key = row[1]
        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", x, y)
        label:SetText(row[2])
        label:SetTextColor(UI.RGB(C.text))
        local value = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        value:SetPoint("TOPLEFT", x + 190, y)
        value:SetWidth(30)
        value:SetJustifyH("CENTER")
        value:SetTextColor(UI.RGB(C.gold))
        local function step(sign, text)
            local b = UI.FlatButton(panel, text, "GameFontNormalSmall", C.raised, C.edge, C.gold, 8, 20)
            b:SetPoint("TOPLEFT", x + (sign < 0 and 160 or 224), y + 4)
            b:SetScript("OnClick", function()
                UI.SetReading(key, UI.Reading()[key] + sign * (key == "paragraph" and 2 or 1))
                Window.ReadingChanged()
            end)
            UI.Tooltip(b, row[2], row[3])
            return b
        end
        reading.steppers[key] = { value = value, minus = step(-1, "-"), plus = step(1, "+") }
        y = y - 28
    end
    local reset = UI.FlatButton(panel, "Reset reading settings", "GameFontNormalSmall", C.raised, C.edge, C.soft, 10, 22)
    reset:SetPoint("TOPLEFT", x, y - 2)
    reset:SetScript("OnClick", function() UI.ResetReading() Window.ReadingChanged() end)
    reading.reset = reset
    -- The preview fills what is left of the panel and clips what does not fit, so a large size cannot spill out.
    local box = CreateFrame("Frame", nil, panel)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y - 34)
    box:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 4)
    if box.SetClipsChildren then box:SetClipsChildren(true) end
    reading.preview = {}
    for i = 1, 2 do
        local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetWidth(300)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetTextColor(UI.RGB(C.text))
        reading.preview[i] = fs
    end
    reading.preview[1]:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
    refreshReading()
end

local function showSettings()
    for key, c in pairs(settingsChecks) do c:SetChecked(rec().Setting(key) and true or false) end
    for field, b in pairs(aiButtons) do b.label:SetText(aiLabel(field)) end
    reading.fonts = reading.fonts or UI.FontChoices() -- the first time only: it loads each font once to test it
    refreshReading()
end

-- The window -------------------------------------------------------------------------------------------------------

local function paintTabs()
    for i, t in ipairs(TABS) do
        local b, on = tabButtons[i], t[1] == tab
        b.box.fill:SetColorTexture(UI.RGB(on and C.on or C.raised))
        b.label:SetTextColor(UI.RGB(on and C.gold or C.muted))
    end
end

local function selectTab(name)
    tab = name
    paintTabs()
    if reading.popup then reading.popup:Hide() end
    win.sessions:SetShown(name ~= "settings")
    win.settings:SetShown(name == "settings")
    win.chipBar:SetShown(name == "log")
    -- Overview: no session list, the reader takes the whole width.
    win.listPane:SetShown(name ~= "overview")
    reader.pane:SetPoint("TOPLEFT", win.sessions, "TOPLEFT", name == "overview" and 0 or LIST_WIDTH + 2, 0)
    reader.area.frame:SetPoint("TOPLEFT", reader.pane, "TOPLEFT", 0, name == "log" and -win.chipBar.used or 0)
    Window.Refresh()
end

-- One chip per kind, in the kind's colour, as in the mock-up: full strength when shown, faded when hidden. Chips wrap
-- onto a new row when the reader is too narrow for them all. Returns the height the chips use.
local function buildChips(parent, width)
    local x, y = 0, 0
    for _, kind in ipairs(Core.KINDS) do
        local b = UI.FlatButton(parent, kind.label, "GameFontHighlightSmall", C.bg, C.edge, Core.KindHex(kind.key), 8, CHIP_H)
        if x > 0 and x + b:GetWidth() > width then x, y = 0, y + CHIP_H + CHIP_GAP end
        b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
        b.on = true
        b.SetChecked = function(self, v) self.on = v and true or false self:SetAlpha(self.on and 1 or 0.4) end
        b.GetChecked = function(self) return self.on end
        b:SetScript("OnClick", function(self)
            self:SetChecked(not self.on)
            if self.on then filter[kind.key] = nil else filter[kind.key] = false end
            showReader()
        end)
        UI.Tooltip(b, kind.label, "Click to show or hide these entries.")
        chips[kind.key] = b
        x = x + b:GetWidth() + CHIP_GAP
    end
    return y + CHIP_H
end

local function create()
    -- The frame: dark brown with a bronze border and a thin black outline, as in the mock-up.
    win = CreateFrame("Frame", "JourneyMasterFrame", UIParent)
    win:SetSize(WIDTH, HEIGHT)
    win:SetPoint("CENTER", 0, 40)
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if UISpecialFrames then tinsert(UISpecialFrames, "JourneyMasterFrame") end -- closes with Escape
    win:Hide()
    local outline = UI.Fill(win, "000000", "BACKGROUND")
    outline:SetDrawLayer("BACKGROUND", -8)
    outline:SetPoint("TOPLEFT", -1, 1)
    outline:SetPoint("BOTTOMRIGHT", 1, -1)
    UI.Box(win, C.bg, C.edge, EDGE)

    -- Title bar: a band darkening downwards with a bronze line under it, the title in gold, the close button right.
    local bar = CreateFrame("Frame", nil, win)
    bar:SetPoint("TOPLEFT", EDGE, -EDGE)
    bar:SetPoint("TOPRIGHT", -EDGE, -EDGE)
    bar:SetHeight(TITLE_H)
    UI.Box(bar, C.raised, C.edge, 2, "B")
    local top = UI.Fill(bar, C.titleTop, "BACKGROUND")
    top:SetDrawLayer("BACKGROUND", 1)
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(TITLE_H / 2)
    win.titleText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    win.titleText:SetPoint("LEFT", 10, 1)
    win.titleText:SetTextColor(UI.RGB(C.gold))
    local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
    close:SetSize(26, 26)
    close:SetPoint("RIGHT", 1, 0)
    close:SetScript("OnClick", function() win:Hide() end)

    -- Tabs under the title, open at the bottom onto a bronze line.
    for i, t in ipairs(TABS) do
        local b = UI.FlatButton(win, t[2], "GameFontNormal", C.raised, C.edge, C.muted, 16, TABS_H)
        b.box.edges[2]:Hide() -- the bottom edge
        b:SetScript("OnClick", function() selectTab(t[1]) end)
        if i == 1 then b:SetPoint("TOPLEFT", win, "TOPLEFT", EDGE + 8, -(EDGE + TITLE_H + 6))
        else b:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", 4, 0) end
        tabButtons[i] = b
    end
    local line = UI.Fill(win, C.edge, "BORDER")
    line:SetPoint("TOPLEFT", EDGE, -(BODY_TOP - 2))
    line:SetPoint("TOPRIGHT", -EDGE, -(BODY_TOP - 2))
    line:SetHeight(2)

    -- Sessions on the left, behind a bronze line; the reader on the right.
    local body = CreateFrame("Frame", nil, win)
    body:SetPoint("TOPLEFT", EDGE, -BODY_TOP)
    body:SetPoint("BOTTOMRIGHT", -EDGE, EDGE + FOOT_H)
    win.sessions = body
    local listPane = CreateFrame("Frame", nil, body)
    win.listPane = listPane
    listPane:SetPoint("TOPLEFT", 0, 0)
    listPane:SetPoint("BOTTOMLEFT", 0, 0)
    listPane:SetWidth(LIST_WIDTH + 2)
    UI.Box(listPane, nil, C.edge, 2, "R")
    list.area = UI.ScrollArea(listPane)
    list.area.frame:SetPoint("TOPLEFT", 0, -6)
    list.area.frame:SetPoint("BOTTOMRIGHT", -2, 6)
    list.area.onResize = function() showList() end

    reader.pane = CreateFrame("Frame", nil, body)
    reader.pane:SetPoint("TOPLEFT", LIST_WIDTH + 2, 0)
    reader.pane:SetPoint("BOTTOMRIGHT", 0, 0)

    win.chipBar = CreateFrame("Frame", nil, reader.pane)
    win.chipBar:SetPoint("TOPLEFT", READER_PAD, -8)
    win.chipBar:SetPoint("RIGHT", reader.pane, "RIGHT", -READER_PAD, 0)
    local chipsHeight = buildChips(win.chipBar, WIDTH - 2 * EDGE - LIST_WIDTH - 2 - 2 * READER_PAD)
    win.chipBar:SetHeight(chipsHeight)
    win.chipBar.used = 8 + chipsHeight + 2

    reader.area = UI.ScrollArea(reader.pane)
    reader.area.padding = READER_PAD
    reader.area.frame:SetPoint("TOPLEFT", reader.pane, "TOPLEFT", 0, 0)
    reader.area.frame:SetPoint("BOTTOMRIGHT", -4, 4)
    reader.area.onResize = function() showReader() end

    -- The page bar at the foot of the reader: Prev, the page numbers (the current one lit), Next, and "Page 2 of 5".
    reader.bar = CreateFrame("Frame", nil, reader.pane)
    reader.bar:SetPoint("BOTTOMLEFT", reader.pane, "BOTTOMLEFT", 0, 0)
    reader.bar:SetPoint("BOTTOMRIGHT", reader.pane, "BOTTOMRIGHT", 0, 0)
    reader.bar:SetHeight(BAR_H)
    UI.Box(reader.bar, nil, C.edge, 1, "T")
    reader.bar:Hide()
    local function flat(label, padding) return UI.FlatButton(reader.bar, label, "GameFontNormalSmall", C.raised, C.edge, C.soft, padding, 18) end
    reader.bar.prev = flat("< Prev", 8)
    reader.bar.prev:SetScript("OnClick", function() Window.GoToPage((reader.page or 1) - 1) end)
    reader.bar.next = flat("Next >", 8)
    reader.bar.next:SetScript("OnClick", function() Window.GoToPage((reader.page or 1) + 1) end)
    reader.bar.slots = {}
    for i = 1, BAR_SLOTS do
        local b = flat("1", 6)
        b:SetScript("OnClick", function(self) if self.page then Window.GoToPage(self.page) end end)
        b:Hide()
        reader.bar.slots[i] = b
    end
    reader.bar.text = reader.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    reader.bar.text:SetPoint("RIGHT", reader.bar, "RIGHT", -READER_PAD, 0)
    reader.bar.text:SetTextColor(UI.RGB(C.muted))

    win.settings = CreateFrame("Frame", nil, win)
    win.settings:SetPoint("TOPLEFT", EDGE + 8, -BODY_TOP)
    win.settings:SetPoint("BOTTOMRIGHT", -(EDGE + 8), EDGE + FOOT_H)
    win.settings:Hide()
    buildSettings(win.settings)
    buildAISettings(win.settings)
    buildReadingSettings(win.settings)

    -- Foot: a bronze line, the counts in muted text, the reload button in the mock-up's red and gold. The button is as
    -- wide as its label, and the counts stop short of it.
    footer = CreateFrame("Frame", nil, win)
    footer:SetPoint("BOTTOMLEFT", EDGE, EDGE)
    footer:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
    footer:SetHeight(FOOT_H)
    UI.Box(footer, nil, C.edge, 2, "T")
    -- "Reload", not the mock-up's "Reload for new summaries": with Rename and Delete the foot has no room for it.
    footer.reload = UI.FlatButton(footer, "Reload", "GameFontNormalSmall", C.button, C.buttonEdge, C.gold, 12, 20)
    footer.reload:SetScript("OnClick", function() ReloadUI() end)
    footer.reload:SetPoint("RIGHT", -10, -1)
    UI.Tooltip(footer.reload, "Reload the interface",
        "Loads the newest summaries from the app on your PC. The game also writes the record to disk, so the app can summarise it.")
    footer.summarise = UI.FlatButton(footer, "Summarise", "GameFontNormalSmall", C.button, C.buttonEdge, C.gold, 12, 20)
    footer.summarise:SetScript("OnClick", summarise)
    footer.summarise:SetPoint("RIGHT", -10, -1)
    footer.summarise:Hide()
    UI.Tooltip(footer.summarise, "Summarise this session",
        "The app on your PC writes this session's summary. Only a finished session can be summarised (the one in progress needs Finish session first), and nothing is summarised on its own. This reloads the interface, so the game writes the record to disk. The app must be running (it can stay in the background). Reload again when the app has finished, to see the summary.")
    footer.shots = UI.FlatButton(footer, "Open screenshots", "GameFontNormalSmall", C.raised, C.edge, C.soft, 10, 20)
    footer.shots:SetScript("OnClick", requestShots)
    footer.shots:Hide()
    UI.Tooltip(footer.shots, "Open screenshots on PC",
        "The JourneyMaster app on your PC opens this session's screenshots in File Explorer, a few seconds after the click. The app must be running.")
    footer.finish = UI.FlatButton(footer, "Finish session", "GameFontNormalSmall", C.finish, C.finishEdge, C.finishText, 10, 20)
    footer.finish:SetScript("OnClick", finishSession)
    footer.finish:Hide()
    UI.Tooltip(footer.finish, "Finish this session",
        "Ends the session now, so the app can summarise it after a reload, without waiting for you to close the game. Whatever you do next starts a new session. Also /jm end.")
    footer.rename = UI.FlatButton(footer, "Rename", "GameFontNormalSmall", C.raised, C.edge, C.soft, 10, 20)
    footer.rename:SetScript("OnClick", askRename)
    footer.rename:Hide()
    UI.Tooltip(footer.rename, "Rename this session",
        "Gives the session your own title. The app on your PC writes it into the session's file, or uses it when it summarises the session.")
    footer.delete = UI.FlatButton(footer, "Delete", "GameFontNormalSmall", C.raised, C.edge, C.soft, 10, 20)
    footer.delete:SetScript("OnClick", askDelete)
    footer.delete:Hide()
    UI.Tooltip(footer.delete, "Delete this session",
        "Removes the session from the journal, after you confirm. The app on your PC moves its summary, record, screenshots and entries to the character's deleted folder, from where they can be restored.")
    footer.text = footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer.text:SetPoint("LEFT", 10, -1)
    footer.text:SetPoint("RIGHT", footer.reload, "LEFT", -10, 0)
    footer.text:SetJustifyH("LEFT")
    footer.text:SetTextColor(UI.RGB(C.muted))
    if footer.text.SetWordWrap then footer.text:SetWordWrap(false) end

    selectTab("journal")
end

function Window.Refresh()
    if not (win and win:IsShown()) then return end
    local c = rec().Char()
    win.titleText:SetText("JourneyMaster" .. (c and (": " .. tostring(c.name)) or ""))
    if tab == "settings" then
        showSettings()
    else
        showList()
        showReader()
    end
    showFooter() -- after the list, as its "Open screenshots on PC" button follows the chosen session
end

function Window.Show()
    if not win then create() end
    win:Show()
    Window.Refresh()
end

function Window.Hide() if win then win:Hide() end end
function Window.IsShown() return win and win:IsShown() or false end

function Window.Toggle()
    if Window.IsShown() then Window.Hide() else Window.Show() end
end

-- Opens on a tab (used by /jm log).
function Window.ShowTab(name)
    Window.Show()
    selectTab(name)
end

-- Called by the recorder for each new entry: keeps an open window up to date, at most twice a second.
local pending = false
function Window.OnNewEntry()
    if not Window.IsShown() or pending then return end
    pending = true
    local function run() pending = false Window.Refresh() end
    if C_Timer and C_Timer.After then C_Timer.After(0.5, ns.Recorder.Guard("the journal window", run)) else run() end
end

-- For the offline harness.
Window.Footer = function() return footer end
Window.State = function() return { tab = tab, selected = selected, filter = filter, items = list.items } end
Window.Select = function(s) selected = s Window.Refresh() end
Window.SelectTab = function(name) selectTab(name) end
Window.TabNames = function() local o = {} for i, t in ipairs(TABS) do o[i] = t[1] end return o end
Window.PageState = function() return { key = reader.pageKey, page = reader.page, total = reader.total, bar = reader.barShown and true or false } end
Window.SetChip = function(key, on)
    if on then filter[key] = nil else filter[key] = false end
    if chips[key] then chips[key]:SetChecked(on) end
    showReader()
end
