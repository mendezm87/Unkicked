-- Unkicked :: Nameplates.lua
--
-- The combat log does NOT carry an interruptible flag. The only place that
-- information exists is UnitCastingInfo/UnitChannelInfo, which needs a live unit
-- token -- and the only unit tokens you get for arbitrary enemies are nameplates.
--
-- So: keep a GUID -> nameplate token map, and the moment a nameplate unit starts
-- casting, snapshot notInterruptible. The combat log's SPELL_CAST_START arrives
-- for the same cast and looks the snapshot up by GUID.
--
-- Known hole: an enemy with no nameplate (out of range, behind you, nameplate cap
-- reached) produces casts we cannot classify. Those come back as nil, and the
-- caller decides whether to show them as "unknown" (REQUIREMENTS.md R-5).

local ADDON, ns = ...

local Nameplates = {}
ns.Nameplates = Nameplates

local tokenByGUID = {}
local snapshot = {}     -- guid -> { spellID, interruptible, at }

function Nameplates:TokenFor(guid)
  local token = tokenByGUID[guid]
  if token and UnitGUID(token) == guid then return token end
  tokenByGUID[guid] = nil
  return nil
end

-- Reads interruptibility for a GUID the moment it is asked, if a token exists.
local function readLive(guid)
  local token = Nameplates:TokenFor(guid)
  if not token then return nil end
  local name, _, _, _, _, _, notInterruptible = UnitCastingInfo(token)
  if not name then
    name, _, _, _, _, notInterruptible = UnitChannelInfo(token)
  end
  if ns.Plain(name) == nil then return nil end
  -- In an instance this flag is a secret value: we may hold it but never test
  -- it. An untestable flag is the same as not knowing, so say so.
  if ns.IsSecret(notInterruptible) then return nil end
  return not notInterruptible
end

-- true = interruptible, false = immune, nil = could not tell.
function Nameplates:Interruptible(guid, spellID)
  local snap = snapshot[guid]
  -- Comparing secret spellIDs is forbidden; only match when both are plain.
  spellID = ns.Plain(spellID)
  if snap and spellID and snap.spellID == spellID then return snap.interruptible end
  local live = readLive(guid)
  if live ~= nil then return live end
  if snap and GetTime() - snap.at < 1 then return snap.interruptible end
  return nil
end

ns.On("NAME_PLATE_UNIT_ADDED", function(unit)
  local guid = UnitGUID(unit)
  if guid then
    tokenByGUID[guid] = unit
    -- The nameplate may appear mid-cast; grab what we can right now.
    local ok = readLive(guid)
    if ok ~= nil then
      local _, _, _, _, _, _, _, _, spellID = UnitCastingInfo(unit)
      snapshot[guid] = { spellID = ns.Plain(spellID), interruptible = ok, at = GetTime() }
    end
  end
end)

ns.On("NAME_PLATE_UNIT_REMOVED", function(unit)
  local guid = UnitGUID(unit)
  if guid then tokenByGUID[guid] = nil end
end)

local function onCastStart(unit)
  if not unit or not unit:find("nameplate", 1, true) then return end
  local guid = UnitGUID(unit)
  if not guid then return end
  tokenByGUID[guid] = unit

  local name, _, _, _, _, _, notInterruptible, _, spellID = UnitCastingInfo(unit)
  if not name then
    local cName, _, _, _, _, cNotInterruptible, cSpellID = UnitChannelInfo(unit)
    name, notInterruptible, spellID = cName, cNotInterruptible, cSpellID
  end
  if ns.Plain(name) == nil then return end

  -- nil, not false, when the flag was secret: "could not tell" is the honest
  -- answer and the panel renders it as unknown rather than as interruptible.
  -- Note this cannot be written as `cond and nil or x` -- in Lua that always
  -- falls through to x, which would silently call every cast interruptible.
  local interruptible
  if not ns.IsSecret(notInterruptible) then
    interruptible = not notInterruptible
  end

  snapshot[guid] = {
    spellID = ns.Plain(spellID),
    interruptible = interruptible,
    at = GetTime(),
  }
end

ns.On("UNIT_SPELLCAST_START", onCastStart)
ns.On("UNIT_SPELLCAST_CHANNEL_START", onCastStart)
-- Talents and auras can flip a cast's interruptibility mid-cast; re-read it.
ns.On("UNIT_SPELLCAST_INTERRUPTIBLE", onCastStart)
ns.On("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", onCastStart)

ns.On("PLAYER_REGEN_ENABLED", function()
  wipe(snapshot)
end)
