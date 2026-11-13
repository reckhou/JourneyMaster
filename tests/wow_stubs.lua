-- Stand-ins for the game's API, enough to load JourneyMaster offline and build its window. Every widget is a table
-- that accepts any method call; the few methods whose return values the add-on uses give sensible values.
-- Used by tests/addon_harness.lua (loaded with dofile, so it is not run on its own).
local W = { now = 1794520000, zone = "Elwynn Forest", sub = "Goldshire", instance = { false, "none" }, name = "Instance",
    secret = {}, money = 0, group = {}, quest = {}, recap = {}, shots = 0, chatLogging = false, reloads = 0, timers = {} }
STUB = W

time = function() return W.now end
date = os.date

local widgetMethods = {}
local Widget = {}
Widget.__index = function(self, key)
    if widgetMethods[key] then return widgetMethods[key] end
    return function() return nil end -- any other method: accepted and ignored
end

local function new(kind, name)
    local w = setmetatable({ kind = kind, scripts = {}, events = {}, shown = true, checked = false, width = 300, height = 300, text = "" }, Widget)
    if kind == "ScrollFrame" then w.ScrollBar = new("Slider") end
    if name then _G[name] = w end
    return w
end
W.new = new

widgetMethods.SetScript = function(self, name, fn) self.scripts[name] = fn end
widgetMethods.HookScript = function(self, name, fn) self.scripts[name] = fn end
widgetMethods.GetScript = function(self, name) return self.scripts[name] end
widgetMethods.Show = function(self) self.shown = true end
widgetMethods.Hide = function(self) self.shown = false end
widgetMethods.SetShown = function(self, v) self.shown = v and true or false end
widgetMethods.IsShown = function(self) return self.shown end
widgetMethods.IsVisible = function(self) return self.shown end
widgetMethods.SetText = function(self, v) self.text = v end
widgetMethods.GetText = function(self) return self.text end
widgetMethods.SetChecked = function(self, v) self.checked = v and true or false end
widgetMethods.GetChecked = function(self) return self.checked end
widgetMethods.SetWidth = function(self, v) self.width = v end
widgetMethods.SetHeight = function(self, v) self.height = v end
widgetMethods.SetSize = function(self, w, h) self.width, self.height = w, h end
widgetMethods.GetWidth = function(self) return self.width end
widgetMethods.GetHeight = function(self) return self.height end
widgetMethods.GetStringHeight = function(self) local n = 1 for _ in tostring(self.text):gmatch("\n") do n = n + 1 end return n * 14 end
widgetMethods.GetStringWidth = function(self) return #tostring(self.text) * 6 end
widgetMethods.GetMinMaxValues = function() return 0, 0 end
widgetMethods.GetValue = function() return 0 end
widgetMethods.GetEffectiveScale = function() return 1 end
widgetMethods.GetCenter = function() return 0, 0 end
widgetMethods.CreateFontString = function() return new("FontString") end
widgetMethods.CreateTexture = function() return new("Texture") end
widgetMethods.RegisterEvent = function(self, ev) self.events[ev] = true end
widgetMethods.Click = function(self, ...) if self.scripts.OnClick then self.scripts.OnClick(self, ...) end end

CreateFrame = function(kind, name) return new(kind, name) end
UIParent = new("Frame")
Minimap = new("Frame")
Minimap.width = 140
GameTooltip = new("GameTooltip")
DEFAULT_CHAT_FRAME = new("Frame")
W.chat = {}
DEFAULT_CHAT_FRAME.AddMessage = function(_, msg) W.chat[#W.chat + 1] = msg end
UISpecialFrames = {}
tinsert = table.insert
PanelTemplates_SetTab = function() end
PanelTemplates_SetNumTabs = function() end
PanelTemplates_TabResize = function() end
GetCursorPosition = function() return 0, 100 end
ReloadUI = function() W.reloads = W.reloads + 1 end
W.tickers = {}
C_Timer = {
    After = function(_, fn) W.timers[#W.timers + 1] = fn end,
    -- W.ticker is the first ticker made (the recorder's); every ticker is also kept in W.tickers.
    NewTicker = function(_, fn)
        local t = { fn = fn }
        function t:Cancel() self.cancelled = true end
        W.tickers[#W.tickers + 1] = t
        W.ticker = W.ticker or fn
        return t
    end,
}
-- Runs every ticker not cancelled, except the first, until all are cancelled (at most n rounds).
function W.RunSignalTickers(n)
    for _ = 1, n or 1000 do
        local live = false
        for i = 2, #W.tickers do
            local t = W.tickers[i]
            if not t.cancelled then live = true t.fn() end
        end
        if not live then return end
    end
end
W.system = {}
SendSystemMessage = function(line) W.system[#W.system + 1] = line end
ChatFrame_AddMessageEventFilter = function(event, fn) W.filters = W.filters or {} W.filters[event] = fn end
C_ChatInfo = { IsLoggingChat = function() return W.chatLogging end }
function W.RunTimers()
    local list = W.timers
    W.timers = {}
    for _, fn in ipairs(list) do fn() end
end

issecretvalue = function(v) return W.secret[v] == true end
UnitName = function(unit)
    if unit == "player" then return "Baldrake Cavendell" end
    if unit == "questnpc" or unit == "npc" then return W.quest.giver end
    local i = tonumber(unit:match("^party(%d)$") or "")
    return i and W.group[i] or nil
end
GetRealmName = function() return "Living Flame" end
UnitClass = function() return "Warlock", "WARLOCK" end
UnitRace = function() return "Human", "Human" end
UnitSex = function() return 2 end
UnitFactionGroup = function() return "Alliance" end
UnitLevel = function() return 26 end
GetMoney = function() return W.money end
GetRealZoneText = function() return W.zone end
GetSubZoneText = function() return W.sub end
IsInInstance = function() return W.instance[1], W.instance[2] end
GetInstanceInfo = function() return W.name, W.instance[2] end
GetNumGroupMembers = function() return #W.group > 0 and #W.group + 1 or 0 end
IsInRaid = function() return false end
LoggingChat = function(v) if v ~= nil then W.chatLogging = v end return W.chatLogging end
GetTitleText = function() return W.quest.title end
GetQuestText = function() return W.quest.text end
GetObjectiveText = function() return W.quest.obj end
GetRewardText = function() return W.quest.reward end
C_QuestLog = { GetTitleForQuestID = function(id) return W.quest.byId and W.quest.byId[id] end }
C_DeathRecap = { GetRecapEvents = function(id) return W.recap[id] end }
GetInventoryItemLink = function(_, slot) return W.gear and W.gear[slot] end
Screenshot = function() W.shots = W.shots + 1 end
RequestTimePlayed = function() end
InCombatLockdown = function() return false end
StaticPopupDialogs = {}
StaticPopup_Show = function(name) W.popup = name end

-- Loads the add-on's files in the order its TOC lists them.
function W.LoadAddOn()
    local ns = {}
    local toc = assert(io.open("src/JourneyMaster/JourneyMaster.toc")):read("*a")
    for file in toc:gmatch("\n([%w_]+%.lua)") do
        assert(loadfile("src/JourneyMaster/" .. file))("JourneyMaster", ns)
    end
    return ns
end

-- Fires a game event at the add-on's frame.
function W.Fire(ns, event, ...)
    ns.frame.scripts.OnEvent(ns.frame, event, ...)
end

return W
