-- Unkicked :: tests/wow_stub.lua
--
-- Just enough of the WoW client to load the Core files outside the game and
-- replay a synthetic combat log at them. The UI is not stubbed; every module
-- guards its Panel calls with `if ns.Panel then`, so headless runs skip it.

local stub = {}

-- ----------------------------------------------------------------- the clock
local now = 1000
function stub.now() return now end
function stub.advance(s) now = now + s end
function stub.setTime(t) now = t end
GetTime = function() return now end

-- --------------------------------------------------------------- bit / utils
-- LuaJIT ships `bit`; plain Lua does not, and `&` is a syntax error under 5.1,
-- so the fallback is arithmetic rather than an operator.
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
COMBATLOG_OBJECT_REACTION_HOSTILE = 0x00000040
COMBATLOG_OBJECT_REACTION_FRIENDLY = 0x00000010
RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { colorStr = "ffffffff" } end })
C_AddOns = { GetAddOnMetadata = function() return "0.1.0-test" end }
GetBuildInfo = function() return "12.1.0", "69933", nil, 120100 end
UIParent = {}

-- ---------------------------------------------------------------- the roster
-- unit token -> { guid, name, class, spells = { [spellID]=true } }
stub.units = {}
stub.groupSize = 0

stub.nameplates = {}
UnitGUID = function(u)
  if stub.nameplates[u] then return stub.nameplates[u] end
  local x = stub.units[u]; return x and x.guid
end
UnitName = function(u) local x = stub.units[u]; return x and x.name end
UnitClass = function(u) local x = stub.units[u]; return x and x.class, x and x.class end
UnitIsDeadOrGhost = function() return false end
GetNumGroupMembers = function() return stub.groupSize end
IsInRaid = function() return false end
IsPlayerSpell = function(id) local p = stub.units.player; return p and p.spells and p.spells[id] or false end
-- ------------------------------------------------- secret values (12.0.0+)
-- The real client hands back opaque userdata that Lua may hold but not test.
-- We cannot reproduce that at the VM level, so we tag a wrapper table and make
-- issecretvalue recognise it: enough to prove the addon routes every guarded
-- read through ns.Plain instead of testing it directly.
local SECRET = {}
function stub.secret(v) return setmetatable({ v }, SECRET) end
issecretvalue = function(v)
  return type(v) == "table" and getmetatable(v) == SECRET
end

-- unit token -> { name, spellID, notInterruptible } or nil
stub.casting = {}
function stub.setCasting(token, info) stub.casting[token] = info end

UnitCastingInfo = function(u)
  local c = stub.casting[u]
  if not c then return nil end
  -- real return order: name, text, texture, startMs, endMs, isTradeskill,
  --                    notInterruptible, spellID (8th in modern clients)
  return c.name, c.name, nil, 0, 0, false, c.notInterruptible, c.spellID, c.spellID
end
UnitChannelInfo = function() return nil end

function stub.setParty(members)
  stub.units = {}
  for i, m in ipairs(members) do
    local token = i == 1 and "player" or ("party" .. (i - 1))
    stub.units[token] = m
  end
  stub.groupSize = #members
end

-- ------------------------------------------------------------- event plumbing
-- Init.lua creates exactly one frame and registers events on it. Capture the
-- OnEvent script so the test can fire events by name.
local onEvent, registered = nil, {}

CreateFrame = function()
  local f = {}
  local noop = function() return f end
  local methods = {
    "SetSize", "SetPoint", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor",
    "SetMovable", "EnableMouse", "RegisterForDrag", "Show", "Hide", "StartMoving",
    "StopMovingOrSizing", "SetWidth", "SetJustifyH", "SetWordWrap", "SetText",
    "SetScript", "RegisterEvent", "UnregisterEvent", "CreateFontString", "GetPoint",
    "IsShown", "SetOwner", "AddLine", "AddDoubleLine",
  }
  for _, m in ipairs(methods) do f[m] = noop end
  f.CreateFontString = function() local fs = {}; for _, m in ipairs(methods) do fs[m] = function() return fs end end return fs end
  f.RegisterEvent = function(_, e) registered[e] = true return f end
  f.SetScript = function(_, which, fn) if which == "OnEvent" then onEvent = fn end return f end
  f.IsShown = function() return true end
  f.GetPoint = function() return "CENTER", nil, nil, 0, 0 end
  return f
end

function stub.fire(event, ...)
  if onEvent then onEvent(nil, event, ...) end
end

function stub.registered(event) return registered[event] == true end

-- ------------------------------------------------------------- combat log feed
local payload = {}
CombatLogGetCurrentEventInfo = function() return unpack(payload) end

-- Build a CLEU payload in the real field order and fire it.
--   stub.cleu("SPELL_CAST_SUCCESS", src, dst, { spellID, spellName, school, ... })
function stub.cleu(subevent, src, dst, extra)
  payload = {
    now, subevent, false,
    src and src.guid or nil, src and src.name or nil, src and src.flags or 0, 0,
    dst and dst.guid or nil, dst and dst.name or nil, dst and dst.flags or 0, 0,
  }
  for _, v in ipairs(extra or {}) do payload[#payload + 1] = v end
  -- The client refuses to deliver this event since 12.0.0, so there is no
  -- registered handler to fire. Drive the model's entry point directly -- the
  -- same way an offline WoWCombatLog.txt parser would have to.
  local ns = stub.ns
  ns.Cast:Ingest(payload[1], subevent, payload[4], payload[5], payload[6],
    payload[8], payload[9],
    payload[12], payload[13], payload[14], payload[15], payload[16],
    payload[17], payload[18], payload[19], payload[20], payload[21])
end

-- shorthand actor constructors
function stub.enemy(guid, name)
  return { guid = guid, name = name, flags = COMBATLOG_OBJECT_REACTION_HOSTILE }
end
function stub.friend(guid, name)
  return { guid = guid, name = name, flags = COMBATLOG_OBJECT_REACTION_FRIENDLY }
end

-- ------------------------------------------------------- combat logging state
-- The real LoggingCombat() is rate limited to 5 calls per 10 seconds shared
-- across every addon, and returns NIL (not false) when over the limit. That nil
-- is the whole reason Core/Logging.lua exists, so the stub reproduces it: the
-- test sets a budget and the stub starts handing back nil once it is spent.
stub.logging = { on = false, calls = 0, budget = math.huge, advanced = true }

LoggingCombat = function(newState)
  stub.logging.calls = stub.logging.calls + 1
  if stub.logging.calls > stub.logging.budget then return nil end
  if newState ~= nil then stub.logging.on = newState and true or false end
  return stub.logging.on
end

C_CVar = {
  GetCVarBool = function(name)
    if name ~= "advancedCombatLogging" then return nil end
    return stub.logging.advanced
  end,
}

stub.instance = nil
IsInInstance = function()
  if not stub.instance then return false, "none" end
  return true, stub.instance
end

C_Timer = { After = function(_, fn) fn() end }

-- Lua 5.2+ moved unpack; WoW is 5.1 where it is global.
unpack = unpack or table.unpack

return stub
