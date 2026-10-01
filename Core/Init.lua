-- Unkicked :: Init.lua
-- Namespace, saved settings, and the handful of helpers everything else uses.

local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = C_AddOns and C_AddOns.GetAddOnMetadata(ADDON, "Version") or "0.1.0"

-- How long after a cast completes we keep attributing damage to it. Channels and
-- DoTs keep ticking well past SPELL_CAST_SUCCESS, so this is generous; the record
-- is shown immediately and its damage number grows while the window is open.
ns.DAMAGE_WINDOW = 30

-- A death within this many seconds of a cast's damage counts as "contributed to".
ns.DEATH_WINDOW = 5

-- Measured intervals are never exact: cast time, latency and log granularity all
-- shave fractions. Tolerate this much before believing a cooldown is shorter.
ns.CD_EPSILON_MS = 400

-- Before we have seen a player spend their interrupt even once, we do not know
-- whether they came into the pull with it already down. Casts in the first few
-- seconds of combat are marked low-confidence rather than dropped.
ns.COLD_START = 20

local DEFAULTS = {
  enabled = true,
  showPanel = true,
  announce = false,          -- off by default: nobody asked you to narrate party chat
  minDamage = 0,             -- hide chip damage
  onlyInterruptible = true,  -- hide casts we know were immune to interrupts
  includeUnknown = true,     -- keep casts whose interruptibility we could not read
  maxRows = 12,
  point = { "CENTER", 240, 80 },
  locked = false,
}

function ns.Deep(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      ns.Deep(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

function ns.Print(fmt, ...)
  print("|cff40c8ffUnkicked|r: " .. (select("#", ...) > 0 and fmt:format(...) or fmt))
end

function ns.ClassColor(class)
  local c = class and RAID_CLASS_COLORS[class]
  return c and c.colorStr or "ffffffff"
end

function ns.Short(n)
  if not n or n <= 0 then return "0" end
  if n >= 1e6 then return ("%.1fm"):format(n / 1e6) end
  if n >= 1e3 then return ("%.0fk"):format(n / 1e3) end
  return ("%d"):format(n)
end

-- Event plumbing: one frame, one dispatcher, modules register by event name.
local handlers = {}
local frame = CreateFrame("Frame", "UnkickedEventFrame")

-- Events that Midnight (12.0.0) made unregisterable for addons. Calling
-- RegisterEvent on one of these raises ADDON_ACTION_FORBIDDEN, which taints us
-- and spams BugGrabber, so we never attempt it -- we record it and degrade.
local FORBIDDEN = {
  COMBAT_LOG_EVENT = true,
  COMBAT_LOG_EVENT_UNFILTERED = true,
}

ns.blocked = {}

function ns.On(event, fn)
  if FORBIDDEN[event] then
    ns.blocked[event] = true
    return false
  end
  if not handlers[event] then
    handlers[event] = {}
    -- Blizzard can restrict further events without warning; a pcall means a new
    -- restriction costs us one feature, not the whole addon's load.
    local ok, err = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      handlers[event] = nil
      ns.blocked[event] = err or true
      return false
    end
  end
  table.insert(handlers[event], fn)
  return true
end

-- Secret values (12.0.0+) cannot be compared, used as table keys, or boolean
-- tested by addon code. Anything read about a unit that is not you or your pet
-- is secret while in an instance, so every such read goes through these.
local issecret = _G.issecretvalue
function ns.IsSecret(v)
  return issecret and issecret(v) or false
end

-- Returns a value only if it is safe to actually use; nil otherwise.
function ns.Plain(v)
  if v == nil or ns.IsSecret(v) then return nil end
  return v
end

-- True when the client has addon restrictions in force -- i.e. exactly the
-- content this addon was built for (dungeon, raid, M+, encounter, rated PvP).
function ns.Restricted()
  local R = C_RestrictedActions
  if not R or not R.IsAddOnRestrictionActive then return false end
  for _, t in pairs(Enum.AddOnRestrictionType or {}) do
    local ok, active = pcall(R.IsAddOnRestrictionActive, t)
    if ok and active then return true end
  end
  return false
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do list[i](...) end
end)

ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  UnkickedDB = UnkickedDB or {}
  ns.db = ns.Deep(UnkickedDB, DEFAULTS)

  if ns.DATA_BUILD then
    local client = select(2, GetBuildInfo())
    -- Not fatal, just worth knowing: the data was generated for a different build
    -- than the one you are running, so cooldowns may have moved under you.
    if client and ns.DATA_BUILD ~= "" and not ns.DATA_BUILD:find(client, 1, true) then
      ns.staleData = ns.DATA_BUILD
    end
  end

  if ns.blocked["COMBAT_LOG_EVENT_UNFILTERED"] then
    ns.Print("|cffff2020cannot track casts on this client.|r "
      .. "Patch 12.0.0 made COMBAT_LOG_EVENT_UNFILTERED unregisterable for addons. "
      .. "Type |cffffd200/uk why|r for what that means.")
  end
end)
