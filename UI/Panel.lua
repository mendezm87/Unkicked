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
local WIDTH = 360

-- Column geometry, shared by the data rows AND the header, because the two
-- drifting apart is exactly how the header ends up sitting on top of row one.
--   c1 name/spell (flexes)  c2 kicks  c3 died  c4 taken  c5 kickable/names
local C2_W, C3_W, C4_W, C5_W = 38, 28, 56, 60
local GAP = 6
local C1_W = WIDTH - 16 - (C2_W + C3_W + C4_W + C5_W + GAP * 4)

-- The first data row sits BELOW the header row, not on it.
local HEAD_Y = 22
local ROWS_Y = HEAD_Y + ROW_H

local frame, rows, menu, clearBox, colBox, auditBox

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
  -- A warlock's interrupts are his demon's. Folding them onto his row is right, but
  -- it has to be visible, or his kick count looks like it came from nowhere.
  if p.withPet then
    GameTooltip:AddLine(("includes %d pet row%s"):format(p.withPet,
      p.withPet == 1 and "" or "s"), 0.7, 0.7, 0.7)
  end
  GameTooltip:AddLine(" ")

  if p.plain then
    GameTooltip:AddDoubleLine("Interrupts", ("%d"):format(p.kicks or 0), 1, 1, 1, 1, 0.82, 0)
    GameTooltip:AddDoubleLine("Deaths", ("%d"):format(p.deaths or 0), 1, 1, 1,
      (p.deaths or 0) > 0 and 1 or 0.7, (p.deaths or 0) > 0 and 0.2 or 0.7, 0.2)
    GameTooltip:AddDoubleLine("Damage taken", ns.Short(p.taken), 1, 1, 1, 1, 0.82, 0)

    -- p.segment is nil for a harvested pull or a past session: there is no
    -- by-id drill-down in the API, and serving the Current session's spells
    -- under another segment's heading would be worse than no breakdown.
    local spells = p.segment and p.guid and ns.Meter:Spells(p.segment, p.guid, p.creatureID)
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

  local kv = ns.Meter:KickValue(p)
  if kv and kv > 0 then
    local mode = ns.Meter:KickableMode()
    local count = (mode.key == "casts" or mode.key == "spells")
    local function fmt(v) return count and tostring(v) or ns.Short(v) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("From spells proven interruptible", fmt(kv),
      1, 0.6, 0.2, 1, 0.6, 0.2)
    for i = 1, math.min(#(p.kickableBy or {}), 6) do
      local sp = p.kickableBy[i]
      local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sp.spellID))
        or tostring(sp.spellID)
      -- Each line in the same unit as the column above it, so the rows add up
      -- to the figure they are a breakdown of.
      local v = (mode.key == "casts" and sp.casts)
        or (mode.key == "spells" and 1)
        or (mode.key == "overkill" and sp.overkill)
        or sp.amount
      GameTooltip:AddDoubleLine(name, v and fmt(v) or "-", 0.8, 0.8, 0.8, 1, 0.82, 0)
    end
  end

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Interrupts pressed -- not casts missed.", 1, 0.6, 0.2)
  GameTooltip:AddLine(("last column: %s"):format(ns.Meter:KickableMode().note), 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Which casts got through is still the parser's answer.", 0.7, 0.7, 0.7)
  local learned, boot, src = ns.KickableCounts()
  GameTooltip:AddLine(("%d proven in your logs, %d from %s."):format(
    learned, boot, src or "the dungeon list"), 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Which casts got through needs WoWCombatLog.txt.", 0.7, 0.7, 0.7)
end


-- One set of columns, laid out once, used by both the header and every row.
local function layoutColumns(owner, font)
  owner.c1 = owner:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  owner.c1:SetPoint("LEFT")
  owner.c1:SetWidth(C1_W)
  owner.c1:SetJustifyH("LEFT")
  owner.c1:SetWordWrap(false)

  owner.c2 = owner:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
  owner.c2:SetPoint("LEFT", owner.c1, "RIGHT", GAP, 0)
  owner.c2:SetWidth(C2_W)
  owner.c2:SetJustifyH("RIGHT")

  owner.c3 = owner:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
  owner.c3:SetPoint("LEFT", owner.c2, "RIGHT", GAP, 0)
  owner.c3:SetWidth(C3_W)
  owner.c3:SetJustifyH("RIGHT")

  owner.c4 = owner:CreateFontString(nil, "OVERLAY", font or "GameFontDisableSmall")
  owner.c4:SetPoint("LEFT", owner.c3, "RIGHT", GAP, 0)
  owner.c4:SetWidth(C4_W)
  owner.c4:SetJustifyH("RIGHT")
  owner.c4:SetWordWrap(false)

  owner.c5 = owner:CreateFontString(nil, "OVERLAY", font or "GameFontDisableSmall")
  owner.c5:SetPoint("LEFT", owner.c4, "RIGHT", GAP, 0)
  owner.c5:SetWidth(C5_W)
  owner.c5:SetJustifyH("RIGHT")
  owner.c5:SetWordWrap(false)
  return owner
end

local function setCols(owner, a, b, c, d, e)
  owner.c1:SetText(a or "")
  owner.c2:SetText(b or "")
  owner.c3:SetText(c or "")
  owner.c4:SetText(d or "")
  owner.c5:SetText(e or "")
end

local function buildRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(WIDTH - 16, ROW_H)
  row:SetPoint("TOPLEFT", 8, -(ROWS_Y + (index - 1) * ROW_H))
  layoutColumns(row)

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
-- A party is five, but the meter lists every ACTOR: pets kick too, and each
-- resummon is its own row upstream. Six slots meant the Voidscar +10 showed
-- three players and three copies of one felhunter, and the only member who
-- actually died never made the list at all -- which is what made the panel look
-- like it was undercounting deaths.
local METER_ROWS = 10

local function rowCount(m)
  if m == "meter" then return METER_ROWS end
  return ns.db.maxRows or 12
end

-- `n` is how many rows are actually on screen. The cap is a ceiling, not a
-- shape: sizing to the ceiling leaves a five-man group sitting in a box with
-- five empty lines under it, which reads as a broken addon.
local function heightFor(m, n)
  if m == "blind" then return 22 + ROW_H * 2 + 10 end
  n = math.min(n or rowCount(m), rowCount(m))
  -- header row + rows + footer + log line
  return 22 + ROW_H + ROW_H * math.max(n, 1) + 18 + ROW_H
end

function Panel:Layout(n)
  if not frame then return end
  frame:SetSize(WIDTH, heightFor(mode(), n))
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

  -- Clearing used to live only at the bottom of the segment dropdown, and only
  -- when there was something to take -- so on the common case of an empty
  -- history there was nothing on screen to find, and the honest answer to "how
  -- do I clear this" was a slash command. It is a button now: always visible,
  -- always opens, and the scopes that would take nothing are listed greyed
  -- rather than omitted.
  frame.clear = CreateFrame("Button", nil, frame)
  frame.clear:SetPoint("TOPLEFT", 62, -5)
  frame.clear:SetSize(40, ROW_H)
  frame.clear.text = frame.clear:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.clear.text:SetPoint("LEFT")
  frame.clear.text:SetText("clear")
  frame.clear:SetScript("OnClick", function() Panel:Clear() end)
  frame.clear:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.5, 0.5)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Clear", 1, 1, 1)
    GameTooltip:AddLine("Throw away harvested pulls, stored keys, or the", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("game's live meter. Each asks twice before taking.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  frame.clear:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.5, 0.5, 0.5)
    GameTooltip:Hide()
  end)

  -- The last column answered exactly one question -- how much damage from
  -- proven-interruptible spells -- and the heading said "kickable", which reads
  -- like a count. It is a picker now, in the title bar rather than behind a
  -- slash command, for the same reason clearing moved there.
  frame.cols = CreateFrame("Button", nil, frame)
  frame.cols:SetPoint("TOPLEFT", 102, -5)
  frame.cols:SetSize(34, ROW_H)
  frame.cols.text = frame.cols:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.cols.text:SetPoint("LEFT")
  frame.cols.text:SetText("cols")
  frame.cols:SetScript("OnClick", function() Panel:Cols() end)
  frame.cols:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.82, 0)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Column", 1, 1, 1)
    GameTooltip:AddLine("Choose what the last column shows: kickable damage,", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("casts, how many spells, overkill -- or hide it.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  frame.cols:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.5, 0.5, 0.5)
    GameTooltip:Hide()
  end)

  -- The audit is taken automatically now, but it still has to LEAVE the client
  -- to be any use, and a screenshot of the chat frame cuts off the ends of the
  -- lines that matter -- field names. So it gets a button and a box you can
  -- select out of, rather than only a command whose output you have to photograph.
  frame.audit = CreateFrame("Button", nil, frame)
  frame.audit:SetPoint("TOPLEFT", 136, -5)
  frame.audit:SetSize(38, ROW_H)
  frame.audit.text = frame.audit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.audit.text:SetPoint("LEFT")
  frame.audit.text:SetText("audit")
  frame.audit:SetScript("OnClick", function() Panel:AuditBox() end)
  frame.audit:SetScript("OnEnter", function(self)
    self.text:SetTextColor(0.4, 0.8, 1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Audit", 1, 1, 1)
    GameTooltip:AddLine("What C_DamageMeter returns on this client -- the one", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("thing a combat log cannot contain. Taken by itself", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("when a key completes; this copies it out.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  frame.audit:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.5, 0.5, 0.5)
    GameTooltip:Hide()
  end)

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
  frame.seg:SetScript("OnClick", function(self, button)
    -- Right-click cycles, left-click opens the list. Cycling is the muscle
    -- memory from when there were only two segments; the list is the only way
    -- to reach a specific past pull.
    if button == "RightButton" then Panel:Segment() else Panel:Menu() end
  end)
  frame.seg:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  frame.seg:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Segment", 1, 1, 1)
    GameTooltip:AddLine("Click for the list: the live view, the whole key, and", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("every pull harvested so far. Right-click cycles.", 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Inside a key only one segment is usually harvestable:", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("the amounts stay secret until you leave the dungeon.", 0.6, 0.6, 0.6)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("To throw a report away, use the panel's clear button --", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("it is not in this list, so a mis-click cannot take one.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  frame.seg:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Kept as an alias: Logging and the tests reach for frame.stat.
  frame.stat = frame.seg.text

  -- A header laid out with the SAME column geometry as a row, on its own line.
  -- It used to be one right-justified string anchored at the row-one y, which
  -- put "kicks died taken" directly on top of the first player.
  frame.head = CreateFrame("Frame", nil, frame)
  frame.head:SetPoint("TOPLEFT", 8, -HEAD_Y)
  frame.head:SetSize(WIDTH - 16, ROW_H)
  layoutColumns(frame.head, "GameFontDisableSmall")

  -- The headings are buttons: click a column to sort by it, click it again to
  -- flip the direction. One button per column rather than one for the strip, so
  -- the hit area is exactly the column it labels.
  frame.head.btn = {}
  for i, col in ipairs((ns.Meter and ns.Meter.COLUMNS) or {}) do
    local b = CreateFrame("Button", nil, frame.head)
    b:SetAllPoints(frame.head["c" .. i])
    b.sortKey = col.key
    b:SetScript("OnClick", function(self) Panel:SortBy(self.sortKey) end)
    b:SetScript("OnEnter", function(self)
      local by, desc = ns.Meter:SortSpec()
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Sort by " .. col.label, 1, 1, 1)
      GameTooltip:AddLine(self.sortKey == by
        and ("click to flip to " .. (desc and "ascending" or "descending"))
        or "click to sort by this column", 0.7, 0.7, 0.7)
      if Panel.sortNote then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(Panel.sortNote, 1, 0.6, 0.2)
      end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.head.btn[col.key] = b
  end
  Panel.headButtons = frame.head.btn

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
  -- Exposed so a test can prove the header and row one are not on the same line.
  Panel.rows = rows

  self:Layout()
  return frame
end

-- -------------------------------------------------------- the segment dropdown
-- Built here rather than with MenuUtil: the entries carry our own labels and
-- have to survive a client where a label's underlying value is secret, and a
-- list of five buttons in the panel's own style is less to go wrong than a
-- native menu whose shape changes between builds.
local MENU_W = 210

local function segColor(kind)
  if kind == "live" then return "|cff808080" end
  if kind == "run" then return "|cffffd200" end
  if kind == "pull" then return "|cff80b0ff" end
  -- A key from an earlier login reads differently from one from this one, so a
  -- stored report is never mistaken for the run in progress.
  if kind == "saved" then return "|cff90c080" end
  if kind == "savedpull" then return "|cff80a070" end
  return "|cffb0b0b0"
end

local function buildMenu()
  -- A file local, not a field on the frame: a stubbed frame answers any unknown
  -- key with a function, so `frame.menu` is never nil and the nil check would
  -- never fire.
  if menu then return menu end
  local m = CreateFrame("Frame", "UnkickedSegmentMenu", frame, "BackdropTemplate")
  m:SetPoint("TOPRIGHT", frame.seg, "BOTTOMRIGHT", 0, -2)
  m:SetFrameStrata("DIALOG")
  m:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  m:SetBackdropColor(0, 0, 0, 0.92)
  m:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
  m:EnableMouse(true)
  m.items = {}
  m:Hide()
  menu = m
  Panel.menuFrame = m
  return m
end

-- show == nil toggles.
function Panel:Menu(show)
  self:Build()
  local m = buildMenu()
  if show == nil then show = not m:IsShown() end
  if not show then m:Hide(); return m end

  -- Four dialogs, one corner. Two of them stacked is how you click the one you
  -- could not see.
  if colBox then colBox:Hide() end
  if clearBox then clearBox:Hide() end
  if auditBox then auditBox:Hide() end

  local segs = (ns.Meter and ns.Meter:Segments()) or {}
  -- Segments only. The clear actions used to be appended here, which both hid
  -- them (they appeared only when there was something to take) and put an
  -- irreversible row one pixel from the harmless act of looking at another
  -- pull. They live behind the panel's own Clear button now.
  local entries = {}
  for _, seg in ipairs(segs) do entries[#entries + 1] = seg end

  for i, e in ipairs(entries) do
    local b = m.items[i]
    if not b then
      b = CreateFrame("Button", nil, m)
      b:SetSize(MENU_W - 8, ROW_H)
      b:SetPoint("TOPLEFT", 4, -(4 + (i - 1) * ROW_H))
      b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      b.text:SetPoint("LEFT")
      b.text:SetJustifyH("LEFT")
      b.text:SetWordWrap(false)
      b:SetScript("OnClick", function(self)
        if self.segKey then Panel:Segment(self.segKey) end
        Panel:Menu(false)
      end)
      m.items[i] = b
    end
    -- `false`, never nil: a stubbed frame answers an unknown key with a
    -- function, so a nil field reads as truthy.
    b.segKey = e.key or false
    b.text:SetText(("%s%s%s|r"):format(
      e.key == ns.db.segment and "|cffffd200>|r " or "   ",
      segColor(e.kind), e.label))
    b:Show()
  end
  for i = #entries + 1, #m.items do
    m.items[i].segKey = false
    m.items[i]:Hide()
  end
  m:SetSize(MENU_W, 8 + ROW_H * math.max(#entries, 1))
  m:Show()
  return m
end

-- ------------------------------------------------------------ the clear box
-- A dialog of its own rather than rows in the segment list, for three reasons
-- the last version got wrong:
--
--   it is REACHABLE. The old entries appeared only when there was something to
--   take, so with no stored keys the panel offered no way to clear at all and
--   the honest answer was a slash command.
--   it says what each scope COSTS, next to the button that does it, instead of
--   only in the help text of a command.
--   it is not adjacent to a harmless click. Selecting a different pull and
--   destroying one were one pixel apart.
local CLEAR_W = 268

function Panel:ClearBox()
  if clearBox then return clearBox end
  local c = CreateFrame("Frame", "UnkickedClearBox", frame, "BackdropTemplate")
  c:SetPoint("TOPLEFT", frame.clear, "BOTTOMLEFT", -4, -2)
  c:SetFrameStrata("DIALOG")
  c:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  c:SetBackdropColor(0, 0, 0, 0.95)
  c:SetBackdropBorderColor(0.6, 0.25, 0.25, 1)
  c:EnableMouse(true)
  c.items = {}

  c.head = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  c.head:SetPoint("TOPLEFT", 6, -6)
  c.head:SetText("Clear what?")

  c.foot = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.foot:SetPoint("BOTTOMLEFT", 6, 6)
  c.foot:SetPoint("BOTTOMRIGHT", -6, 6)
  c.foot:SetJustifyH("LEFT")
  c.foot:SetText("A pull cannot be re-harvested: its session is gone.")

  c:Hide()
  clearBox = c
  Panel.clearFrame = c
  return c
end

-- --------------------------------------------------------- the column picker
-- Five answers to one question, and the panel can only honestly give some of
-- them on some clients -- so each is listed with whether it is actually
-- available HERE, rather than the unavailable ones being quietly omitted. That
-- omission is exactly what made clearing unfindable (R-39), and the same rule
-- applies: offer it, grey it, say why.
local COL_W = 272

-- nil when the mode works, otherwise the reason it cannot be shown.
function Panel:ModeBlocked(mode)
  if mode.key == "casts" and ns.Meter.noCastCount then
    return "this client's spell rows carry no count"
  end
  return nil
end

function Panel:ColBox()
  if colBox then return colBox end
  local c = CreateFrame("Frame", "UnkickedColBox", frame, "BackdropTemplate")
  c:SetPoint("TOPLEFT", frame.cols, "BOTTOMLEFT", -4, -2)
  c:SetFrameStrata("DIALOG")
  c:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  c:SetBackdropColor(0, 0, 0, 0.95)
  c:SetBackdropBorderColor(0.6, 0.5, 0.2, 1)
  c:EnableMouse(true)
  c.items = {}

  c.head = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  c.head:SetPoint("TOPLEFT", 6, -6)
  c.head:SetText("Last column shows")

  c.foot = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.foot:SetPoint("BOTTOMLEFT", 6, 6)
  c.foot:SetPoint("BOTTOMRIGHT", -6, 6)
  c.foot:SetJustifyH("LEFT")
  c.foot:SetWordWrap(true)
  c.foot:SetText("Missed casts are the parser's answer, not the API's.")

  c:Hide()
  colBox = c
  Panel.colFrame = c
  return c
end

function Panel:Cols(show)
  self:Build()
  local c = self:ColBox()
  if show == nil then show = not c:IsShown() end
  if not show then c:Hide(); return c end
  self:Menu(false)
  self:Clear(false)
  if auditBox then auditBox:Hide() end

  local modes = ns.Meter.KICKABLE_MODES
  local cur = ns.Meter:KickableMode()
  local ROW = ROW_H + 10
  for i, m in ipairs(modes) do
    local b = c.items[i]
    if not b then
      b = CreateFrame("Button", nil, c)
      b:SetSize(COL_W - 12, ROW)
      b:SetPoint("TOPLEFT", 6, -(6 + ROW_H + (i - 1) * ROW))
      b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      b.text:SetPoint("TOPLEFT")
      b.text:SetJustifyH("LEFT")
      b.text:SetWordWrap(false)
      b.note = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      b.note:SetPoint("TOPLEFT", 10, -ROW_H + 4)
      b.note:SetJustifyH("LEFT")
      b.note:SetWordWrap(false)
      b:SetScript("OnClick", function(self)
        -- A mode this client cannot answer is still listed, so that the player
        -- can see it exists and why it is dark -- but selecting it would leave
        -- an empty column with no explanation, so it does not select.
        if not self.mode or self.blocked then return end
        ns.Meter:SetKickableMode(self.mode)
        Panel:Cols(false)
        Panel:Refresh()
      end)
      c.items[i] = b
    end
    local blocked = Panel:ModeBlocked(m)
    b.mode = m.key
    b.blocked = blocked and true or false
    local name = (m.key == "off") and "nothing (hide it)" or m.key
    if blocked then
      b.text:SetText(("|cff606060%s|r"):format(name))
      b.note:SetText(("|cff806030%s|r"):format(blocked))
    elseif m.key == cur.key then
      b.text:SetText(("|cffffd200%s  <|r"):format(name))
      b.note:SetText(("|cff808080%s|r"):format(m.note))
    else
      b.text:SetText(name)
      b.note:SetText(("|cff606060%s|r"):format(m.note))
    end
    b:Show()
  end
  for i = #modes + 1, #c.items do
    c.items[i].mode = false
    c.items[i]:Hide()
  end
  c:SetSize(COL_W, 6 + ROW_H + ROW * #modes + ROW_H + 8)
  c:Show()
  return c
end

-- The one line under an empty column. Six causes, and only "no known
-- interruptible spell hit anyone" is a fact about the fight -- the rest are
-- facts about the API, the segment, or us, and the player should not have to
-- guess which they are looking at.
function Panel:KickableNote(kind)
  local M = ns.Meter
  local mode = M:KickableMode()
  if not mode.field then
    return "|cff808080the last column is hidden -- click |r|cffffd200cols|r|cff808080 to bring it back|r"
  end
  local learned, boot = ns.KickableCounts()
  local known = learned + boot
  if known == 0 then
    return "|cffff9933kickable: no interruptibility data -- run tools/gen-dungeon-interruptible.mjs|r"
  end
  -- A stored or harvested segment carries whatever was measured when it was
  -- taken; nothing can drill into it now, so this is not a diagnosis of the API.
  if kind ~= "live" then
    return "|cff808080" .. M.KICKABLE_WHY["stored"] .. "|r"
  end
  local why = M.kickableWhy
  if why == "no-match" then
    return ("|cff808080kickable: none of the %d known interruptible casts hit anyone|r"):format(known)
  end
  local text = why and M.KICKABLE_WHY[why]
  if not text then
    return ("|cff808080%s|r"):format(mode.note)
  end
  local bad = (why == "secret-guid" or why == "refused" or why == "no-metric")
  return ("|c%s%s: %s|r"):format(bad and "ffff9933" or "ff808080", mode.label ~= "" and mode.label or "kickable", text)
end

-- show == nil toggles. Rebuilt on every open so the counts are current and no
-- armed confirmation survives a close.
function Panel:Clear(show)
  self:Build()
  local c = self:ClearBox()
  if show == nil then show = not c:IsShown() end
  if not show then c:Hide(); return c end
  -- Never both open: the box is anchored under a button the segment list
  -- overlaps, and two stacked dialogs is how you click the wrong one.
  self:Menu(false)
  if colBox then colBox:Hide() end
  if auditBox then auditBox:Hide() end

  local scopes = (ns.Meter and ns.Meter:ClearScopes()) or {}
  local ROW = ROW_H + 10
  for i, sc in ipairs(scopes) do
    local b = c.items[i]
    if not b then
      b = CreateFrame("Button", nil, c)
      b:SetSize(CLEAR_W - 12, ROW)
      b:SetPoint("TOPLEFT", 6, -(6 + ROW_H + (i - 1) * ROW))
      b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      b.text:SetPoint("TOPLEFT")
      b.text:SetJustifyH("LEFT")
      b.text:SetWordWrap(false)
      b.note = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      b.note:SetPoint("TOPLEFT", 10, -ROW_H + 4)
      b.note:SetJustifyH("LEFT")
      b.note:SetWordWrap(false)
      b:SetScript("OnClick", function(self)
        -- Nothing to take, so nothing to confirm. Arming an empty scope would
        -- teach the confirmation is noise.
        if not self.act or self.empty then return end
        if not self.armed then
          self.armed = true
          self.text:SetText(("|cffff4040%s -- click again to confirm|r"):format(self.label))
          return
        end
        local ok, msg = ns.Meter:ClearBy(self.act)
        ns.Print("%s", msg)
        Panel:Clear(false)
        Panel:Refresh()
      end)
      c.items[i] = b
    end
    -- `false`, never nil: a stubbed frame answers an unknown key with a
    -- function, so a nil field reads as truthy.
    b.armed = false
    b.act = sc.act or false
    b.label = sc.label or ""
    b.empty = (sc.count or 0) == 0
    b.text:SetText(("%s%s|r"):format(b.empty and "|cff707070" or "|cffe08080", sc.label))
    b.note:SetText(("|cff606060%s|r")
      :format(b.empty and "nothing to clear" or (sc.note or "")))
    b:Show()
  end
  for i = #scopes + 1, #c.items do
    c.items[i].act = false
    c.items[i].armed = false
    c.items[i]:Hide()
  end
  c:SetSize(CLEAR_W, 6 + ROW_H + ROW * math.max(#scopes, 1) + ROW_H + 6)
  c:Show()
  return c
end

-- `which` is a segment key: "current", "overall", "pull:<n>" or "session:<id>".
-- With no argument it advances to the next segment in the list, which is what
-- the old two-state toggle did when the list was only ever two long.
function Panel:Segment(which)
  if which == nil then
    local segs = (ns.Meter and ns.Meter:Segments()) or {}
    local at
    for i, seg in ipairs(segs) do
      if seg.key == ns.db.segment then at = i; break end
    end
    which = (#segs > 0) and segs[((at or 1) % #segs) + 1].key or "current"
  end
  ns.db.segment = which
  self:Refresh()
  return ns.db.segment
end

-- ------------------------------------------------------------------- sorting
-- Only meter mode has value columns to sort, so the hit areas are off in the
-- other two -- an invisible button over a blank heading that silently rewrites
-- a stored preference is worse than no button.
-- ------------------------------------------------------------ the audit box
-- A read-only-ish multiline edit box, because the answer has to be PASTED. The
-- text is live in a widget rather than screenshotted: ctrl-A, ctrl-C, done.
local AUDIT_W = 420
local AUDIT_H = 260

function Panel:AuditFrame()
  if auditBox then return auditBox end
  local c = CreateFrame("Frame", "UnkickedAuditBox", frame, "BackdropTemplate")
  c:SetPoint("TOPLEFT", frame.audit, "BOTTOMLEFT", -4, -2)
  c:SetFrameStrata("DIALOG")
  c:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  c:SetBackdropColor(0, 0, 0, 0.96)
  c:SetBackdropBorderColor(0.2, 0.5, 0.7, 1)
  c:EnableMouse(true)
  c:SetSize(AUDIT_W, AUDIT_H)

  c.head = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  c.head:SetPoint("TOPLEFT", 6, -6)
  c.head:SetText("Audit")

  c.scroll = CreateFrame("ScrollFrame", "UnkickedAuditScroll", c, "UIPanelScrollFrameTemplate")
  c.scroll:SetPoint("TOPLEFT", 6, -(6 + ROW_H))
  c.scroll:SetPoint("BOTTOMRIGHT", -26, 6 + ROW_H)

  c.edit = CreateFrame("EditBox", nil, c.scroll)
  c.edit:SetMultiLine(true)
  c.edit:SetAutoFocus(false)
  c.edit:SetFontObject("GameFontHighlightSmall")
  c.edit:SetWidth(AUDIT_W - 40)
  -- Escape closes it; the text itself is never meant to be edited, but it has
  -- to stay selectable, which is why this is an EditBox and not a FontString.
  c.edit:SetScript("OnEscapePressed", function() Panel:AuditBox(false) end)
  c.scroll:SetScrollChild(c.edit)

  c.foot = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.foot:SetPoint("BOTTOMLEFT", 6, 6)
  c.foot:SetPoint("BOTTOMRIGHT", -6, 6)
  c.foot:SetJustifyH("LEFT")
  c.foot:SetWordWrap(false)

  c:Hide()
  auditBox = c
  Panel.auditFrame = c
  return c
end

-- What the box is showing, and why -- never "an audit" with no provenance. A
-- stored one from a finished key and one taken right now in town answer
-- different questions, and only the first is worth sending anywhere.
function Panel:AuditEntry()
  local stored = (ns.Meter and ns.Meter:StoredAudits()) or {}
  if stored[1] then return stored[1], "stored" end
  -- Nothing captured yet: take one now rather than showing an empty box, but
  -- say that it is this moment's client and not the key's.
  local live = ns.Meter and ns.Meter:AuditCapture("opened the box")
  if live then return live, "live" end
  return nil, nil
end

function Panel:AuditBox(show)
  self:Build()
  local c = self:AuditFrame()
  if show == nil then show = not c:IsShown() end
  if not show then c:Hide(); return c end
  self:Menu(false)
  self:Clear(false)
  self:Cols(false)

  local entry, kind = self:AuditEntry()
  if not entry then
    c.head:SetText("Audit")
    c.edit:SetText("no damage meter on this client, so there is nothing to audit.")
    c.foot:SetText("|cff808080C_DamageMeter is the only source left; see /uk why.|r")
  else
    local when = entry.at and entry.at > 0 and date and date("%H:%M", entry.at) or nil
    c.head:SetText(("Audit -- %s%s%s%s"):format(
      entry.reason or "?",
      entry.map and (", " .. entry.map) or "",
      entry.level and ("+" .. entry.level) or "",
      when and (", " .. when) or ""))
    c.edit:SetText(ns.Meter:AuditText(entry) or "")
    c.foot:SetText(("|cff808080%s -- restrictions %s. ctrl-A, ctrl-C to copy.|r"):format(
      kind == "stored" and "kept from the last key" or "taken just now",
      entry.restricted and "active" or "lifted"))
  end
  c.edit:HighlightText(0, 0)
  c:Show()
  return c
end

local function headButtons(show)
  if not (frame and frame.head and frame.head.btn) then return end
  for _, b in pairs(frame.head.btn) do
    if show then b:Show() else b:Hide() end
  end
end

-- Inactive columns keep the colour they always had, so the strip does not
-- suddenly read as five live controls.
local HEAD_COLOR = { kickable = "|cffff9933" }

local function headLabel(key, by, desc, applied)
  local col = ns.Meter and ns.Meter:Column(key)
  local label = (col and col.label) or key
  -- The last column answers whichever question the picker last set, so its
  -- heading has to say which one. A heading that reads "kickable" over a count
  -- of spells is the same class of fault as an arrow over rows that were never
  -- sorted.
  if key == "kickable" and ns.Meter then
    local mode = ns.Meter:KickableMode()
    label = mode.label ~= "" and mode.label or "kickable"
    if mode.key == "casts" then label = "misses"
    elseif mode.key == "spells" then label = "spells" end
  end
  if key ~= by then
    return ("%s%s|r"):format(HEAD_COLOR[key] or "|cff808080", label)
  end
  -- A requested sort that could not be applied gets a dash, not an arrow: the
  -- arrow is a claim about the order of the rows below it.
  local mark = applied and (desc and "v" or "^") or "-"
  return ("|cffffd200%s%s|r"):format(label, mark)
end

-- Click the same column again to flip the direction; a different one starts
-- descending, which is what "show me the most" means for every column here.
function Panel:SortBy(col)
  if not (ns.Meter and ns.Meter:Column(col)) then return nil end
  local by, desc = ns.Meter:SortSpec()
  if by == col then desc = not desc else by, desc = col, true end
  ns.db.sort = { by = by, desc = desc }
  self:Refresh()
  return by, desc
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

  headButtons(false)
  setCols(frame.head)
  for i = 1, rowCount("feed") do
    local row = rows[i]
    local rec = recs[i]
    if rec and rec.damage >= (ns.db.minDamage or 0) then
      shown = shown + 1
      row.rec, row.player = rec, nil

      local mark = ""
      if next(rec.deaths) then mark = "|cffff2020*|r "
      elseif rec.interruptible == nil then mark = "|cffff9933?|r " end
      local who
      local k = rec.kicks
      if #k.ready > 0 then who = namesOf(k.ready, 3)
      elseif #k.cc > 0 then who = "|cff80b0ffcc|r"
      elseif #k.unknown > 0 then who = "|cffff9933?|r"
      else who = "|cff808080all down|r" end

      row.c5:SetJustifyH("LEFT")
      setCols(row, mark .. rec.spellName,
        ("|cffffd200%s|r"):format(ns.Short(rec.damage)), "", "", who)
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
--
-- Plainness is decided PER VALUE, not once for the whole table. A real +10
-- (Voidscar Arena, 2026-10-01) returned readable amounts beside an unreadable
-- name, and a single global flag made every number in the panel render as a raw
-- 77011323 instead of 77.0m. A name this code cannot read says nothing about
-- whether a number beside it can be.
local function setAmount(fs, value, fmt)
  if value == nil then fs:SetText("") return end
  if ns.IsSecret(value) then fs:SetText(value) else fs:SetText(fmt(value)) end
end

local function refreshMeter()
  -- The segment is whatever the dropdown last selected. A key stored in
  -- SavedVariables can name a pull from a key that has since been reset, so a
  -- view that does not resolve falls back to the live one and says it did --
  -- an empty table under a stale heading is the worst of the three outcomes.
  local key = ns.db.segment or "current"
  local data, plain, label, kind = ns.Meter:View(key)
  local stale
  if data == nil then
    stale = key
    key, ns.db.segment = "current", "current"
    data, plain, label, kind = ns.Meter:View(key)
  end
  data = data or {}

  frame.seg.text:SetText(("%s%s|r |cff808080v|r"):format(segColor(kind), label))

  -- Sorted here, not in Meter:View: the order is a property of this panel's
  -- headings, and the same rows are handed unchanged to the chat report.
  local by, desc = ns.Meter:SortSpec()
  local sorted, applied, note = ns.Meter:Sort(data, by, desc)
  data = sorted
  Panel.sortNote = (not applied) and note or nil
  Panel.sortedBy, Panel.sortedDesc = by, desc
  headButtons(true)
  setCols(frame.head,
    headLabel("name", by, desc, applied),
    headLabel("kicks", by, desc, applied),
    headLabel("died", by, desc, applied),
    headLabel("taken", by, desc, applied),
    headLabel("kickable", by, desc, applied))

  -- Only the two live-by-type segments can drill down per spell; a harvested
  -- pull and a past session cannot (no by-id variant of the call exists).
  local drill = (kind == "live" and "current") or (kind == "run" and "overall") or nil

  local shown, kickableBlank = 0, true
  for i = 1, rowCount("meter") do
    local row, p = rows[i], data[i]
    if p then
      shown = shown + 1
      p.plain, p.segment = plain, drill
      row.rec, row.player = nil, p
      row.c1:SetText(("|c%s%s|r%s"):format(ns.ClassColor(p.class),
        p.name or "?", p.isYou and " |cff808080(you)|r" or ""))
      setAmount(row.c2, p.kicks, function(v) return ("|cffffd200%d|r"):format(v) end)
      setAmount(row.c3, p.deaths, function(v)
        return v > 0 and ("|cffff2020%d|r"):format(v) or "|cff5050500|r"
      end)
      setAmount(row.c4, p.taken, function(v) return "|cff808080" .. ns.Short(v) .. "|r" end)
      -- Only ever a plain number: it is computed from the per-spell drill-down,
      -- which cannot run while the values are secret. Blank during a pull.
      row.c5:SetJustifyH("RIGHT")
      local kv = ns.Meter:KickValue(p)
      local kmode = ns.Meter:KickableMode()
      -- A count is a count: shortening 12 to "12" is fine, but running a count
      -- through the damage formatter would print "12" for twelve and "1.2k" for
      -- twelve hundred spells, which no column of spells will ever reach.
      local shown = kv and ((kmode.key == "casts" or kmode.key == "spells")
        and tostring(kv) or ns.Short(kv)) or nil
      row.c5:SetText(shown and ("|cffff9933%s|r"):format(shown) or "")
      if kv then kickableBlank = false end
      row:Show()
    else
      row.rec, row.player = nil, nil
      row:Hide()
    end
  end
  hideRows(rowCount("meter") + 1)
  Panel:Layout(shown)

  -- Said on every refresh, not once in a readme. This panel counts interrupts
  -- PRESSED; the thing the addon is named after -- a cast nobody stopped -- is
  -- not in this API and never will be, so pretending by omission is the one
  -- failure mode worth designing against.
  if stale then
    frame.footer:SetText(("|cffff9933%s is gone -- showing the live segment|r"):format(stale))
  elseif not applied then
    -- Say which order the rows are ACTUALLY in, rather than leaving the heading
    -- to imply one that was never applied.
    frame.footer:SetText(("|cffff9933sort by %s: %s|r"):format(by, note or "not available"))
  elseif kind == "saved" or kind == "savedpull" then
    frame.footer:SetText("|cff808080a key from an earlier session -- stored, not live|r")
  elseif kind == "pull" or kind == "session" then
    frame.footer:SetText("|cff808080a finished segment -- click the heading for the list|r")
  elseif shown == 0 then
    frame.footer:SetText("|cff808080no combat yet -- kicks pressed appear here per pull|r")
  elseif not plain then
    frame.footer:SetText("|cff808080live: kicks pressed. kickable damage lands when the pull ends|r")
  elseif kind == "live" and not ns.Meter.run then
    frame.footer:SetText("|cff808080not in a key -- per-pull totals start at CHALLENGE_MODE_START|r")
  elseif kickableBlank then
    frame.footer:SetText(Panel:KickableNote(kind))
  else
    local m = ns.Meter:KickableMode()
    frame.footer:SetText(("|cff808080%s|r"):format(m.note))
  end
end

-- ----------------------------------------------------------------- blind mode
local function refreshBlind()
  hideRows(1)
  headButtons(false)
  frame.seg.text:SetText("")
  setCols(frame.head)
  frame.footer:SetText("|cffff2020no feed on this client|r -- |cffffd200/uk why|r")
end

function Panel:Refresh()
  if not frame then return end
  local m = mode()
  self:Layout()
  -- The dropdown only ever lists meter segments, so it has no business being on
  -- screen in the other two modes.
  if m ~= "meter" and menu then menu:Hide() end

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
  if show then frame:Show() self:Refresh() else
    if menu then menu:Hide() end
    frame:Hide()
  end
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
