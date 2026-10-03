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

local frame, rows, menu

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

  if p.kickable and p.kickable > 0 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("From spells proven interruptible", ns.Short(p.kickable),
      1, 0.6, 0.2, 1, 0.6, 0.2)
    for i = 1, math.min(#(p.kickableBy or {}), 6) do
      local sp = p.kickableBy[i]
      local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sp.spellID))
        or tostring(sp.spellID)
      GameTooltip:AddDoubleLine(name, ns.Short(sp.amount), 0.8, 0.8, 0.8, 1, 0.82, 0)
    end
  end

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Interrupts pressed -- not casts missed.", 1, 0.6, 0.2)
  GameTooltip:AddLine("\"kickable\" is damage from spells known to be stoppable", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("-- a cost, not a count of missed casts.", 0.7, 0.7, 0.7)
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

  local segs = (ns.Meter and ns.Meter:Segments()) or {}
  for i, seg in ipairs(segs) do
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
    b.segKey = seg.key
    b.text:SetText(("%s%s%s|r"):format(
      seg.key == ns.db.segment and "|cffffd200>|r " or "   ",
      segColor(seg.kind), seg.label))
    b:Show()
  end
  for i = #segs + 1, #m.items do
    m.items[i].segKey = nil
    m.items[i]:Hide()
  end
  m:SetSize(MENU_W, 8 + ROW_H * math.max(#segs, 1))
  m:Show()
  return m
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
      row.c5:SetText(p.kickable and ("|cffff9933%s|r"):format(ns.Short(p.kickable)) or "")
      if p.kickable then kickableBlank = false end
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
    -- The column is empty for EVERY row, so say which of the two reasons it is
    -- rather than letting a blank column read as "nothing was kickable". A
    -- refused drill-down is ours to report; an empty spell list is the data
    -- file's, and only one of those is worth the player doing anything about.
    local learned, boot = ns.KickableCounts()
    frame.footer:SetText(ns.Meter.secretGuidRefusals > 0
      and "|cffff9933kickable: the API will not name a player's spells (guid is secret)|r"
      or (learned + boot) == 0
      and "|cffff9933kickable: no interruptibility data -- run tools/gen-dungeon-interruptible.mjs|r"
      or ("|cff808080kickable: none of the %d known interruptible casts hit anyone|r")
         :format(learned + boot))
  else
    frame.footer:SetText("|cff808080kickable = dmg from proven-interruptible spells, not a cast count|r")
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
