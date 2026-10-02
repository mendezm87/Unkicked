-- Unkicked :: Meter.lua
--
-- The one live feed 12.x left standing: C_DamageMeter.
--
-- Patch 12.0.0 took COMBAT_LOG_EVENT_UNFILTERED away, so the addon cannot see a
-- single cast. What it CAN see is what Blizzard's own meter sees, because the
-- server does the aggregation and hands back a finished answer. Enum.DamageMeterType
-- includes Interrupts, Deaths, DamageTaken and a per-spell breakdown, which is
-- enough for "who is kicking" per pull and per run.
--
-- It is NOT enough for "what got through". Interruptibility and the identity of
-- an enemy cast are not in this API and are secret values everywhere else, so
-- missed casts remain the offline parser's job. This module never pretends
-- otherwise -- see Panel's footer.
--
-- FIVE THINGS THAT WILL BITE WHOEVER EDITS THIS (each cost somebody a release):
--
-- 1) IN COMBAT EVERY AMOUNT IS A SECRET VALUE. You may not compare it, add it,
--    format it, or use it as a table key. You MAY hand it straight to
--    FontString:SetText / StatusBar:SetValue, which are whitelisted. So the live
--    path pipes raw values at widgets and the arithmetic path only runs when the
--    values have gone plain again (out of combat). Hence Snapshot() vs Rows().
--
-- 2) YOU MAY NOT HAND A SECRET BACK TO THE API. GetCombatSessionSourceFromType
--    with a secret GUID errors with "Secret values are only allowed during
--    untainted" and takes the whole draw down. So in combat metrics cannot be
--    cross-matched by GUID; classFilename/specIconID and isLocalPlayer are
--    NeverSecret and are the only join keys available.
--
-- 3) THE DEATHS METRIC IS A LIST OF DEATHS, NOT PLAYERS WITH COUNTS. One entry
--    per death, and only when deathRecapID ~= 0. Reading totalAmount there gives
--    0 for someone who died and nothing for someone who did not. You count rows.
--
-- 4) DO NOT HARDCODE THE SESSION NUMBERS. Enum.DamageMeterSessionType.Current /
--    .Overall are not guaranteed to be 0/1, and guessing reads a different
--    session than Details! is reading.
--
-- 5) AFTER ResetAllCombatSessions THE CURRENT SESSION CAN COME BACK EMPTY
--    MID-FIGHT while new data lands in a fresh session addressed by id. Without
--    the GetCombatSessionFromID fallback the panel goes blank during combat and
--    only fills in when the fight ends.

local ADDON, ns = ...

local Meter = {}
ns.Meter = Meter

-- Pull snapshots taken inside the current keystone, oldest first. Each is a
-- plain (readable) snapshot harvested after combat ended, which is the only
-- moment the numbers can be summed at all.
Meter.pulls = {}
Meter.run = nil   -- { level, mapName, startedAt, endedAt, deathCount }

local function metric(name)
  local E = Enum and Enum.DamageMeterType
  return E and E[name] or nil
end

-- Gotcha 4: ask the enum, never assume 0/1.
local function sessionValue(which)
  local S = Enum and Enum.DamageMeterSessionType
  if not S then return nil end
  if which == "overall" then return S.Overall end
  return S.Current
end

function Meter:Available()
  local C = C_DamageMeter
  if not C or not C.IsDamageMeterAvailable then return false end
  local ok, v = pcall(C.IsDamageMeterAvailable)
  return (ok and v) and true or false
end

local function hasSources(s)
  return s ~= nil and s.combatSources ~= nil and s.combatSources[1] ~= nil
end

local function newestSessionID()
  local C = C_DamageMeter
  if not C.GetAvailableCombatSessions then return nil end
  local ok, list = pcall(C.GetAvailableCombatSessions)
  if not ok or type(list) ~= "table" or #list == 0 then return nil end
  local newest = list[#list]
  if type(newest) == "table" then return newest.sessionID or newest.sessionId or newest.id end
  return newest
end

-- Gotcha 5.
local function sessionFor(which, attr)
  if not attr or not Meter:Available() then return nil end
  local value = sessionValue(which)
  if value == nil then return nil end

  local ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, value, attr)
  if not ok then return nil end
  if hasSources(s) then return s end

  -- Only meaningful for the live segment: "overall" is an accumulation, not a
  -- session sitting under an id.
  if which ~= "overall" and C_DamageMeter.GetCombatSessionFromID then
    local id = newestSessionID()
    if id ~= nil then
      local ok2, byId = pcall(C_DamageMeter.GetCombatSessionFromID, id, attr)
      if ok2 and hasSources(byId) then return byId end
    end
  end
  return s
