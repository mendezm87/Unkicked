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
-- A pet interrupt (Spell Lock) lives in the PET spellbook, never the player's, so
-- the warlock case can only be tested through this call.
IsSpellKnown = function(id, isPet)
  local u = stub.units[isPet and "pet" or "player"]
  return u and u.spells and u.spells[id] or false
end
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
--
-- The widget itself is permissive: any method you call on it returns it. That is
-- not a model of the real client -- it cannot prove a frame actually renders --
-- but it does let UI/Panel.lua be LOADED and driven headlessly, which catches
-- the class of bug that leaves nothing on screen in game: a nil field, a bad
-- format string, a method called on a module that was not there yet.
local onEvent, registered = nil, {}
stub.frames = {}

local function widget(name)
  local w = { _name = name, _shown = false, _text = nil, _points = {} }
  return setmetatable(w, { __index = function(t, k)
    if k == "Show" then return function() t._shown = true; return t end end
    if k == "Hide" then return function() t._shown = false; return t end end
    if k == "IsShown" then return function() return t._shown end end
    if k == "SetText" then return function(_, v) t._text = v; return t end end
    if k == "GetText" then return function() return t._text end end
    if k == "SetSize" then return function(_, w2, h) t._w, t._h = w2, h; return t end end
    if k == "GetHeight" then return function() return t._h end end
    if k == "SetPoint" then return function(_, ...) t._points[#t._points + 1] = { ... }; return t end end
    if k == "GetPoint" then return function() return "CENTER", nil, nil, 0, 0 end end
    if k == "ClearAllPoints" then return function() t._points = {}; return t end end
    if k == "CreateFontString" then return function() return widget(name .. "-fs") end end
    if k == "RegisterEvent" then return function(_, e) registered[e] = true; return t end end
    -- Lets a test press a button the way a player does, rather than reaching
    -- into the stored handler and bypassing whatever the button does first.
    if k == "Click" then
      return function(_, button)
        if t._OnClick then t._OnClick(t, button or "LeftButton") end
        return t
      end
    end
    if k == "SetScript" then
      return function(_, which, fn)
        if which == "OnEvent" then onEvent = fn end
        t["_" .. which] = fn
        return t
      end
    end
    return function() return t end
  end })
end
stub.widget = widget

CreateFrame = function(_, name)
  local f = widget(name or "anon")
  if name then stub.frames[name] = f end
  return f
end

GameTooltip = widget("GameTooltip")
SlashCmdList = {}

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


-- -------------------------------------------------------------- C_DamageMeter
-- The sanctioned replacement for the combat-log feed (12.0.0+). The parts that
-- matter to a test are the ones that are easy to get wrong in the real client:
--   * in combat every amount, the name and the GUID are SECRET; classFilename,
--     specIconID, isLocalPlayer and deathRecapID are NeverSecret
--   * Deaths is one entry PER DEATH, and only counts when deathRecapID ~= 0
--   * the session enum values are not guaranteed to be 0/1
--   * the Current session can come back empty while a fresh one holds the data
Enum = Enum or {}
-- Deliberately NOT 0/1: a module that hardcodes the numbers must fail here.
Enum.DamageMeterSessionType = { Current = 7, Overall = 8, Expired = 9 }
Enum.DamageMeterType = {
  DamageDone = 1, HealingDone = 2, Absorbs = 3, DamageTaken = 4,
  AvoidableDamageTaken = 5, Interrupts = 6, Dispels = 7, Deaths = 8,
  EnemyDamageTaken = 9,
}
Enum.AddOnRestrictionType = Enum.AddOnRestrictionType or {}

-- which -> list of { name, class, icon, guid, kicks, taken, deaths, isYou }
-- Off by default so the existing "no feed at all" tests keep describing a client
-- with neither feed nor meter; the meter tests turn it on explicitly.
stub.meter = {
  available = false,
  secret = false,
  secretNames = false,  -- measured on a real key: a name can be unreadable
                        -- while the amount beside it is plain
  secretGuids = false,  -- MEASURED on a real key (/uk audit, Voidscar +10): the
                        -- guid came back secret with the name and total beside it
                        -- plain, and stayed secret after the key ended
  emptyCurrent = false,   -- reproduces the post-reset empty Current session
  duration = { current = 60, overall = 300 },
  players = { current = {}, overall = {} },
  sourceCalls = {},
  spells = {},        -- guid -> combatSpells for the Interrupts metric
  damageSpells = {},  -- guid -> combatSpells for the DamageTaken metric
}

function stub.setMeter(which, players, opts)
  if opts and opts.duration then stub.meter.duration[which] = opts.duration end
  stub.meter.players[which] = players or {}
end

local function maybeSecret(v)
  if v == nil then return nil end
  if stub.meter.secret then return stub.secret(v) end
  return v
end

local function sourcesFor(which, attr)
  local E = Enum.DamageMeterType
  local out = {}
  for _, p in ipairs(stub.meter.players[which] or {}) do
    local base = {
      -- NeverSecret in the real client, so never wrapped here either.
      classFilename = p.class,
      specIconID = p.icon,
      isLocalPlayer = p.isYou and true or false,
      deathRecapID = 0,
      -- Names and numbers are secret INDEPENDENTLY -- the Voidscar +10 audit caught
      -- a secret guid sitting beside a plain name and a plain total. plainNames is
      -- the regime where the name is the only join left.
      name = (stub.meter.secretNames and p.name ~= nil) and stub.secret(p.name)
        or (stub.meter.plainNames and p.name)
        or maybeSecret(p.name),
      guid = (stub.meter.secretGuids and p.guid ~= nil) and stub.secret(p.guid)
        or maybeSecret(p.guid),
    }
    if attr == E.Deaths then
      -- one entry per death, not a player with a count
      for i = 1, (p.deaths or 0) do
        local row = {}
        for k, v in pairs(base) do row[k] = v end
        row.deathRecapID = 1000 + i
        row.deathTimeSeconds = maybeSecret(10 * i)
        row.totalAmount = maybeSecret(0)
        out[#out + 1] = row
      end
      -- and a row for someone who did NOT die, exactly as the real metric does
      if (p.deaths or 0) == 0 then
        base.totalAmount = maybeSecret(0)
        out[#out + 1] = base
      end
    else
      local amount = 0
      if attr == E.Interrupts then amount = p.kicks or 0
      elseif attr == E.DamageTaken then amount = p.taken or 0 end
      base.totalAmount = maybeSecret(amount)
      base.amountPerSecond = maybeSecret(amount / 60)
      out[#out + 1] = base
    end
  end
  -- The API returns the list ALREADY SORTED by the metric asked for; position in
  -- the list is the only ranking available when the amounts are secret.
  local rankBy = (attr == E.Interrupts and "kicks")
    or (attr == E.DamageTaken and "taken") or nil
  if rankBy then
    local src = stub.meter.players[which] or {}
    local order = {}
    for i, p in ipairs(src) do order[i] = { p[rankBy] or 0, out[i] } end
    table.sort(order, function(a, b) return a[1] > b[1] end)
    local sorted = {}
    for i, o in ipairs(order) do sorted[i] = o[2] end
    out = sorted
  end
  return out
end

C_DamageMeter = {
  IsDamageMeterAvailable = function() return stub.meter.available end,

  GetCombatSessionFromType = function(sessionValue, attr)
    local S = Enum.DamageMeterSessionType
    local which = (sessionValue == S.Overall) and "overall" or "current"
    if which == "current" and stub.meter.emptyCurrent then
      return { combatSources = {} }
    end
    return { combatSources = sourcesFor(which, attr) }
  end,

  GetAvailableCombatSessions = function() return { { sessionID = 42 } } end,

  GetCombatSessionFromID = function(id, attr)
    if id ~= 42 then return nil end
    return { combatSources = sourcesFor("current", attr) }
  end,

  GetSessionDurationSeconds = function(sessionValue)
    local S = Enum.DamageMeterSessionType
    return (sessionValue == S.Overall) and stub.meter.duration.overall
      or stub.meter.duration.current
  end,

  -- Handing a secret back to the API is what errors in the real client, and the
  -- error takes the whole draw down. So the stub raises too.
  GetCombatSessionSourceFromType = function(sessionValue, attr, guid, creatureID)
    if issecretvalue(guid) then
      error("Secret values are only allowed during untainted execution", 2)
    end
    stub.meter.sourceCalls[#stub.meter.sourceCalls + 1] = { attr, guid, creatureID }
    local bag = (attr == Enum.DamageMeterType.DamageTaken)
      and stub.meter.damageSpells or stub.meter.spells
    return { totalAmount = 0, combatSpells = bag[guid] or {} }
  end,

  ResetAllCombatSessions = function() end,
}

stub.challenge = { level = nil, mapID = nil, mapName = nil, deaths = 0, active = nil }
C_ChallengeMode = {
  -- active is deliberately nil unless a test sets it, so the fallback path
  -- (a keystone level is readable) is exercised as well as the direct answer.
  IsChallengeModeActive = function() return stub.challenge.active end,
  GetActiveKeystoneInfo = function() return stub.challenge.level end,
  GetActiveChallengeMapID = function() return stub.challenge.mapID end,
  GetMapUIInfo = function() return stub.challenge.mapName end,
  GetDeathCount = function() return stub.challenge.deaths end,
}

C_Spell = { GetSpellName = function(id) return "Spell" .. tostring(id) end }
GetInstanceInfo = function() return stub.instance or "nowhere" end

stub.instance = nil
IsInInstance = function()
  if not stub.instance then return false, "none" end
  return true, stub.instance
end

C_Timer = { After = function(_, fn) fn() end }

-- The wall clock, which unlike GetTime() survives a logout and is what a stored
-- run is stamped with.
stub.wallclock = 1770000000
time = function() return stub.wallclock end

-- Lua 5.2+ moved unpack; WoW is 5.1 where it is global.
unpack = unpack or table.unpack

return stub
