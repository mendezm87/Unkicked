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

function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    frame:RegisterEvent(event)
  end
  table.insert(handlers[event], fn)
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
end)
