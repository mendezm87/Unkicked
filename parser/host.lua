-- Unkicked :: parser/host.lua
--
-- Loads the addon's Core modules outside WoW, so the offline parser runs the
-- SAME model the in-game version ran and the existing test suite covers.
--
-- Two things make that possible:
--   * every Core module guards its UI calls with `if ns.Panel then`, so a
--     headless load simply has no panel;
--   * CastTracker exposes Cast:Ingest() as a named entry point, so the feed can
--     come from a file instead of from an event the client no longer delivers.
--
-- The clock is the important part. In game GetTime() is the client's uptime; here
-- it is the timestamp of the log line currently being processed, which the caller
-- sets before each Ingest. Everything downstream (cooldowns, damage windows,
-- death windows) therefore measures log time, not wall time -- so a log replayed
-- days later produces identical numbers to one tailed live.

local host = {}

host.root = nil   -- set by init(), the addon directory holding Core/ and Data/

-- ------------------------------------------------------------------ the clock
host.clock = 0
function host.setClock(t) host.clock = t end

-- --------------------------------------------------------- client stand-ins
local function installGlobals()
  GetTime = function() return host.clock end

  -- LuaJIT ships `bit`; plain Lua does not, and `&` is a syntax error under 5.1.
  if not bit then
    bit = { band = function(a, b)
      local r, m = 0, 1
      while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + m end
        a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
      end
      return r
    end }
  end

  wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  unpack = unpack or table.unpack

  COMBATLOG_OBJECT_AFFILIATION_MINE    = 0x00000001
  COMBATLOG_OBJECT_AFFILIATION_PARTY   = 0x00000002
  COMBATLOG_OBJECT_AFFILIATION_RAID    = 0x00000004
  COMBATLOG_OBJECT_TYPE_PLAYER         = 0x00000400
  COMBATLOG_OBJECT_REACTION_FRIENDLY   = 0x00000010
  COMBATLOG_OBJECT_REACTION_HOSTILE    = 0x00000040

  RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { colorStr = "ffffffff" } end })
  C_AddOns = { GetAddOnMetadata = function() return "offline" end }
  GetBuildInfo = function() return "12.1.0", "69933", nil, 120100 end
  UIParent = nil

  -- No units exist offline: the roster comes from the log itself. These exist so
  -- Kick:Rebuild() is a harmless no-op rather than an error.
  UnitGUID = function() return nil end
  UnitName = function() return nil end
  UnitClass = function() return nil end
  UnitIsDeadOrGhost = function() return false end
  GetNumGroupMembers = function() return 0 end
  IsInRaid = function() return false end
  IsPlayerSpell = function() return false end
  UnitCastingInfo = function() return nil end
  UnitChannelInfo = function() return nil end
  issecretvalue = function() return false end   -- nothing is secret in a text file
  C_RestrictedActions = nil

  -- One frame, no-op. Init.lua creates exactly one and hangs events off it; we
  -- never fire them, because the parser drives the model directly.
  local function noopFrame()
    local f = {}
    local noop = function() return f end
    return setmetatable(f, { __index = function() return noop end })
  end
  CreateFrame = noopFrame
  print = print
end

-- --------------------------------------------------------------------- loader
local ORDER = {
  "Data/InterruptData.lua",
  "Data/CCData.lua",
  "Core/Init.lua",
  "Core/Nameplates.lua",
  "Core/KickTracker.lua",
  "Core/CastTracker.lua",
}

-- `root` is the addon directory (the one holding Core/ and Data/).
function host.init(root)
  host.root = root
  installGlobals()

  local ns = {}
  host.ns = ns
  for _, rel in ipairs(ORDER) do
    local path = root .. "/" .. rel
    local chunk, err = loadfile(path)
    if not chunk then error(("cannot load %s: %s"):format(rel, err), 0) end
    chunk("Unkicked", ns)
  end

  -- ADDON_LOADED never fires, so settings are applied here. Defaults live in
  -- Init.lua; these are the offline-specific overrides.
  ns.db = {
    enabled = true,
    showPanel = false,
    announce = false,
    minDamage = 0,
    onlyInterruptible = false,  -- offline we report unknowns and say so, R-15
    includeUnknown = true,
    maxRows = 100,              -- a pull's worth, not a panel's worth
  }

  -- There are no nameplates in a text file. The log carries no interruptible
  -- flag either, so interruptibility is answered by learned knowledge or not at
  -- all; the parser replaces this with its own resolver.
  ns.Nameplates.Interruptible = function() return nil end

  return ns
end

return host
