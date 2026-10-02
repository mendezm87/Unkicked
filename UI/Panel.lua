-- Unkicked :: Panel.lua
--
-- One row per unkicked cast: what landed, what it cost, whether someone died,
-- and who had an interrupt available when it began.
--
-- Deliberately reports FACTS and not a verdict. The addon cannot see whether a
-- party member was in range of the caster, so "their kick was up" is as far as
-- the data goes -- the human applies the judgment.

local ADDON, ns = ...

local Panel = {}
ns.Panel = Panel

local ROW_H = 16
local WIDTH = 330

local frame, rows

local function namesOf(list, limit)
  local out = {}
  for i = 1, math.min(#list, limit or 4) do
    local r = list[i]
    out[#out + 1] = ("|c%s%s|r"):format(ns.ClassColor(r.class), r.name or "?")
  end
  if #list > (limit or 4) then out[#out + 1] = ("+%d"):format(#list - (limit or 4)) end
  return table.concat(out, " ")
end

local function tooltipFor(rec)
  GameTooltip:AddLine(rec.spellName, 1, 1, 1)
  GameTooltip:AddLine(rec.srcName or "?", 0.7, 0.7, 0.7)
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Damage", ns.Short(rec.damage), 1, 1, 1, 1, 0.82, 0)
  if rec.interruptible == nil then
    GameTooltip:AddLine("Interruptible: unknown (no nameplate on the caster)", 1, 0.6, 0.2)
  elseif rec.interruptible then
    GameTooltip:AddLine("Interruptible: yes", 0.3, 1, 0.3)
  else
    GameTooltip:AddLine("Interruptible: no", 0.6, 0.6, 0.6)
  end

  for name, dmg in pairs(rec.deaths) do
    GameTooltip:AddLine(("Contributed to %s's death (%s)"):format(name, ns.Short(dmg)), 1, 0.2, 0.2)
  end

  GameTooltip:AddLine(" ")
  local k = rec.kicks
  if #k.ready > 0 then GameTooltip:AddLine("Interrupt available: " .. namesOf(k.ready, 8), 1, 0.82, 0) end
  if #k.down > 0 then
    local parts = {}
    for _, r in ipairs(k.down) do
      parts[#parts + 1] = ("%s (%.1fs)"):format(r.name or "?", tonumber(r.detail) or 0)
    end
    GameTooltip:AddLine("On cooldown: " .. table.concat(parts, ", "), 0.6, 0.6, 0.6)
  end
  if #k.cc > 0 then
    local parts = {}
    for _, r in ipairs(k.cc) do parts[#parts + 1] = ("%s (%s)"):format(r.name or "?", r.detail or "cc") end
    GameTooltip:AddLine("Could not act: " .. table.concat(parts, ", "), 0.5, 0.7, 1)
  end
  if #k.unknown > 0 then
    local parts = {}
    for _, r in ipairs(k.unknown) do parts[#parts + 1] = ("%s (%s)"):format(r.name or "?", r.detail or "?") end
    GameTooltip:AddLine("Unknown: " .. table.concat(parts, ", "), 1, 0.6, 0.2)
  end
end

local function buildRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(WIDTH - 16, ROW_H)
  row:SetPoint("TOPLEFT", 8, -(22 + (index - 1) * ROW_H))

  row.spell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.spell:SetPoint("LEFT")
  row.spell:SetWidth(140)
  row.spell:SetJustifyH("LEFT")
  row.spell:SetWordWrap(false)

  row.dmg = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.dmg:SetPoint("LEFT", row.spell, "RIGHT", 4, 0)
  row.dmg:SetWidth(46)
  row.dmg:SetJustifyH("RIGHT")

  row.who = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.who:SetPoint("LEFT", row.dmg, "RIGHT", 6, 0)
  row.who:SetPoint("RIGHT")
  row.who:SetJustifyH("LEFT")
  row.who:SetWordWrap(false)

  row:SetScript("OnEnter", function(self)
    if not self.rec then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    tooltipFor(self.rec)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

-- On 12.x there is no combat-log feed, so the row area can never fill: twelve
-- empty rows read as "broken", and the one thing the panel can still tell you
-- (is the client writing the log?) gets lost in the middle of them. So the frame
-- collapses to the header plus the log line when there is no feed.
local function compact()
  return ns.blocked and ns.blocked["COMBAT_LOG_EVENT_UNFILTERED"] and true or false
end

local function fullHeight()
  return 22 + ROW_H * (ns.db.maxRows or 12) + 20 + ROW_H
end

local function compactHeight()
  return 22 + ROW_H * 2 + 10
end

function Panel:Layout()
  if not frame then return end
  frame:SetSize(WIDTH, compact() and compactHeight() or fullHeight())
end

function Panel:Build()
  if frame then return frame end

  frame = CreateFrame("Frame", "UnkickedPanel", UIParent, "BackdropTemplate")
  frame:SetSize(WIDTH, fullHeight())
  frame:SetPoint(unpack(ns.db.point))
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  frame:SetBackdropColor(0, 0, 0, 0.72)
  frame:SetBackdropBorderColor(0, 0, 0, 1)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    if not ns.db.locked then self:StartMoving() end
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    ns.db.point = { point, x, y }
  end)

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.title:SetPoint("TOPLEFT", 8, -6)
  frame.title:SetText("Unkicked")

  frame.stat = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.stat:SetPoint("TOPRIGHT", -8, -6)

  frame.footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.footer:SetPoint("BOTTOMLEFT", 8, 6 + ROW_H)
  frame.footer:SetPoint("BOTTOMRIGHT", -8, 6 + ROW_H)
  frame.footer:SetJustifyH("LEFT")

  -- Whether the client is writing WoWCombatLog.txt. On 12.x this is the one
  -- genuinely load-bearing thing the in-game panel still reports, because the
  -- analysis happens offline and a run you forgot to /combatlog is gone.
  frame.log = CreateFrame("Button", nil, frame)
  frame.log:SetPoint("BOTTOMLEFT", 8, 6)
  frame.log:SetPoint("BOTTOMRIGHT", -8, 6)
  frame.log:SetHeight(ROW_H)
  frame.log.text = frame.log:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.log.text:SetPoint("LEFT")
  frame.log.text:SetJustifyH("LEFT")
  frame.log.text:SetWordWrap(false)
  frame.log:SetScript("OnClick", function()
    local _, v = ns.Logging:Label()
    -- Only offer the one action we can actually take. Advanced logging is a
    -- cvar behind a settings panel and we do not change settings behind you.
    if v == "off" then ns.Logging:Set(true) else ns.Logging:Query(true) end
    Panel:Refresh()
  end)
  frame.log:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Combat log", 1, 1, 1)
    for _, l in ipairs(ns.Logging:Lines()) do GameTooltip:AddLine(l.text, l.r, l.g, l.b) end
    GameTooltip:Show()
  end)
  frame.log:SetScript("OnLeave", function() GameTooltip:Hide() end)

  rows = {}
  for i = 1, (ns.db.maxRows or 12) do rows[i] = buildRow(frame, i) end

  self:Layout()
  return frame
end

function Panel:Refresh()
  if not frame then return end
  local recs = ns.Cast.records
  local shown = 0

  if compact() then
    for i = 1, #rows do rows[i].rec = nil; rows[i]:Hide() end
    frame.stat:SetText("")
    frame.footer:SetText("|cffff2020no combat log in 12.x|r -- parse the log file, |cffffd200/uk why|r")
    frame.log.text:SetText((ns.Logging and ns.Logging:Label()) or "")
    return
  end

  for i = 1, #rows do
    local row = rows[i]
    local rec = recs[i]
    if rec and rec.damage >= (ns.db.minDamage or 0) then
      shown = shown + 1
      row.rec = rec

      local mark = ""
      if next(rec.deaths) then mark = "|cffff2020*|r "
      elseif rec.interruptible == nil then mark = "|cffff9933?|r " end
      row.spell:SetText(mark .. rec.spellName)

      row.dmg:SetText(("|cffffd200%s|r"):format(ns.Short(rec.damage)))

      local k = rec.kicks
      if #k.ready > 0 then
        row.who:SetText(namesOf(k.ready, 3))
      elseif #k.cc > 0 then
        row.who:SetText("|cff80b0ffcc|r")
      elseif #k.unknown > 0 then
        row.who:SetText("|cffff9933?|r")
      else
        row.who:SetText("|cff808080all down|r")
      end
      row:Show()
    else
      row.rec = nil
      row:Hide()
    end
  end

  local casts, damage, deaths = ns.Cast:Summary()
  frame.stat:SetText(("%d casts  |cffffd200%s|r%s")
    :format(casts, ns.Short(damage), deaths > 0 and ("  |cffff2020%d deaths|r"):format(deaths) or ""))

  frame.log.text:SetText((ns.Logging and ns.Logging:Label()) or "")

  if ns.blocked["COMBAT_LOG_EVENT_UNFILTERED"] then
    -- Be blunt rather than look broken: with no combat log there is no feed,
    -- so an empty panel is not "a quiet pull", it is "this cannot work".
    frame.footer:SetText("|cffff2020no combat log in 12.x -- see /uk why|r")
  elseif ns.staleData then
    frame.footer:SetText(("|cffff9933data built for %s|r"):format(ns.staleData))
  elseif shown == 0 then
    frame.footer:SetText("nothing got through")
  else
    frame.footer:SetText("")
  end
end

-- Recovers a panel you cannot see: back to the default position, unlocked and
-- shown. A frame dragged off the edge of the screen, or a saved position from a
-- different resolution, is otherwise unreachable without wiping SavedVariables.
function Panel:Reset()
  ns.db.point = { "CENTER", 240, 80 }
  ns.db.locked = false
  self:Build()
  frame:ClearAllPoints()
  frame:SetPoint(unpack(ns.db.point))
  self:Layout()
  self:Toggle(true)
end

function Panel:Toggle(show)
  self:Build()
  if show == nil then show = not frame:IsShown() end
  ns.db.showPanel = show
  if show then frame:Show() self:Refresh() else frame:Hide() end
end

ns.On("PLAYER_LOGIN", function()
  Panel:Build()
  if ns.db.showPanel then frame:Show() else frame:Hide() end
  Panel:Refresh()
  -- Say where it is. With no feed the panel is a small card and easy to miss
  -- behind another addon, and "I saw nothing in the UI" is indistinguishable
  -- from "it failed to load" unless the addon says which one happened.
  if ns.db.showPanel then
    ns.Print("panel is on screen (" .. tostring(ns.db.point and ns.db.point[1] or "CENTER")
      .. "). |cffffd200/uk|r toggles it, |cffffd200/uk reset|r recentres it if you cannot see it.")
  end
end)
