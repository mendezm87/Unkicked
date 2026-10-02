-- Unkicked :: parser/logline.lua
--
-- WoWCombatLog.txt -> the field order Cast:Ingest() expects.
--
-- A line looks like:
--   9/30/2026 21:43:01.123-7  SPELL_CAST_SUCCESS,Player-1-ABC,"Rek-Illidan",0x511,0x0,
--   Creature-0-...,"Tideburn Mystic",0xa48,0x0,1766,"Kick",1
--
-- Two details that will bite anyone reading this later:
--
--  * ADVANCED COMBAT LOGGING inserts a block of unit fields between the spell
--    params and the suffix params, so the damage amount is NOT at a fixed offset
--    across logs. Counting those fields by hand is how this went wrong once
--    already: a count of 17 landed on `facing`, which is numeric, so the amount
--    check passed and every damage event silently scored a heading in radians.
--    The block is now SELF-LOCATING -- see M.advancedSuffix -- and the count
--    below is only a fallback.
--
--  * COMBATANT_INFO nests parens and brackets, so splitting on commas requires
--    tracking depth as well as quotes.

local M = {}

-- Advanced-logging unit fields, as actually written by retail build 12.1.0
-- (COMBAT_LOG_VERSION 22), verified against a real WoWCombatLog.txt:
--   infoGUID, ownerGUID, currentHP, maxHP, attackPower, spellPower, armor,
--   absorb, powerType, currentPower, maxPower, powerCost, <2 unnamed>,
--   positionX, positionY, uiMapID, facing, level
-- That is 19, not the 17 the layout is usually documented as. Treat this as a
-- fallback only; M.advancedSuffix finds the real boundary.
M.ADVANCED_FIELDS = 19

-- The block always ENDS with positionX, positionY, uiMapID, facing, level.
-- positionX/Y and facing carry a decimal point; uiMapID and level never do, and
-- nothing earlier in the block is fractional. Anchoring on that five-field shape
-- means a future patch inserting another unit field cannot shift the amount.
local function isFrac(v) return type(v) == "string" and v:match("^%-?%d+%.%d+$") ~= nil end
local function isInt(v)  return type(v) == "string" and v:match("^%-?%d+$") ~= nil end

