-- Unkicked :: Logging.lua
--
-- Is the client actually writing WoWCombatLog.txt right now?
--
-- On 12.x this is the single most useful thing the in-game addon can still do.
-- The analysis moved offline, and the offline parser is worthless if you forgot
-- to type /combatlog before the key -- which you cannot tell from inside the
-- game, because nothing in the default UI says so and the toggle silently
-- resets on every logout.
--
-- Two separate things have to be true:
--   1. LoggingCombat()  -- the file is being written at all. Per-session.
--   2. CVar advancedCombatLogging -- the unit fields are included. Sticky, but
--      without it the parser gets no damage amounts, GUIDs or positions, so a
--      log written without it cannot answer any of the questions we ask.
--
-- The trap here, and the reason this module exists instead of a one-line call
-- in Panel:Refresh(): LoggingCombat() is rate limited to FIVE CALLS PER TEN
-- SECONDS, shared across every addon on the system *and* the /combatlog command
-- itself. Over the limit it returns nil -- not false. A panel that polled it on
-- a ticker would burn the shared budget, break other addons' logging, and
-- display "logging off" while it was merrily on. So: never poll, cache the last
-- good answer, spend at most one call per MIN_GAP, and treat nil as "unknown",
-- never as "off".

local ADDON, ns = ...

local Logging = {}
ns.Logging = Logging

-- Minimum seconds between real LoggingCombat() calls. Two per ten seconds
-- leaves most of the shared 5/10s budget for everyone else.
local MIN_GAP = 5

local ADVANCED_CVAR = "advancedCombatLogging"

-- on:        true / false / nil  (nil = never got an answer)
-- advanced:  true / false / nil  (nil = cvar unreadable)
-- at:        GetTime() of the last answer we actually believe
-- limited:   the most recent query came back rate limited
local st = { on = nil, advanced = nil, at = 0, limited = false, asked = 0 }

local function getCVarBool(name)
  local fn = (C_CVar and C_CVar.GetCVarBool) or _G.GetCVarBool
  if not fn then return nil end
  local ok, v = pcall(fn, name)
  if not ok then return nil end
  -- An unknown cvar reads back nil; that is "cannot tell", not "off".
  if v == nil then return nil end
  return v and true or false
end

-- Reads the advanced-logging cvar. Cheap and not rate limited, unlike the
-- logging state itself, so this one can be called whenever.
function Logging:Advanced()
  st.advanced = getCVarBool(ADVANCED_CVAR)
  return st.advanced
end

-- Returns the cached state, refreshing it only if the rate-limit gap has
-- elapsed. Safe to call from every panel refresh.
function Logging:Query(force)
  self:Advanced()

  local now = GetTime()
  if not force and st.at > 0 and (now - st.asked) < MIN_GAP then
    return st.on, st.advanced
  end

  if not _G.LoggingCombat then
    st.limited = false
    return st.on, st.advanced
  end

  st.asked = now
  local ok, v = pcall(_G.LoggingCombat)
  if not ok then
    -- Should not happen -- the function is not protected -- but a future
    -- restriction here must cost us this indicator, not the addon.
    st.limited = true
    return st.on, st.advanced
  end

  if v == nil then
    -- Rate limited. The state did not change and we were not told what it is,
    -- so keep the last thing we knew and say it is stale.
    st.limited = true
  else
    st.on, st.at, st.limited = (v and true or false), now, false
  end
  return st.on, st.advanced
end

-- on, advanced, limited, ageSeconds
function Logging:State()
  return st.on, st.advanced, st.limited, (st.at > 0 and (GetTime() - st.at) or nil)
end

-- "ready" | "basic" | "off" | "unknown"
--   ready   -- logging on and advanced on: the parser will get everything
--   basic   -- logging on, advanced off: a log with no unit fields, so no
--              damage numbers and no death attribution. Near useless to us.
--   off     -- nothing is being written
--   unknown -- we have never had an answer, or only a rate limited one
function Logging:Verdict()
  self:Query()
  if st.on == nil then return "unknown" end
  if not st.on then return "off" end
  if st.advanced == false then return "basic" end
  if st.advanced == nil then return "unknown-advanced" end
  return "ready"
end

local LABEL = {
  ready             = "|cff40c860log: on|r",
  basic             = "|cffff9933log: on, not advanced|r",
  off               = "|cffff2020log: OFF -- /combatlog|r",
  unknown           = "|cff808080log: unknown|r",
  ["unknown-advanced"] = "|cffff9933log: on, advanced unknown|r",
}