end

function Meter:Duration(which)
  local C = C_DamageMeter
  if not C or not C.GetSessionDurationSeconds then return nil end
  local value = sessionValue(which)
  if value == nil then return nil end
  local ok, v = pcall(C.GetSessionDurationSeconds, value)
  return (ok and ns.Plain(v)) or nil
end

-- Gotcha 3: a Deaths row is a death, and only if deathRecapID ~= 0 (that field
-- is NeverSecret, so comparing it is safe even mid-combat).
local function isRealDeath(src)
  local recap = ns.Plain(src.deathRecapID)
  return recap ~= nil and recap ~= 0
end

-- Gotcha 2: classFilename and specIconID stay readable where the GUID does not,
-- so they are the only in-combat join key. Two players of one spec collide, so
-- the key is only trusted when it is unique in BOTH lists -- a blank cell beats
-- swapping two players' numbers.
local function identityOf(src)
  local class = ns.Plain(src.classFilename)
  local icon = ns.Plain(src.specIconID)
  if class == nil or icon == nil then return nil end
  return tostring(class) .. "/" .. tostring(icon)
end

-- An index of one metric's actors, so a row can be looked up from another
-- metric's list without asking the API per row (and without passing a GUID back).
local function indexOf(which, attr, countOnly)
  local s = sessionFor(which, attr)
  local list = s and s.combatSources
  if not list then return nil end

  local idx = { byGuid = {}, byIdentity = {}, countGuid = {}, countIdentity = {}, dupe = {} }
  for i = 1, #list do
    local src = list[i]
    local counts = (not countOnly) or isRealDeath(src)
    local guid = ns.Plain(src.guid)
    local ident = identityOf(src)
    if guid ~= nil then
      if idx.byGuid[guid] == nil then idx.byGuid[guid] = src end
      if counts then idx.countGuid[guid] = (idx.countGuid[guid] or 0) + 1 end
    end
    if ident then
      if idx.byIdentity[ident] == nil then idx.byIdentity[ident] = src
      else idx.dupe[ident] = true end
      if counts then idx.countIdentity[ident] = (idx.countIdentity[ident] or 0) + 1 end
    end
  end
  return idx
end

local function lookup(idx, row)
  if not idx then return nil end
  if row.guid ~= nil and idx.byGuid[row.guid] then return idx.byGuid[row.guid] end
  if row.identity and not idx.dupe[row.identity] then return idx.byIdentity[row.identity] end
  return nil
end

local function lookupCount(idx, row)
  if not idx then return nil end
  if row.guid ~= nil and idx.countGuid[row.guid] ~= nil then return idx.countGuid[row.guid] end
  if row.identity and not idx.dupe[row.identity] then return idx.countIdentity[row.identity] or 0 end
  return nil
end