-- Returns the index of the first suffix field, or nil if the shape is not found.
function M.advancedSuffix(f, from)
  for i = from, math.min(from + M.ADVANCED_FIELDS + 4, #f) do
    if isFrac(f[i]) and isFrac(f[i + 1]) and isInt(f[i + 2])
       and isFrac(f[i + 3]) and isInt(f[i + 4]) then
      return i + 5
    end
  end
  return nil
end

-- ------------------------------------------------------------------ splitting
-- Returns an array of fields. Quotes are stripped; bracketed groups are kept
-- whole, with their brackets, so COMBATANT_INFO can be parsed separately.
function M.split(s)
  local out, buf, i, n = {}, {}, 1, #s
  local depth, quoted = 0, false
  while i <= n do
    local c = s:sub(i, i)
    if quoted then
      if c == '"' then quoted = false else buf[#buf + 1] = c end
    elseif c == '"' then
      quoted = true
    elseif c == "(" or c == "[" then
      depth = depth + 1; buf[#buf + 1] = c
    elseif c == ")" or c == "]" then
      depth = depth - 1; buf[#buf + 1] = c
    elseif c == "," and depth == 0 then
      out[#out + 1] = table.concat(buf); buf = {}
    else
      buf[#buf + 1] = c
    end
    i = i + 1
  end
  out[#out + 1] = table.concat(buf)
  return out
end

-- ------------------------------------------------------------------ timestamps
-- Returns seconds (float) and the remainder of the line, or nil if the line has
-- no timestamp (blank lines, and the odd truncated tail of a live log).
local DATE = "^(%d+)/(%d+)/(%d+)%s+(%d+):(%d+):(%d+)%.(%d+)"

function M.timestamp(line)
  local mo, d, y, h, mi, s, frac = line:match(DATE)
  if not mo then return nil end
  local rest = line:match("^[^%s]+%s+[^%s]+%s+(.*)$")
  if not rest then return nil end
  -- Years are 4-digit in retail logs; a 2-digit year would be a Classic log.
  y = tonumber(y)
  if y < 100 then y = y + 2000 end
  local t = os.time({
    year = y, month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false,
  })
  if not t then return nil end
  return t + tonumber("0." .. frac), rest
end

-- --------------------------------------------------------------- field layout
-- Base params present on every combat-log subevent, after the subevent name:
--   srcGUID, srcName, srcFlags, srcRaidFlags, dstGUID, dstName, dstFlags, dstRaidFlags
local BASE = 8

-- How many spell params a subevent carries before its suffix, and whether the
-- advanced block sits between them.
local SHAPE = {
  SPELL_CAST_START      = { spell = 3, advanced = false },
  SPELL_CAST_SUCCESS    = { spell = 3, advanced = true  },
  SPELL_CAST_FAILED     = { spell = 3, advanced = false },
  SPELL_INTERRUPT       = { spell = 3, advanced = false },
  SPELL_DAMAGE          = { spell = 3, advanced = true  },
  SPELL_PERIODIC_DAMAGE = { spell = 3, advanced = true  },
  SPELL_ABSORBED        = { spell = 3, advanced = false },
  SPELL_AURA_APPLIED    = { spell = 3, advanced = false },
  SPELL_AURA_REFRESH    = { spell = 3, advanced = false },
  SPELL_AURA_REMOVED    = { spell = 3, advanced = false },
  UNIT_DIED             = { spell = 0, advanced = true  },
  SPELL_SUMMON          = { spell = 3, advanced = false },
}
M.SHAPE = SHAPE

-- ------------------------------------------------------------------ pet owners
-- The advanced block opens with infoGUID, ownerGUID. For a pet's line that second
-- field names the player who owns it, which is how a felhunter's Spell Lock is
-- credited to the warlock without having to have seen the summon.
--
-- SELF-VALIDATING: the candidate is only accepted when the block's infoGUID is the
-- line's own source and the owner is a Player-. UNIT_DIED is written without the
-- block in practice despite the shape table, so guessing an offset there would
-- otherwise read a flag field as a GUID.
function M.ownerOf(f, adv)
  if not adv then return nil end
  local event, src = f[1], f[2]
  local shape = SHAPE[event]
  if not shape or not shape.advanced then return nil end
  if type(src) ~= "string" or src:find("^Player%-") or src == "0000000000000000" then return nil end
  local at = 1 + BASE + 1 + shape.spell
  if f[at] ~= src then return nil end
  local owner = f[at + 1]
  if type(owner) ~= "string" or not owner:find("^Player%-") then return nil end
  return owner
end

local function flags(v)
  return tonumber(v) or tonumber((v or ""):match("0x(%x+)") or "", 16) or 0
end

-- Turns one split line into the argument list Cast:Ingest() takes, i.e. the
-- in-game CLEU order with the advanced block removed:
--   ts, event, srcGUID, srcName, srcFlags, dstGUID, dstName, <spell params>, <suffix>
--
-- `adv` says whether the log was written with advanced logging on. Returns nil
-- for subevents the model does not handle, so callers can skip cheaply.
function M.normalize(ts, f, adv)
  local event = f[1]
  local shape = SHAPE[event]
  if not shape then return nil end

  local srcGUID, srcName, srcFlags = f[2], f[3], flags(f[4])
  local dstGUID, dstName = f[6], f[7]

  -- A no-source event is written with the null GUID and the LITERAL string
  -- "nil" as its name, so reports that fall back on `name or "?"` print the word
  -- nil as if a mob were called that. Seen on every Unstable Singularity in the
  -- Voidscar +10. Nil means nil.
  if srcName == "nil" and srcGUID == "0000000000000000" then srcName = nil end
  if dstName == "nil" and dstGUID == "0000000000000000" then dstName = nil end

  -- Positions are explicit because the suffix slots can legitimately be nil, and
  -- a nil hole makes `#args` meaningless. args.n is the real length.
  local args = { ts, event, srcGUID, srcName, srcFlags, dstGUID, dstName, n = 7 }
  local at = 1 + BASE + 1                 -- first spell param
  for i = 0, shape.spell - 1 do
    local v = f[at + i]
    args[8 + i] = tonumber(v) or v
  end
  args.n = 7 + shape.spell

  local suffix = at + shape.spell
  if adv and shape.advanced then
    suffix = M.advancedSuffix(f, suffix) or (suffix + M.ADVANCED_FIELDS)
  end

  if event == "SPELL_DAMAGE" or event == "SPELL_PERIODIC_DAMAGE" then
    -- amount is the first suffix field. Damage amounts are always whole numbers,
    -- so a fractional value means the advanced block was mis-measured and we are
    -- looking at a coordinate or a heading -- reject rather than score it.
    local amount = tonumber(f[suffix])
    if not amount then return nil, "damage amount not numeric" end
    if amount % 1 ~= 0 then return nil, "damage amount fractional -- advanced offset wrong" end
    args[11] = amount                        -- handler reads it as the 4th spell slot
    args.n = 11
  elseif event == "SPELL_INTERRUPT" then
    -- suffix: extraSpellID, extraSpellName, extraSchool.
    args[11] = tonumber(f[suffix])            -- extraSpellID: the cast that was stopped
    args.n = 11
  end

  return args
end

-- The header line: COMBAT_LOG_VERSION,21,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,...
function M.header(f)
  if f[1] ~= "COMBAT_LOG_VERSION" then return nil end
  local h = { version = tonumber(f[2]) }
  for i = 3, #f - 1, 2 do
    if f[i] == "ADVANCED_LOG_ENABLED" then h.advanced = f[i + 1] == "1" end
    if f[i] == "BUILD_VERSION" then h.build = f[i + 1] end
  end
  return h
end

-- COMBATANT_INFO: the only place a log states a player's spec and the talent
-- entries they actually chose. Field layout drifts between patches as stats are
-- added, so rather than counting stats we anchor on the first bracketed group
-- (the talent list) -- currentSpecID is the field immediately before it.
function M.combatantInfo(f)
  local guid = f[2]
  if not guid or guid == "" then return nil end
  local groupAt
  for i = 3, #f do
    local c = f[i]:sub(1, 1)
    if c == "(" or c == "[" then groupAt = i break end
  end
  if not groupAt then return nil end
  local specID = tonumber(f[groupAt - 1])
  local entries = {}
  -- Talent triples are (traitNodeID, traitNodeEntryID, rank); we want the middle.
  for a, b, c in f[groupAt]:gmatch("%((%d+),(%d+),(%d+)%)") do
    entries[#entries + 1] = tonumber(b)
  end
  return { guid = guid, specID = specID, entries = entries }
end

return M
