-- JourneyMaster window (mock-up revision B in docs/mockups/journey-window.html): two panes, about 700 by 500 pixels.
-- A session list on the left drives the reader on the right; the Journal, Log and Settings tabs run along the top.
-- Journal shows a session's summary, Log its raw entries with one on/off chip per kind, Settings the switches.
-- The foot shows the entries recorded, the date of the last summary and a button that reloads the interface, which
-- loads a new snapshot from the app.
-- Abbreviation: UI = user interface.
local _, ns = ...
local Core, UI, Journal = ns.Core, ns.UI, ns.Journal
local Window = {}
ns.Window = Window

local WIDTH, HEIGHT, LIST_WIDTH, ROW_HEIGHT = 720, 500, 210, 38
local GREY = "|cff9d9d9d"
local TABS = { { "journal", "Journal" }, { "log", "Log" }, { "settings", "Settings" } }

local win
local tab = "journal"
local list = { rows = {}, items = {} }
local reader = { pool = {} }
local chips = {}
local filter = {}          -- chip key -> false when hidden (not saved: every opening starts with all kinds shown)
local selected             -- session number shown
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

local function showReader()
    if not win then return end
    local item = currentItem()
    local key = charKey()
    local blocks
    if not item then
        blocks = { { text = "Nothing recorded yet. Play on: the journal fills itself." } }
    elseif tab == "log" then
        local c = rec().Char()
        blocks = Journal.LogBlocks(key, item, Core.SessionEntries(c and c.entries or {}, item.s), filter)
    else
        blocks = Journal.JournalBlocks(key, item)
    end
    UI.LayoutBlocks(reader.area, reader.pool, blocks)
end

local function makeRow(i)
    local row = CreateFrame("Button", nil, list.area.child)
    row:SetHeight(ROW_HEIGHT)
    row.bg = UI.Shade(row, 1, 0.82, 0, 0.15)
    row.bg:Hide()
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", 6, -4)
    row.title:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.title:SetJustifyH("LEFT")
    if row.title.SetWordWrap then row.title:SetWordWrap(false) end
    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.sub:SetJustifyH("LEFT")
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
        local title = item.title or "?"
        if item.state == "brief" then title = GREY .. title .. "|r" end
        if item.state == "pending" then title = "|cffffb347" .. title .. "|r" end
        row.title:SetText(title)
        local sub = Core.Clock(item.first or 0, "%d %b %Y, %H:%M")
        if item.entries and item.entries > 0 then sub = sub .. " \194\183 " .. item.entries .. " entries" end
        row.sub:SetText(sub)
        row.bg:SetShown(item.s == selected)
        row:Show()
        y = y + ROW_HEIGHT
    end
    for i = #list.items + 1, #list.rows do list.rows[i]:Hide() end
    list.area:SetContentHeight(y)
end

local function showFooter()
    local c = rec().Char()
    local n = c and #c.entries or 0
    footer.text:SetText(n .. " entries recorded" .. "   \194\183   Last summary: " .. (Journal.LastSummaryDate() or "none yet"))
end

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
    { "screenshots", "Screenshots at milestones", "A screenshot at each level-up, boss kill, dungeon entry and first visit to a zone. The app links them from the session's summary." },
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
        if s[3] then UI.Tooltip(c, s[2], s[3]) end
        settingsChecks[s[1]] = c
        y = y - 28
    end
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 12, y - 8)
    note:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
    note:SetJustifyH("LEFT")
    note:SetText("Settings are kept per character. Whispers, guild, officer and numbered channels are never recorded. "
        .. "/jm help lists the commands, including /jm keep <n> (recent sessions whose record stays in the add-on) and /jm reloadhours <n>.")
end

local function showSettings()
    for key, c in pairs(settingsChecks) do c:SetChecked(rec().Setting(key) and true or false) end
end

-- The window -------------------------------------------------------------------------------------------------------

local function selectTab(name)
    tab = name
    for i, t in ipairs(TABS) do
        if t[1] == name then
            if PanelTemplates_SetTab then PanelTemplates_SetTab(win, i) end
        end
    end
    win.sessions:SetShown(name ~= "settings")
    win.settings:SetShown(name == "settings")
    win.chipBar:SetShown(name == "log")
    reader.area.frame:SetPoint("TOPLEFT", win.sessions, "TOPLEFT", LIST_WIDTH + 10, name == "log" and -30 or 0)
    Window.Refresh()
end

