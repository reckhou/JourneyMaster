-- JourneyMaster window (mock-up revision B in docs/mockups/journey-window.html): two panes, about 700 by 500 pixels.
-- A session list on the left drives the reader on the right; the Journal, Log and Settings tabs run along the top.
-- Journal shows a session's summary, Log its raw entries with one on/off chip per kind, Settings the switches.
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
local C = UI.C
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
        label:SetTextColor(UI.RGB(C.text))
        if s[3] then UI.Tooltip(c, s[2], s[3]) end
        settingsChecks[s[1]] = c
        y = y - 28
    end
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    note:SetTextColor(UI.RGB(C.muted))
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
    win.sessions:SetShown(name ~= "settings")
    win.settings:SetShown(name == "settings")
    win.chipBar:SetShown(name == "log")
    reader.area.frame:SetPoint("TOPLEFT", reader.pane, "TOPLEFT", 0, name == "log" and -win.chipBar.used or 0)
    Window.Refresh()
end

-- One chip per kind, in the kind's colour, as in the mock-up: full strength when shown, faded when hidden. Chips wrap
-- onto a new row when the reader is too narrow for them all. Returns the height the chips use.
local function buildChips(parent, width)
    local x, y = 0, 0
    for _, kind in ipairs(Core.KINDS) do
        local b = UI.FlatButton(parent, kind.label, "GameFontHighlightSmall", C.bg, C.edge, kind.colour, 8, CHIP_H)
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

    win.settings = CreateFrame("Frame", nil, win)
    win.settings:SetPoint("TOPLEFT", EDGE + 8, -BODY_TOP)
    win.settings:SetPoint("BOTTOMRIGHT", -(EDGE + 8), EDGE + FOOT_H)
    win.settings:Hide()
    buildSettings(win.settings)

    -- Foot: a bronze line, the counts in muted text, the reload button in the mock-up's red and gold. The button is as
    -- wide as its label, and the counts stop short of it.
    footer = CreateFrame("Frame", nil, win)
    footer:SetPoint("BOTTOMLEFT", EDGE, EDGE)
    footer:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
    footer:SetHeight(FOOT_H)
    UI.Box(footer, nil, C.edge, 2, "T")
    footer.reload = UI.FlatButton(footer, "Reload for new summaries", "GameFontNormalSmall", C.button, C.buttonEdge, C.gold, 12, 20)
    footer.reload:SetScript("OnClick", function() ReloadUI() end)
    footer.reload:SetPoint("RIGHT", -10, -1)
    UI.Tooltip(footer.reload, "Reload the interface",
        "Loads the newest summaries from the app on your PC. The game also writes the record to disk, so the app can summarise it.")
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
    if C_Timer and C_Timer.After then C_Timer.After(0.5, ns.Recorder.Guard("the journal window", run)) else run() end
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