-- Short, for the panel.
function Logging:Label()
  local v = self:Verdict()
  local s = LABEL[v] or LABEL.unknown
  if st.limited and st.at > 0 then s = s .. " |cff808080(stale)|r" end
  return s, v
end

-- Long, for a tooltip or chat. Returns an array of { text, r, g, b }.
function Logging:Lines()
  local v = self:Verdict()
  local out = {}
  local function add(t, r, g, b) out[#out + 1] = { text = t, r = r or 1, g = g or 1, b = b or 1 } end

  if v == "ready" then
    add("Combat logging is on, with advanced data.", 0.3, 1, 0.3)
    add("WoWCombatLog.txt is being written -- the parser will see this run.", 0.7, 0.7, 0.7)
  elseif v == "basic" then
    add("Combat logging is on, but Advanced Combat Logging is OFF.", 1, 0.6, 0.2)
    add("The log will have no unit fields, so the parser gets no damage", 0.7, 0.7, 0.7)
    add("amounts and cannot attribute deaths. Fix it in:", 0.7, 0.7, 0.7)
    add("Esc > Options > System > Network > Advanced Combat Logging", 1, 0.82, 0)
  elseif v == "off" then
    add("Combat logging is OFF -- nothing is being written.", 1, 0.2, 0.2)
    add("Type /combatlog before the pull. It resets every logout.", 1, 0.82, 0)
    add("Click here to turn it on.", 1, 0.82, 0)
  elseif v == "unknown-advanced" then
    add("Combat logging is on; could not read the advanced setting.", 1, 0.6, 0.2)
    add("Check Options > System > Network > Advanced Combat Logging.", 0.7, 0.7, 0.7)
  else
    add("Cannot tell whether combat logging is on.", 0.6, 0.6, 0.6)
    add("LoggingCombat() is rate limited to 5 calls / 10s across all", 0.7, 0.7, 0.7)
    add("addons, and a limited call returns nothing. Try again shortly.", 0.7, 0.7, 0.7)
  end

  if st.limited and st.at > 0 then
    add(("Last confirmed %ds ago; the latest check was rate limited."):format(GetTime() - st.at),
      0.6, 0.6, 0.6)
  end
  return out
end

-- Turning it on ourselves. LoggingCombat(true) is not protected, but it spends
-- the same shared budget, so this is only ever user-initiated -- a click or a
-- slash command, never automatic.
function Logging:Set(on)
  if not _G.LoggingCombat then
    ns.Print("this client has no LoggingCombat; type |cffffd200/combatlog|r instead")
    return false
  end
  local ok = pcall(_G.LoggingCombat, on and true or false)
  if not ok then
    ns.Print("could not change logging; type |cffffd200/combatlog|r instead")
    return false
  end
  -- Do not immediately re-query: that is a second call against the budget and
  -- would likely come back nil anyway. Record what we asked for and let the
  -- next natural check confirm it.
  st.on, st.at, st.limited = (on and true or false), GetTime(), false
  st.asked = GetTime()
  if ns.Panel then ns.Panel:Refresh() end
  return true
end

-- --------------------------------------------------------------- the reminder
-- The only moment this really matters is walking into an instance with logging
-- off. Say it once per zone, loudly, and never again -- a nag every pull is how
-- an addon gets uninstalled.
local nagged

local function checkZone()
  local inside = IsInInstance and select(1, IsInInstance())
  if not inside then nagged = nil; return end

  local v = Logging:Verdict()
  if v == "off" then
    if nagged ~= "off" then
      nagged = "off"
      ns.Print("|cffff2020combat logging is OFF|r -- type |cffffd200/combatlog|r now "
        .. "or this run will not be in the log.")
    end
  elseif v == "basic" then
    if nagged ~= "basic" then
      nagged = "basic"
      ns.Print("|cffff9933advanced combat logging is off|r -- the log will have no damage "
        .. "numbers. Options > System > Network.")
    end
  else
    nagged = v
  end
  if ns.Panel then ns.Panel:Refresh() end
end

-- Deliberately not a ticker: these are the moments the answer can have changed
-- or started to matter. PLAYER_REGEN_DISABLED is every pull, which the MIN_GAP
-- throttle collapses to at most one real call per five seconds.
ns.On("PLAYER_ENTERING_WORLD", function() Logging:Query(true); checkZone() end)
ns.On("ZONE_CHANGED_NEW_AREA", function() Logging:Query(true); checkZone() end)
ns.On("PLAYER_REGEN_DISABLED", checkZone)
ns.On("ENCOUNTER_START", checkZone)