local function buildChips(parent)
    local x = 0
    for _, kind in ipairs(Core.KINDS) do
        local b = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        b:SetSize(22, 22)
        b:SetPoint("LEFT", parent, "LEFT", x, 0)
        b:SetChecked(true)
        local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", b, "RIGHT", 0, 0)
        label:SetText(kind.label)
        b:SetScript("OnClick", function(self)
            if self:GetChecked() then filter[kind.key] = nil else filter[kind.key] = false end
            showReader()
        end)
        chips[kind.key] = b
        x = x + 24 + (label:GetStringWidth() or 40) + 6
    end
end

local function create()
    win = CreateFrame("Frame", "JourneyMasterFrame", UIParent, "BasicFrameTemplateWithInset")
    win:SetSize(WIDTH, HEIGHT)
    win:SetPoint("CENTER", 0, 40)
    win:SetFrameStrata("HIGH")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if UISpecialFrames then tinsert(UISpecialFrames, "JourneyMasterFrame") end -- closes with Escape
    win:Hide()
    win.titleText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    win.titleText:SetPoint("TOP", 0, -5)

    -- Tabs along the top.
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", "JourneyMasterFrameTab" .. i, win, "PanelTopTabButtonTemplate")
        b:SetID(i)
        b:SetText(t[2])
        b:SetScript("OnClick", function() selectTab(t[1]) end)
        if i == 1 then b:SetPoint("TOPLEFT", win, "TOPLEFT", 12, -26) else b:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", 2, 0) end
        if PanelTemplates_TabResize then PanelTemplates_TabResize(b, 0) end
        tabButtons[i] = b
    end
    if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(win, #TABS) end

    -- Sessions and reader.
    local body = CreateFrame("Frame", nil, win)
    body:SetPoint("TOPLEFT", 12, -60)
    body:SetPoint("BOTTOMRIGHT", -12, 36)
    win.sessions = body
    list.area = UI.ScrollArea(body)
    list.area.frame:SetPoint("TOPLEFT", 0, 0)
    list.area.frame:SetPoint("BOTTOMLEFT", 0, 0)
    list.area.frame:SetWidth(LIST_WIDTH)
    UI.Shade(list.area.frame, 0, 0, 0, 0.3)
    list.area.onResize = function() showList() end

    win.chipBar = CreateFrame("Frame", nil, body)
    win.chipBar:SetPoint("TOPLEFT", LIST_WIDTH + 10, 0)
    win.chipBar:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    win.chipBar:SetHeight(24)
    buildChips(win.chipBar)

    reader.area = UI.ScrollArea(body)
    reader.area.frame:SetPoint("TOPLEFT", LIST_WIDTH + 10, 0)
    reader.area.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    UI.Shade(reader.area.frame, 0.16, 0.13, 0.07, 1)
    reader.area.onResize = function() showReader() end

    win.settings = CreateFrame("Frame", nil, win)
    win.settings:SetPoint("TOPLEFT", 12, -60)
    win.settings:SetPoint("BOTTOMRIGHT", -12, 36)
    win.settings:Hide()
    buildSettings(win.settings)

    -- Foot.
    footer = CreateFrame("Frame", nil, win)
    footer:SetPoint("BOTTOMLEFT", 12, 8)
    footer:SetPoint("BOTTOMRIGHT", -12, 8)
    footer:SetHeight(24)
    footer.text = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer.text:SetPoint("LEFT", 2, 0)
    footer.reload = UI.Button(footer, 150, "Reload for new summaries", function() ReloadUI() end)
    footer.reload:SetPoint("RIGHT", 0, 0)
    UI.Tooltip(footer.reload, "Reload the interface",
        "Loads the newest summaries from the app on your PC. The game also writes the record to disk, so the app can summarise it.")

    selectTab("journal")
end

function Window.Refresh()
    if not (win and win:IsShown()) then return end
    local c = rec().Char()
    win.titleText:SetText("JourneyMaster" .. (c and (": " .. tostring(c.name)) or ""))
    showFooter()
    if tab == "settings" then
        showSettings()
    else
        showList()
        showReader()
    end
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
    if C_Timer and C_Timer.After then C_Timer.After(0.5, run) else run() end
end

-- For the offline harness.
Window.State = function() return { tab = tab, selected = selected, filter = filter, items = list.items } end
Window.Select = function(s) selected = s Window.Refresh() end
Window.SelectTab = function(name) selectTab(name) end
Window.SetChip = function(key, on)
    if on then filter[key] = nil else filter[key] = false end
    if chips[key] then chips[key]:SetChecked(on) end
    showReader()
end
