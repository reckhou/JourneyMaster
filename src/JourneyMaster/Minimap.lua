-- JourneyMaster minimap button and add-on menu entry. A click opens or closes the window; dragging moves the button
-- round the minimap's edge, and its angle is saved per character. Built by hand, with no library (the same approach
-- as RPMaster's button, observed working on Forever in Phase 0, check 10). A setting hides it; /jm still opens the window.
-- Abbreviation: UI = user interface.
local _, ns = ...
local Core = ns.Core
local M = {}
ns.Minimap = M

M.ICON = "Interface\\AddOns\\JourneyMaster\\Icon"
local RADIUS = 5 -- how far outside the minimap's edge the button's centre sits

-- Where the button's centre sits for an angle in degrees, on the circle or on a square minimap's edge. Pure.
function M.Offset(angle, half, square)
    local rad = math.rad(angle)
    local x, y = math.cos(rad), math.sin(rad)
    local reach = half + RADIUS
    if square then
        local m = math.max(math.abs(x), math.abs(y))
        return x / m * reach, y / m * reach
    end
    return x * reach, y * reach
end

-- The angle in degrees from the minimap's centre to a point. Pure.
function M.Angle(dx, dy)
    return math.deg(math.atan2(dy, dx)) % 360
end

local button

local function char() return ns.Recorder.Char() end

local function savedAngle()
    local c = char()
    return c and tonumber(c.minimapAngle) or 200
end

function M.Place()
    if not button then return end
    local half = (Minimap:GetWidth() or 140) / 2
    local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
    local x, y = M.Offset(savedAngle(), half, square)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function M.Refresh()
    if not button then return end
    button:SetShown(ns.Recorder.Setting("minimapButton") and true or false)
    M.Place()
end

-- The tooltip's second line: entries recorded and the date of the newest summary.
function M.Summary()
    local c = char()
    local n = c and #c.entries or 0
    local last = ns.Journal and ns.Journal.LastSummaryDate()
    return n .. " entries recorded" .. "\nLast summary: " .. (last or "none yet")
end

local function dragUpdate()
    local c = char()
    if not c then return end
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = Minimap:GetCenter()
    local mx, my = GetCursorPosition()
    c.minimapAngle = M.Angle(mx / scale - cx, my / scale - cy)
    M.Place()
end

function M.Create()
    if button or not CreateFrame or not Minimap then return end
    button = CreateFrame("Button", "JourneyMasterMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture(M.ICON)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button:SetScript("OnClick", function() ns.Window.Toggle() end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", dragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    ns.UI.Tooltip(button, "JourneyMaster", function() return "Click to open the journal. Drag to move.\n" .. M.Summary() end, "ANCHOR_LEFT")
    M.Refresh()
end
M.button = function() return button end

-- The add-on menu entry (named in JourneyMaster.toc); it stays when the button is hidden.
function JourneyMaster_OnCompartmentClick() ns.Window.Toggle() end
function JourneyMaster_OnCompartmentEnter(_, anchor)
    GameTooltip:SetOwner(anchor, "ANCHOR_LEFT")
    GameTooltip:AddLine("JourneyMaster")
    GameTooltip:AddLine("Click to open the journal.\n" .. M.Summary(), 1, 1, 1, true)
    GameTooltip:Show()
end
function JourneyMaster_OnCompartmentLeave() GameTooltip:Hide() end
