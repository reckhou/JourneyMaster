-- JourneyMaster UI helpers: a scroll area with the game's classic scroll bar (shown only when the content does not
-- fit), a dark panel, tooltips, buttons and a block of wrapped text. Adapted from RPMaster's UI.lua.
-- Abbreviation: UI = user interface.
local _, ns = ...
local UI = {}
ns.UI = UI

local GUTTER = 24 -- room for the bar, which sits just outside the scroll frame's right edge
local STEP = 40   -- pixels a mouse-wheel notch scrolls

-- A scroll area inside `parent`. Place `area.frame` with SetPoint, put content in `area.child` (its width follows the
-- area's) and call area:SetContentHeight(h) once laid out. area.onResize(width) is called when the width changes.
function UI.ScrollArea(parent)
    local area = { contentHeight = 0 }
    local frame = CreateFrame("Frame", nil, parent)
    area.frame = frame
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", 0, 0)
    scroll:EnableMouseWheel(true)
    scroll.scrollBarHideable = true
    area.scroll = scroll
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    area.child = child
    local bar = scroll.ScrollBar
    bar.scrollStep = STEP
    bar:Hide()
    area.bar = bar

    local function fit()
        local range = math.max(0, math.floor(area.contentHeight - scroll:GetHeight()))
        bar:SetMinMaxValues(0, range)
        bar:SetShown(range > 0)
        scroll:SetPoint("BOTTOMRIGHT", range > 0 and -GUTTER or 0, 0)
        if bar:GetValue() > range then bar:SetValue(range) end
    end

    function area:SetContentHeight(h)
        self.contentHeight = h
        local width = scroll:GetWidth()
        if width and width > 0 then child:SetWidth(width) end
        child:SetHeight(math.max(1, h))
        fit()
    end
    function area:ScrollToTop() bar:SetValue(0) end
    function area:Width()
        local w = scroll:GetWidth()
        return (w and w > 0) and w or 300
    end

    scroll:SetScript("OnSizeChanged", function(_, width)
        child:SetWidth(width)
        if area.onResize then area.onResize(width) end
        fit()
    end)
    return area
end

-- A coloured panel behind a frame's content.
function UI.Shade(frame, r, g, b, a)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(r or 0, g or 0, b or 0, a or 0.35)
    return bg
end

-- Colours of the mock-up (docs/mockups/journey-window.html), as "rrggbb".
UI.C = {
    bg = "1b1712", edge = "6b5a3a", raised = "241c11", on = "4a3b22", titleTop = "3a2f1e",
    gold = "ffd100", text = "e8dcc0", soft = "c9b98f", muted = "a8997a", dim = "7d7260",
    button = "5a1c14", buttonEdge = "a8823c",
    finish = "1f4026", finishEdge = "5a9a62", finishText = "bfe6c3", -- the Finish session button: green, apart from Summarise and Reload
}

-- "rrggbb" to r, g, b between 0 and 1.
function UI.RGB(hex)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- "|cffrrggbb" for colouring text.
function UI.Code(hex) return "|cff" .. hex end

-- A solid texture in a colour on a layer of a frame (not yet placed).
function UI.Fill(frame, hex, layer, alpha)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND")
    local r, g, b = UI.RGB(hex)
    t:SetColorTexture(r, g, b, alpha or 1)
    return t
end

-- A filled box with a border of `size` pixels on its sides; `sides` limits the border (for example "TB" for top and
-- bottom only). Returns the fill texture, and the border textures in box.edges, so callers can recolour them.
function UI.Box(frame, fillHex, edgeHex, size, sides)
    size = size or 1
    sides = sides or "TBLR"
    local fill
    if fillHex then
        fill = UI.Fill(frame, fillHex, "BACKGROUND")
        fill:SetAllPoints()
    end
    local edges = {}
    local function edge(a1, a2, w, h)
        local t = UI.Fill(frame, edgeHex, "BORDER")
        t:SetPoint(a1)
        t:SetPoint(a2)
        if w then t:SetWidth(w) else t:SetHeight(h) end
        edges[#edges + 1] = t
    end
    if sides:find("T") then edge("TOPLEFT", "TOPRIGHT", nil, size) end
    if sides:find("B") then edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, size) end
    if sides:find("L") then edge("TOPLEFT", "BOTTOMLEFT", size, nil) end
    if sides:find("R") then edge("TOPRIGHT", "BOTTOMRIGHT", size, nil) end
    return { fill = fill, edges = edges }
end

-- A flat button in the mock-up's style: a box and a label. Width follows the label unless given.
-- Returns the button; button.label is its font string and button.box its box.
function UI.FlatButton(parent, label, font, fillHex, edgeHex, textHex, padding, height)
    local b = CreateFrame("Button", nil, parent)
    b.box = UI.Box(b, fillHex, edgeHex, 1)
    b.label = b:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    b.label:SetPoint("CENTER", 0, 0)
    b.label:SetText(label)
    b.label:SetTextColor(UI.RGB(textHex or UI.C.gold))
    b:SetSize((b.label:GetStringWidth() or 40) + 2 * (padding or 10), height or 20)
    local hl = UI.Fill(b, "ffffff", "HIGHLIGHT", 0.08)
    hl:SetAllPoints()
    return b
end

-- A tooltip on a widget. title and text may be functions, called each time it shows.
function UI.Tooltip(widget, title, text, anchor)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, anchor or "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine(type(title) == "function" and title() or title)
        local body = type(text) == "function" and text() or text
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function UI.Button(parent, width, label, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

-- Thumbnails are 512 by 256 pixels; the picture fills the top-left w by h of them (see New-Thumbnail in the app).
UI.THUMB_W, UI.THUMB_H = 512, 256

-- A thumbnail block: the texture scaled to the reader's width (never larger than the picture), in a bronze frame.
local function layoutImage(area, pool, b, x, y, width)
    pool.images = pool.images or {}
    pool.nImages = (pool.nImages or 0) + 1
    local holder = pool.images[pool.nImages]
    if not holder then
        holder = CreateFrame("Frame", nil, area.child)
        UI.Box(holder, "000000", UI.C.edge, 1)
        holder.tex = holder:CreateTexture(nil, "ARTWORK")
        holder.tex:SetPoint("TOPLEFT", 1, -1)
        holder.tex:SetPoint("BOTTOMRIGHT", -1, 1)
        pool.images[pool.nImages] = holder
    end
    local w, h = tonumber(b.w) or UI.THUMB_W, tonumber(b.h) or UI.THUMB_H
    local shownW = math.min(width, w)
    local shownH = math.floor(shownW * h / w + 0.5)
    holder.tex:SetTexture(b.image)
    holder.tex:SetTexCoord(0, w / UI.THUMB_W, 0, h / UI.THUMB_H)
    holder:SetSize(shownW + 2, shownH + 2)
    holder:ClearAllPoints()
    holder:SetPoint("TOPLEFT", area.child, "TOPLEFT", x, -y)
    holder:Show()
    return shownH + 2
end

-- Blocks of wrapped text, and thumbnails, stacked down a scroll area's child. Reuses its font strings and textures
-- between calls. blocks: list of { text = "...", font = "GameFontHighlight" (optional), colour = "rrggbb" (optional),
-- gap = pixels above (optional) } or { image = texture path, w, h (the part of the thumbnail the picture fills) }.
-- Returns the height used.
function UI.LayoutBlocks(area, pool, blocks)
    local pad = area.padding or 4
    local width = area:Width() - 2 * pad
    local y = pad
    local n = 0
    pool.nImages = 0
    for _, b in ipairs(blocks) do
      if b.image then
        y = y + (b.gap or 0)
        y = y + layoutImage(area, pool, b, pad, y, width) + 4
      else
        n = n + 1
        local i = n
        local fs = pool[i]
        if not fs then
            fs = area.child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetJustifyH("LEFT")
            fs:SetJustifyV("TOP")
            if fs.SetWordWrap then fs:SetWordWrap(true) end
            pool[i] = fs
        end
        fs:SetFontObject(b.font or "GameFontHighlight")
        fs:SetTextColor(UI.RGB(b.colour or UI.C.text))
        fs:SetWidth(width)
        fs:SetText(b.text or "")
        y = y + (b.gap or 0)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", area.child, "TOPLEFT", pad, -y)
        fs:Show()
        y = y + (fs:GetStringHeight() or 14) + 4
      end
    end
    for i = n + 1, #pool do pool[i]:Hide() end
    for i = pool.nImages + 1, #(pool.images or {}) do pool.images[i]:Hide() end
    area:SetContentHeight(y + pad)
    return y
end