-- ---------------------------------------------------------------------- rows
-- One row per player who was there -- the union of the actors in every metric we
-- show, not just the sorted one. A healer who kicked nothing still belongs on
-- screen, with a zero, or the panel is reporting "who scored" and not "who was
-- in the group".
--
-- Order comes from the Interrupts list, because the API returns it ALREADY
-- SORTED by the metric asked for and list position is the only ranking that
-- exists when the amounts cannot be compared.
function Meter:Rows(which)
  if not self:Available() then return nil end

  local rows, seen = {}, {}
  local secret = false

  local function add(src)
    local guid = ns.Plain(src.guid)
    local ident = identityOf(src)
    local key = (guid ~= nil and ("g:" .. tostring(guid)))
      or (ident and ("i:" .. ident))
      or nil
    if key and seen[key] then return end
    if key then seen[key] = true end

    local name = ns.Plain(src.name)
    local row = {
      guid = guid,
      identity = ident,
      name = name,
      class = ns.Plain(src.classFilename),
      isYou = ns.Plain(src.isLocalPlayer) == true,
    }
    if name == nil then secret = true end
    rows[#rows + 1] = row
  end

  for _, attr in ipairs({ metric("Interrupts"), metric("DamageTaken"), metric("Deaths") }) do
    local s = sessionFor(which, attr)
    local list = s and s.combatSources
    if list then
      for i = 1, #list do
        -- Deaths holds one entry per death; a dupe would otherwise add a row
        -- per death for the same player.
        if attr ~= metric("Deaths") or isRealDeath(list[i]) then add(list[i]) end
      end
    end
  end
  if #rows == 0 then return nil end

  local iKicks = indexOf(which, metric("Interrupts"))
  local iTaken = indexOf(which, metric("DamageTaken"))
  local iDeaths = indexOf(which, metric("Deaths"), true)

  for _, row in ipairs(rows) do
    local k = lookup(iKicks, row)
    local t = lookup(iTaken, row)
    -- Gotcha 1: these may be secret. They are carried RAW and only ever handed
    -- to a widget; `plain` says whether arithmetic on them is legal.
    row.kicks = k and k.totalAmount or nil
    row.taken = t and t.totalAmount or nil
    row.deaths = lookupCount(iDeaths, row) or 0
    if ns.IsSecret(row.kicks) or ns.IsSecret(row.taken) then secret = true end
  end

  return rows, not secret
end

-- --------------------------------------------- what the party ate that was kickable
-- The closest thing to a "missed kick" the live client can produce.
--
-- C_DamageMeter will not say what an enemy was casting or whether it could be
-- interrupted -- so the identity of a cast is unavailable in game, permanently.
-- But the DamageTaken drill-down DOES name the spell that hit each player, and
-- the offline parser has already PROVEN which spell ids are interruptible (a
-- SPELL_INTERRUPT was seen stopping them) and mirrored that into
-- Data/Interruptible.lua. Intersecting the two gives: how much of the damage
-- this player took came from spells that can be stopped.
--
-- Read it as a COST, not a count. It cannot tell how many casts there were, nor
-- whether a given one was kicked and a later one was not -- only that this
-- damage came from a spell somebody could have interrupted. The per-cast answer
-- stays the parser's.
--
-- Needs a readable guid, so like every drill-down it is out-of-combat only.
function Meter:Kickable(which, guid)
  local known = ns.KNOWN_INTERRUPTIBLE
  if not known or guid == nil or ns.IsSecret(guid) then return nil end
  local spells = self:Spells(which, guid, nil, "DamageTaken")
  if not spells then return nil end

  local total, by = 0, {}
  for i = 1, #spells do
    local sp = spells[i]
    local id = ns.Plain(sp.spellID)
    local amount = tonumber(ns.Plain(sp.totalAmount))
    if id and amount and known[id] == true then
      total = total + amount
      by[#by + 1] = { spellID = id, amount = amount }
    end
  end
  table.sort(by, function(a, b) return a.amount > b.amount end)
  return total, by
end

-- A readable snapshot, or nil. Only ever succeeds when the values have gone
-- plain (out of combat), which is exactly why pulls are harvested at the end of
-- one rather than during it.
function Meter:Snapshot(which)
  local rows, plain = self:Rows(which)
  if not rows or not plain then return nil end

  local out = { rows = {}, duration = self:Duration(which), kicks = 0, deaths = 0, taken = 0 }
  for _, row in ipairs(rows) do
    local r = {
      name = row.name, class = row.class, isYou = row.isYou,
      identity = row.identity,
      kicks = tonumber(row.kicks) or 0,
      taken = tonumber(row.taken) or 0,
      deaths = row.deaths or 0,
    }
    r.kickable, r.kickableBy = self:Kickable(which, row.guid)
    out.kickable = (out.kickable or 0) + (r.kickable or 0)
    out.kicks = out.kicks + r.kicks
    out.deaths = out.deaths + r.deaths
    out.taken = out.taken + r.taken
    out.rows[#out.rows + 1] = r
  end
  return out
end

-- Per-spell drill-down for one player. Needs a READABLE guid (gotcha 2), so it
-- is out-of-combat only and returns nil rather than erroring in a pull.
function Meter:Spells(which, guid, creatureID, attrName)
  local attr = metric(attrName or "Interrupts")
  if not attr or guid == nil or ns.IsSecret(guid) then return nil end
  local value = sessionValue(which)
  if value == nil then return nil end
  local ok, container = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
    value, attr, guid, creatureID)
  if not ok or not container then return nil end
  return container.combatSpells
end

-- ------------------------------------------------------------- the run ledger
-- The run total is the sum of the pulls inside the keystone window, deliberately
-- -- not the Overall session, which spans everything since login including the
-- target dummy you hit in the city. Same window the offline parser reports on,
-- so the two agree.
function Meter:Total()
  if #self.pulls == 0 then return nil end
  local byKey, order = {}, {}
  local total = { rows = {}, kicks = 0, deaths = 0, taken = 0, kickable = 0,
                  duration = 0, pulls = #self.pulls }

  for _, pull in ipairs(self.pulls) do
    total.duration = total.duration + (pull.duration or 0)
    for _, r in ipairs(pull.rows) do
      local key = r.name or r.identity or tostring(r)
      local acc = byKey[key]
      if not acc then
        acc = { name = r.name, class = r.class, isYou = r.isYou,
                kicks = 0, taken = 0, deaths = 0, kickable = 0 }
        byKey[key] = acc
        order[#order + 1] = acc
      end
      acc.kicks = acc.kicks + r.kicks
      acc.taken = acc.taken + r.taken
      acc.deaths = acc.deaths + r.deaths
      acc.kickable = acc.kickable + (r.kickable or 0)
    end
  end

  for _, acc in ipairs(order) do
    total.kicks = total.kicks + acc.kicks
    total.deaths = total.deaths + acc.deaths
    total.taken = total.taken + acc.taken
    total.kickable = total.kickable + (acc.kickable or 0)
    total.rows[#total.rows + 1] = acc
  end
  -- Most kicks first. Legal here and only here: a snapshot is plain by
  -- construction, so these numbers can actually be compared.
  table.sort(total.rows, function(a, b)
    if a.kicks ~= b.kicks then return a.kicks > b.kicks end
    return (a.name or "") < (b.name or "")
  end)
  return total
end

-- The client's own death counter for the key, which counts deaths we were never
-- told about by any metric. Reported beside ours rather than instead of it: a
-- total that silently disagrees with the group's own timer is worse than two
-- numbers and a note.
function Meter:KeyDeaths()
  local C = C_ChallengeMode
  if not C or not C.GetDeathCount then return nil end
  local ok, v = pcall(C.GetDeathCount)
  return (ok and ns.Plain(v)) or nil
end

function Meter:Clock(s)
  s = math.floor(tonumber(s) or 0)
  return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

-- ------------------------------------------------------------------- harvest
-- Values go plain when combat ends, but not necessarily on the same frame as
-- PLAYER_REGEN_ENABLED, and a snapshot taken a tick early comes back secret and
-- unusable. So: try, and if the values are still secret, try again shortly --
-- rather than dropping the pull or, worse, recording zeroes.
local HARVEST_TRIES = 4
local HARVEST_GAP = 0.75

local function harvest(try)
  if not Meter.run then return end
  local snap = Meter:Snapshot("current")
  if not snap then
    if try < HARVEST_TRIES and C_Timer and C_Timer.After then
      C_Timer.After(HARVEST_GAP, function() harvest(try + 1) end)
    end
    return
  end

  -- A pull nobody did anything in is not a pull. Keeps the numbering stable
  -- enough to say out loud, the same rule the offline parser uses.
  if snap.kicks == 0 and snap.taken == 0 and snap.deaths == 0 then return end

  snap.index = #Meter.pulls + 1
  Meter.pulls[snap.index] = snap

  if ns.db and ns.db.pullReport then Meter:Announce(snap) end
  if ns.Panel then ns.Panel:Refresh() end
end

function Meter:Announce(snap)
  local parts = {}
  for _, r in ipairs(snap.rows) do
    if r.kicks > 0 then
      parts[#parts + 1] = ("|c%s%s|r %d"):format(ns.ClassColor(r.class), r.name or "?", r.kicks)
    end
  end
  table.sort(parts)
  ns.Print("pull %d (%s) -- %d kicks%s%s%s",
    snap.index or 0, self:Clock(snap.duration or 0), snap.kicks,
    (snap.kickable or 0) > 0 and ("  |cffff9933%s from kickable casts|r"):format(ns.Short(snap.kickable)) or "",
    snap.deaths > 0 and ("  |cffff2020%d deaths|r"):format(snap.deaths) or "",
    #parts > 0 and ("  " .. table.concat(parts, "  ")) or "")
end

function Meter:Report()
  local total = self:Total()
  if not total then
    ns.Print("no pulls recorded in this run yet")
    return
  end
  local run = self.run or {}
  ns.Print("%s%s -- %s in combat, %d pulls, %d kicks",
    run.mapName or "run", run.level and (" +" .. run.level) or "",
    self:Clock(total.duration), total.pulls, total.kicks)
  for _, r in ipairs(total.rows) do
    print(("  |c%s%-20s|r %3d kicks   %d deaths   %8s taken   %8s kickable")
      :format(ns.ClassColor(r.class), r.name or "?", r.kicks, r.deaths,
              ns.Short(r.taken), ns.Short(r.kickable or 0)))
  end
  if (total.kickable or 0) > 0 then
    print(("  |cffff9933%s of that came from spells proven interruptible|r")
      :format(ns.Short(total.kickable)))
  end

  local counted = self:KeyDeaths()
  if counted and counted ~= total.deaths then
    print(("  |cffff9933the key counts %d deaths; %d are in the segments above|r")
      :format(counted, total.deaths))
  end
  print("  |cff808080kickable = damage from spells PROVEN interruptible; it is a cost, not a cast count.|r")
  print("  |cff808080which casts went unkicked still needs the log parser.|r")
end

-- --------------------------------------------------------------------- events
-- Mythic+ only, same gate the offline parser uses: the keystone window is the
-- run. CHALLENGE_MODE_START states the level; difficulty alone proves nothing.
local function startRun()
  local level, mapName
  local C = C_ChallengeMode
  if C and C.GetActiveKeystoneInfo then
    local ok, l = pcall(C.GetActiveKeystoneInfo)
    if ok then level = ns.Plain(l) end
  end
  if C and C.GetActiveChallengeMapID and C.GetMapUIInfo then
    local ok, id = pcall(C.GetActiveChallengeMapID)
    if ok and ns.Plain(id) then
      local ok2, name = pcall(C.GetMapUIInfo, id)
      if ok2 then mapName = ns.Plain(name) end
    end
  end
  Meter.pulls = {}
  Meter.run = { level = level, mapName = mapName or (GetInstanceInfo and GetInstanceInfo()) or nil,
                startedAt = GetTime() }
  if ns.Panel then ns.Panel:Refresh() end
end

ns.On("CHALLENGE_MODE_START", startRun)

ns.On("CHALLENGE_MODE_COMPLETED", function()
  if not Meter.run then return end
  Meter.run.endedAt = GetTime()
  -- The last pull is the boss, and combat ends with it, so the harvest for it is
  -- still in flight. Report after it lands rather than one pull short.
  if C_Timer and C_Timer.After then
    C_Timer.After(HARVEST_GAP * HARVEST_TRIES, function() Meter:Report() end)
  else
    Meter:Report()
  end
end)

ns.On("CHALLENGE_MODE_RESET", function() Meter.pulls = {}; Meter.run = nil end)

ns.On("PLAYER_REGEN_ENABLED", function() harvest(1) end)

-- The restriction edge is the most reliable signal that amounts just became
-- readable again -- more reliable than regen, which is about combat and not
-- about secrets.
ns.On("ADDON_RESTRICTION_STATE_CHANGED", function() harvest(1) end)

ns.On("DAMAGE_METER_CURRENT_SESSION_UPDATED", function()
  if ns.Panel then ns.Panel:Refresh() end
end)
ns.On("DAMAGE_METER_COMBAT_SESSION_UPDATED", function()
  if ns.Panel then ns.Panel:Refresh() end
end)
