-- Unkicked :: Panel.lua
--
-- One row per unkicked cast: what landed, what it cost, whether someone died,
-- and who had an interrupt available when it began.
--
-- Deliberately reports FACTS and not a verdict. The addon cannot see whether a
-- party member was in range of the caster, so "their kick was up" is as far as
-- the data goes -- the human applies the judgment.
--
-- On 12.x there is no cast feed, so the panel has THREE modes and says which one
-- it is in rather than looking broken:
--
--   feed   -- one row per unkicked cast. Needs COMBAT_LOG_EVENT_UNFILTERED,
--             which 12.0.0 removed, so this is unreachable on a live client and
--             is kept for the offline parser's sake (same model, same rows).
--   meter  -- one row per player: interrupts pressed, deaths, damage taken, from
--             C_DamageMeter, per pull and per key. This is what you actually see
--             in a dungeon today. It answers "who is kicking", NOT "what got
--             through" -- that needs the log parser, and the footer says so.
--   blind  -- neither feed nor meter. Two honest lines instead of empty rows.

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

-- Four generic columns, because the two modes want different things in them:
--   feed  -- c1 spell, c2 damage, c4 who had a kick up
--   meter -- c1 player, c2 kicks, c3 deaths, c4 damage taken
-- One widget set rather than two keeps the row heights and hit areas identical,
-- which matters because the tooltip hangs off the row and not off a column.
-- Meter mode. Everything here must survive the numbers being secret, so the
-- per-spell drill-down (which needs a readable GUID handed back to the API)
-- simply does not appear during a pull.
local function meterTooltip(p)
  GameTooltip:AddLine(p.name or "?", 1, 1, 1)
  if p.isYou then GameTooltip:AddLine("you", 0.7, 0.7, 0.7) end
  GameTooltip:AddLine(" ")

  if p.plain then
    GameTooltip:AddDoubleLine("Interrupts", ("%d"):format(p.kicks or 0), 1, 1, 1, 1, 0.82, 0)
    GameTooltip:AddDoubleLine("Deaths", ("%d"):format(p.deaths or 0), 1, 1, 1,
      (p.deaths or 0) > 0 and 1 or 0.7, (p.deaths or 0) > 0 and 0.2 or 0.7, 0.2)
    GameTooltip:AddDoubleLine("Damage taken", ns.Short(p.taken), 1, 1, 1, 1, 0.82, 0)

    local spells = p.guid and ns.Meter:Spells(p.segment, p.guid, p.creatureID)
    if spells and spells[1] then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Interrupts by spell", 1, 1, 1)
      for i = 1, math.min(#spells, 6) do
        local sp = spells[i]
        local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sp.spellID))
          or tostring(sp.spellID)
        GameTooltip:AddDoubleLine(name, tostring(ns.Plain(sp.totalAmount) or "?"),
          0.8, 0.8, 0.8, 1, 0.82, 0)
      end
    end
  else
    -- In combat the amounts are secret: they can be shown, never read. The
    -- numbers on the row itself are real -- they went straight to the widget.
    GameTooltip:AddLine("In combat these numbers can be displayed but not", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("inspected, so there is no breakdown until the pull ends.", 0.6, 0.6, 0.6)
  end

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Interrupts pressed -- not casts missed.", 1, 0.6, 0.2)
  GameTooltip:AddLine("Whether a cast was interruptible is not in this API;", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("parse WoWCombatLog.txt for what actually got through.", 0.7, 0.7, 0.7)
end


local function buildRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(WIDTH - 16, ROW_H)
  row:SetPoint("TOPLEFT", 8, -(22 + (index - 1) * ROW_H))

  row.c1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.c1:SetPoint("LEFT")
  row.c1:SetWidth(140)
  row.c1:SetJustifyH("LEFT")
  row.c1:SetWordWrap(false)

  row.c2 = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.c2:SetPoint("LEFT", row.c1, "RIGHT", 4, 0)
  row.c2:SetWidth(46)
  row.c2:SetJustifyH("RIGHT")

  row.c3 = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.c3:SetPoint("LEFT", row.c2, "RIGHT", 4, 0)
  row.c3:SetWidth(28)
  row.c3:SetJustifyH("RIGHT")

  row.c4 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.c4:SetPoint("LEFT", row.c3, "RIGHT", 6, 0)
  row.c4:SetPoint("RIGHT")
  row.c4:SetJustifyH("LEFT")
  row.c4:SetWordWrap(false)

  row:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.rec then tooltipFor(self.rec)
    elseif self.player then meterTooltip(self.player)
    else return end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

-- Which of the three modes we are in. Checked on every refresh rather than
-- cached: the meter can become available later than login, and the restriction
-- state genuinely changes as you walk through a dungeon door.
local function mode()
  if not (ns.blocked and ns.blocked["COMBAT_LOG_EVENT_UNFILTERED"]) then return "feed" end
  if ns.Meter and ns.Meter:Available() then return "meter" end
  return "blind"
end

-- A party is five, so meter mode never needs twelve rows -- and a row area sized
-- for twelve with five in it reads as a list that failed to load.
local METER_ROWS = 6

local function rowCount(m)
  if m == "meter" then return METER_ROWS end
  return ns.db.maxRows or 12
end

local function heightFor(m)
  if m == "blind" then return 22 + ROW_H * 2 + 10 end
  -- header row + rows + footer + log line
  return 22 + ROW_H + ROW_H * rowCount(m) + 18 + ROW_H
end

function Panel:Layout()
  if not frame then return end
  frame:SetSize(WIDTH, heightFor(mode()))
end

function Panel:Build()
  if frame then return frame end

  frame = CreateFrame("Frame", "UnkickedPanel", UIParent, "BackdropTemplate")
  frame:SetSize(WIDTH, heightFor(mode()))
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

  -- The segment toggle. Blizzard ships Enum.DamageMeterSessionType, so current
  -- vs overall is a native idea here and not something we have to accumulate --
  -- but the overall WE show is the keystone window, summed from the pulls, so it
  -- agrees with what the offline parser reports for the same run.
  frame.seg = CreateFrame("Button", nil, frame)
  frame.seg:SetPoint("TOPRIGHT", -8, -4)
  frame.seg:SetSize(130, ROW_H)
  frame.seg.text = frame.seg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.seg.text:SetPoint("RIGHT")
  frame.seg.text:SetJustifyH("RIGHT")
  frame.seg:SetScript("OnClick", function() Panel:Segment() end)
  frame.seg:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Segment", 1, 1, 1)
    GameTooltip:AddLine("Click to switch between this pull and the whole key.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  frame.seg:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Kept as an alias: Logging and the tests reach for frame.stat.
  frame.stat = frame.seg.text

  frame.head = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.head:SetPoint("TOPLEFT", 8, -22)
  frame.head:SetPoint("TOPRIGHT", -8, -22)
  frame.head:SetJustifyH("RIGHT")

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
  for i = 1, math.max(METER_ROWS, ns.db.maxRows or 12) do rows[i] = buildRow(frame, i) end

  self:Layout()
  return frame
end

function Panel:Segment(which)
  ns.db.segment = which or (ns.db.segment == "overall" and "current" or "overall")
  self:Refresh()
  return ns.db.segment
end

local function hideRows(from)
  for i = from, #rows do
    rows[i].rec, rows[i].player = nil, nil
    rows[i]:Hide()
  end
end

-- ------------------------------------------------------------------ feed mode
local function refreshFeed()
  local recs = ns.Cast.records
  local shown = 0

  frame.head:SetText("")
  for i = 1, rowCount("feed") do
    local row = rows[i]
    local rec = recs[i]
    if rec and rec.damage >= (ns.db.minDamage or 0) then
      shown = shown + 1
      row.rec, row.player = rec, nil

      local mark = ""
      if next(rec.deaths) then mark = "|cffff2020*|r "
      elseif rec.interruptible == nil then mark = "|cffff9933?|r " end
      row.c1:SetText(mark .. rec.spellName)
      row.c2:SetText(("|cffffd200%s|r"):format(ns.Short(rec.damage)))
      row.c3:SetText("")

      local k = rec.kicks
      if #k.ready > 0 then
        row.c4:SetText(namesOf(k.ready, 3))
      elseif #k.cc > 0 then
        row.c4:SetText("|cff80b0ffcc|r")
      elseif #k.unknown > 0 then
        row.c4:SetText("|cffff9933?|r")
      else
        row.c4:SetText("|cff808080all down|r")
      end
      row:Show()
    else
      row.rec, row.player = nil, nil
      row:Hide()
    end
  end
  hideRows(rowCount("feed") + 1)

  local casts, damage, deaths = ns.Cast:Summary()
  frame.seg.text:SetText(("%d casts  |cffffd200%s|r%s")
    :format(casts, ns.Short(damage), deaths > 0 and ("  |cffff2020%d deaths|r"):format(deaths) or ""))

  if ns.staleData then
    frame.footer:SetText(("|cffff9933data built for %s|r"):format(ns.staleData))
  elseif shown == 0 then
    frame.footer:SetText("nothing got through")
  else
    frame.footer:SetText("")
  end
end

-- ----------------------------------------------------------------- meter mode
-- Rendering a number the addon is not allowed to read.
--
-- In combat every amount is a secret value: no comparing, no arithmetic, no
-- string.format. FontString:SetText is whitelisted to ACCEPT one, so the only
-- legal move is to hand the raw value over untouched and let the widget draw it.
-- Which means: no colour wrapper, no "k"/"m" shortening, no hiding a zero -- all
-- of those read the value. Out of combat the same field is a plain number again
-- and the formatted path applies.
local function setAmount(fs, value, plain, fmt)
  if value == nil then fs:SetText("") return end
  if plain then fs:SetText(fmt(value)) else fs:SetText(value) end
end

local function refreshMeter()
  local segment = ns.db.segment == "overall" and "overall" or "current"
  local data, plain, label

  if segment == "overall" then
    local total = ns.Meter:Total()
    if total then
      data, plain = total.rows, true
      label = ("|cffffd200run|r  %s  %d pulls"):format(ns.Meter:Clock(total.duration), total.pulls)
    else
      data, plain, label = {}, true, "|cffffd200run|r  no pulls yet"
    end
  else
    local r, isPlain = ns.Meter:Rows("current")
    data, plain = r or {}, isPlain ~= false
    local n = #ns.Meter.pulls
    label = ("|cffffd200pull %d|r  %s"):format(
      math.max(n, 1), ns.Meter:Clock(ns.Meter:Duration("current") or 0))
  end

  frame.seg.text:SetText(label)
  frame.head:SetText("|cff808080kicks  died   taken|r")

  local shown = 0
  for i = 1, rowCount("meter") do
    local row, p = rows[i], data[i]
    if p then
      shown = shown + 1
      p.plain, p.segment = plain, segment
      row.rec, row.player = nil, p
      row.c1:SetText(("|c%s%s|r%s"):format(ns.ClassColor(p.class),
        p.name or "?", p.isYou and " |cff808080(you)|r" or ""))
      setAmount(row.c2, p.kicks, plain, function(v) return ("|cffffd200%d|r"):format(v) end)
      setAmount(row.c3, p.deaths, plain, function(v)
        return v > 0 and ("|cffff2020%d|r"):format(v) or "|cff5050500|r"
      end)
      setAmount(row.c4, p.taken, plain, function(v) return "|cff808080" .. ns.Short(v) .. "|r" end)
      row:Show()
    else
      row.rec, row.player = nil, nil
      row:Hide()
    end
  end
  hideRows(rowCount("meter") + 1)

  -- Said on every refresh, not once in a readme. This panel counts interrupts
  -- PRESSED; the thing the addon is named after -- a cast nobody stopped -- is
  -- not in this API and never will be, so pretending by omission is the one
  -- failure mode worth designing against.
  if shown == 0 then
    frame.footer:SetText("|cff808080no combat yet -- kicks pressed appear here per pull|r")
  elseif not plain then
    frame.footer:SetText("|cff808080live: kicks pressed (not casts missed)|r")
  else
    frame.footer:SetText("|cff808080kicks pressed -- missed casts: parse the log|r")
  end
end

-- ----------------------------------------------------------------- blind mode
local function refreshBlind()
  hideRows(1)
  frame.seg.text:SetText("")
  frame.head:SetText("")
  frame.footer:SetText("|cffff2020no feed on this client|r -- |cffffd200/uk why|r")
end

function Panel:Refresh()
  if not frame then return end
  local m = mode()
  self:Layout()

  if m == "feed" then refreshFeed()
  elseif m == "meter" then refreshMeter()
  else refreshBlind() end

  frame.log.text:SetText((ns.Logging and ns.Logging:Label()) or "")
end

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
