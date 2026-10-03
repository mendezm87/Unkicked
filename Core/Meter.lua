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
Meter.run = nil   -- { level, mapName, startedAt, endedAt, deathCount, reported }

-- The last readable snapshot, and the reason this file no longer treats the
-- Current session as "a pull".
--
-- VERIFIED ON A REAL KEY (The Blinding Vale +13, 2026-10-01): C_DamageMeter's
-- Current session does NOT reset between pulls inside a keystone. It spanned
-- the whole 24:18 run, and its per-player interrupt counts matched the combat
-- log exactly (26/19/12/9/0). Worse, nothing was harvestable DURING the key at
-- all: the amounts stay secret for the whole restricted map, not merely while
-- in combat, so every between-pull harvest came back secret and zero pulls were
-- recorded across an entire dungeon.
--
-- So a pull is a DIFFERENCE between two readable snapshots of the same session,
-- never a snapshot itself -- otherwise summing pulls counts pull one N times.
-- When the only readable moment is the end of the key, the difference from a
-- nil baseline is the whole key, which is still the right answer.
Meter.baseline = nil
Meter.cumulative = nil  -- true once a session has been seen to accumulate

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

-- Blizzard does not document which field carries the id, and it is not the same
-- in every build, so every reader of this list goes through one place.
local function idOf(entry)
  if entry == nil then return nil end
  if type(entry) ~= "table" then return ns.Plain(entry) end
  return ns.Plain(entry.sessionID or entry.sessionId or entry.id)
end

local function sessionList()
  local C = C_DamageMeter
  if not C or not C.GetAvailableCombatSessions then return {} end
  local ok, list = pcall(C.GetAvailableCombatSessions)
  if not ok or type(list) ~= "table" then return {} end
  return list
end

local function newestSessionID()
  local list = sessionList()
  if #list == 0 then return nil end
  return idOf(list[#list])
end

-- Gotcha 5.
--
-- `which` is a SEGMENT: the string "current", the string "overall", or a table
-- { id = <sessionID> } naming one of Blizzard's own past combat sessions. The
-- id form is what makes the panel's segment dropdown able to show a fight that
-- is already over -- see Meter:Segments.
local function sessionFor(which, attr)
  if not attr or not Meter:Available() then return nil end

  if type(which) == "table" and which.id ~= nil then
    local C = C_DamageMeter
    if not C.GetCombatSessionFromID then return nil end
    local ok, s = pcall(C.GetCombatSessionFromID, which.id, attr)
    -- No by-type fallback here: an id names one specific session and quietly
    -- serving a different one would mislabel every number on screen.
    return ok and s or nil
  end

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
  if not C then return nil end

  -- A session addressed by id is not addressable by GetSessionDurationSeconds,
  -- which takes the enum. Read the clock off the session object instead, and
  -- report nil rather than the Current session's duration under its name.
  if type(which) == "table" and which.id ~= nil then
    local s = sessionFor(which, metric("Interrupts"))
    if type(s) ~= "table" then return nil end
    return ns.Plain(s.durationSeconds or s.duration or s.combatDuration)
  end

  if not C.GetSessionDurationSeconds then return nil end
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

  local idx = { byGuid = {}, byIdentity = {}, countGuid = {}, countIdentity = {}, dupe = {},
                posGuid = {}, posIdentity = {} }
  for i = 1, #list do
    local src = list[i]
    local counts = (not countOnly) or isRealDeath(src)
    local guid = ns.Plain(src.guid)
    local ident = identityOf(src)
    if guid ~= nil then
      if idx.byGuid[guid] == nil then idx.byGuid[guid] = src; idx.posGuid[guid] = i end
      if counts then idx.countGuid[guid] = (idx.countGuid[guid] or 0) + 1 end
    end
    if ident then
      if idx.byIdentity[ident] == nil then idx.byIdentity[ident] = src; idx.posIdentity[ident] = i
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

-- WHERE a row sat in one metric's list.
--
-- This is the only ranking that exists while the amounts are secret, and it is
-- the ranking Blizzard's own meter draws: the API returns combatSources ALREADY
-- SORTED by the metric asked for, so position IS the order. Carrying it per row
-- is what lets a column header sort the panel mid-pull without ever comparing a
-- value the addon is not allowed to read.
local function lookupPos(idx, row)
  if not idx then return nil end
  if row.guid ~= nil and idx.posGuid[row.guid] ~= nil then return idx.posGuid[row.guid] end
  if row.identity and not idx.dupe[row.identity] then return idx.posIdentity[row.identity] end
  return nil
end

local function lookupCount(idx, row)
  if not idx then return nil end
  if row.guid ~= nil and idx.countGuid[row.guid] ~= nil then return idx.countGuid[row.guid] end
  if row.identity and not idx.dupe[row.identity] then return idx.countIdentity[row.identity] or 0 end
  return nil
end

-- ---------------------------------------------------------------------- rows
-- One player, one row -- even when the API hands back several.
--
-- OBSERVED ON A REAL +10 (Voidscar Arena, 2026-10-01): a warlock resummoned his
-- felhunter twice, so its three Spell Locks arrived as THREE rows all named
-- "Maashon" with amount=1 (Pet-0-3779-2923-43290-417-01/02/04...). Blizzard's
-- own meter shows them that way too, so this is upstream shape, not a read bug.
-- Unmerged they ate three of the panel's row slots and pushed the player who
-- actually died off the bottom of the list.
--
-- Merging READS the amounts, so it is only legal when they have gone plain
-- (out of combat). In combat the duplicates stand, exactly as Blizzard draws
-- them.
-- A pet's row is its OWNER's row.
--
-- A warlock does not interrupt; his felhunter does, so Blizzard returns Spell Lock
-- under "Maashon" and the warlock's own row reads 0 kicks. Measured on Voidscar +10:
-- three pet rows for one demon, and the warlock credited nothing.
--
-- The only join available mid-pull is the NAME. A row's guid is a secret value
-- during a pull even when the amounts beside it are plain (observed on that same
-- key), and party pet names are plain reads off a unit token -- so pet name ->
-- owner guid -> owner name is the whole chain. When the owner is not himself on
-- screen there is nothing to fold into, and the pet keeps its own row.
local function petOwnerName(name)
  if name == nil or not ns.Pets then return nil end
  local owner = ns.Pets:OwnerOfName(name)
  if not owner then return nil end
  local p = ns.Kick and ns.Kick.players and ns.Kick.players[owner]
  local ownerName = p and p.name
  if ownerName == nil or ownerName == name then return nil end
  return ownerName
end

local function foldPets(rows)
  local present = {}
  for _, r in ipairs(rows) do if r.name ~= nil then present[r.name] = true end end
  for _, r in ipairs(rows) do
    local owner = petOwnerName(r.name)
    if owner and present[owner] then
      r.isPet = true
      r.petOf = owner
    elseif owner then
      -- The owner has no row of his own, so there is nothing to merge into. Say
      -- whose pet it is rather than leaving a bare demon name in a player list.
      r.isPet = true
      r.name = owner .. " (pet)"
    end
  end
  return rows
end

local function mergeByName(rows)
  local out, at = {}, {}
  for _, r in ipairs(rows) do
    local mergeKey = r.petOf or r.name
    local prior = mergeKey ~= nil and at[mergeKey] or nil
    local mergeable = prior
      and not ns.IsSecret(r.kicks) and not ns.IsSecret(prior.kicks)
      and not ns.IsSecret(r.taken) and not ns.IsSecret(prior.taken)
    if mergeable then
      prior.kicks = (tonumber(prior.kicks) or 0) + (tonumber(r.kicks) or 0)
      prior.taken = (tonumber(prior.taken) or 0) + (tonumber(r.taken) or 0)
      prior.deaths = (tonumber(prior.deaths) or 0) + (tonumber(r.deaths) or 0)
      prior.merged = (prior.merged or 1) + 1
      if r.isPet or prior.isPet then prior.withPet = (prior.withPet or 0) + 1 end
      -- The pet usually arrives FIRST, because the Interrupts list is sorted by
      -- kicks and the demon pressed them all. So whichever row we are keeping, the
      -- identity on it has to end up being the PLAYER's -- otherwise the merged
      -- row renders as "Maashon" with no class colour and no (you) marker.
      if prior.isPet and not r.isPet then
        prior.name, prior.guid, prior.identity = r.name, r.guid, r.identity
        prior.class, prior.isYou, prior.rank = r.class, r.isYou, r.rank
        prior.isPet, prior.petOf = nil, nil
      end
    else
      -- Could not merge -- the amounts are still secret. A pet row therefore
      -- stands on its own this pull, so it must at least read as the owner's.
      if r.petOf then r.name = r.petOf .. " (pet)" end
      out[#out + 1] = r
      if mergeKey ~= nil and prior == nil then at[mergeKey] = r end
    end
  end
  return out
end

-- One row per player who was there -- the union of the actors in every metric we
-- show, not just the sorted one. A healer who kicked nothing still belongs on
-- screen, with a zero, or the panel is reporting "who scored" and not "who was
-- in the group".
--
-- Order comes from the Interrupts list, because the API returns it ALREADY
-- SORTED by the metric asked for and list position is the only ranking that
-- exists when the amounts cannot be compared.
-- A drill-down key that does NOT come from C_DamageMeter.
--
-- MEASURED, 2026-10-01 (Voidscar Arena +10, /uk audit): a row's `guid` comes
-- back SECRET even after the key ended, with the name and totals beside it
-- plain. So Kickable keyed on row.guid could never run once -- the column has
-- never produced a number on a live client, in any dungeon, regardless of how
-- much interruptibility data we had.
--
-- But a party member's GUID is not this API's to withhold: UnitGUID("player")
-- and ("party1".."party4") are ordinary unit API. So resolve the key from the
-- UNIT and join it to the row on the only fields that stay readable --
-- isLocalPlayer (NeverSecret) and the name. ns.GUID drops an unreadable one, so
-- a restricted map degrades to nil rather than erroring.
local function baseName(n)
  return type(n) == "string" and (n:match("^([^-]+)") or n) or nil
end

local function unitGUIDFor(row)
  if row.isYou then return ns.GUID("player") end
  local want = baseName(row.name)
  if not want then return nil end
  if type(GetNumGroupMembers) ~= "function" or type(UnitName) ~= "function" then return nil end
  local n = (GetNumGroupMembers() or 0) - 1      -- party1..partyN-1, player excluded
  for i = 1, math.max(0, n) do
    local unit = "party" .. i
    if baseName(UnitName(unit)) == want then return ns.GUID(unit) end
  end
  return nil
end

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
    -- A player absent from a metric's list scored nothing in it -- but only say
    -- so when the join was DEFINITIVE. A guid match is; an identity match that
    -- collided is not, and a blank cell beats a confident wrong zero. On the
    -- real key this is why the local player's kick count was blank instead of 0:
    -- he genuinely pressed none, so he was not in the Interrupts list at all.
    local definite = row.guid ~= nil
    row.kicks = k and k.totalAmount or (definite and iKicks and 0 or nil)
    row.taken = t and t.totalAmount or (definite and iTaken and 0 or nil)
    local d = lookupCount(iDeaths, row)
    row.deaths = d or (definite and iDeaths and 0 or nil)
    -- Rank, not value: usable in combat, when the value is not.
    row.rank = { kicks = lookupPos(iKicks, row), taken = lookupPos(iTaken, row) }
    if ns.IsSecret(row.kicks) or ns.IsSecret(row.taken) then secret = true end
    row.unitGUID = unitGUIDFor(row)
  end

  return mergeByName(foldPets(rows)), not secret
end

-- ------------------------------------------------------------------- sorting
-- Sorting a table of numbers the addon is not allowed to read.
--
-- Out of combat the amounts are plain and this is an ordinary table.sort. During
-- a pull they are secret: comparing two of them is not merely wrong, it errors.
-- So there is a second ordering that needs no comparison at all -- the POSITION
-- each row held in its metric's list, which Blizzard returns already sorted by
-- that metric. Reversing a list of positions is still not reading a value, so
-- ascending works mid-pull too.
--
-- Three columns, three answers:
--   kicks / taken  -- value when plain, list position when secret
--   died           -- always sortable: it is a count of rows, never an amount
--   kickable       -- plain by construction (derived from the drill-down), so it
--                     simply has nothing to sort during a pull
--   name           -- a name can be secret independently of the numbers beside
--                     it (observed on the Voidscar +10), so it is refused
--                     rather than guessed at
Meter.COLUMNS = {
  { key = "name",     label = "who",      field = "name" },
  { key = "kicks",    label = "kicks",    field = "kicks", rank = "kicks" },
  { key = "died",     label = "died",     field = "deaths" },
  { key = "taken",    label = "taken",    field = "taken", rank = "taken" },
  { key = "kickable", label = "kickable", field = "kickable" },
}

local COL = {}
for _, c in ipairs(Meter.COLUMNS) do COL[c.key] = c end

function Meter:Column(key) return COL[key or ""] end

-- The stored sort, with the default being the order the panel has always had:
-- the Interrupts list, which is kicks descending.
function Meter:SortSpec()
  local s = ns.db and ns.db.sort
  local by = (s and COL[s.by or ""] and s.by) or "kicks"
  local desc = true
  if s and s.desc == false then desc = false end
  return by, desc
end

local function plainNumber(v)
  if v == nil then return nil, true end
  if ns.IsSecret(v) then return nil, false end
  return tonumber(v), true
end

-- Returns rows, applied, note. `rows` is always a fresh list, so a stored pull
-- never has its own order rewritten underneath it.
function Meter:Sort(rows, by, desc)
  local out, ord = {}, {}
  for i, r in ipairs(rows or {}) do out[i] = r; ord[r] = i end
  local function stable(a, b) return (ord[a] or 0) < (ord[b] or 0) end

  local col = COL[by or ""]
  if not col then return out, false, "no such column" end
  if #out < 2 then return out, true end

  if col.key == "name" then
    for _, r in ipairs(out) do
      if r.name == nil or ns.IsSecret(r.name) then
        return out, false, "a name here is not readable yet"
      end
    end
    table.sort(out, function(a, b)
      local x, y = tostring(a.name):lower(), tostring(b.name):lower()
      if x == y then return stable(a, b) end
      if desc then return x > y end
      return x < y
    end)
    return out, true
  end

  local value, readable, any = {}, true, false
  for _, r in ipairs(out) do
    local v, ok = plainNumber(r[col.field])
    if not ok then readable = false; break end
    if v ~= nil then any = true end
    value[r] = v
  end

  -- A column that is empty for every row cannot order anything, and an arrow
  -- over it would claim an order the rows are not in. kickable is the real case:
  -- it is derived from the per-spell drill-down, which cannot run during a pull.
  if readable and not any then
    return out, false, (col.label .. " is empty -- nothing to order by")
  end

  if readable then
    table.sort(out, function(a, b)
      -- A player absent from a metric scored nothing in it, so nil sorts with
      -- the zeroes rather than jumping to the top.
      local x = value[a] or -math.huge
      local y = value[b] or -math.huge
      if x == y then return stable(a, b) end
      if desc then return x > y end
      return x < y
    end)
    return out, true
  end

  if not col.rank then
    return out, false, (col.label .. " has no value until the pull ends")
  end

  table.sort(out, function(a, b)
    -- Position 1 is the TOP of a descending list, so descending == ascending
    -- rank. A row missing from this metric's list goes last either way.
    local x = (a.rank and a.rank[col.rank]) or math.huge
    local y = (b.rank and b.rank[col.rank]) or math.huge
    if x == y then return stable(a, b) end
    if desc then return x < y end
    return x > y
  end)
  return out, true, "by list position -- the amounts cannot be read in combat"
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
  if guid == nil then return nil end
  local spells = self:Spells(which, guid, nil, "DamageTaken")
  if not spells then return nil end

  local total, by = 0, {}
  for i = 1, #spells do
    local sp = spells[i]
    local id = ns.Plain(sp.spellID)
    local amount = tonumber(ns.Plain(sp.totalAmount))
    if id and amount and ns.IsKickable(id) == true then
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
    -- row.unitGUID first: the row's own guid is secret on a live client (see
    -- unitGUIDFor), so without the unit-token key this is always nil.
    r.kickable, r.kickableBy = self:Kickable(which, row.unitGUID or row.guid)
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
-- MEASURED, 2026-10-01, Voidscar Arena +10: `src.guid` came back SECRET even
-- after the key ended and the amounts beside it had gone plain again -- /uk
-- audit printed readable names and readable totals on rows whose guid was still
-- unreadable. So "wait until out of combat and the guid will be plain" is false,
-- and a drill-down gated on a plain guid can never run at all.
--
-- Handing the secret straight back is the only remaining move. Research says it
-- raises "Secret values are only allowed during untainted execution", so it is
-- pcall'd and the refusal is COUNTED rather than swallowed -- if it ever starts
-- working, /uk audit says so, and if it never does, the audit says that too
-- instead of the kickable column silently staying blank forever.
Meter.secretGuidRefusals = 0

function Meter:Spells(which, guid, creatureID, attrName)
  local attr = metric(attrName or "Interrupts")
  if not attr or guid == nil then return nil end
  -- There is no by-id drill-down in the API, only by session TYPE. Serving the
  -- Current session's spells under a past session's label would be a lie, so a
  -- segment addressed by id has no breakdown at all.
  if type(which) == "table" then return nil end
  local value = sessionValue(which)
  if value == nil then return nil end
  local ok, container = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
    value, attr, guid, creatureID)
  if not ok then
    if ns.IsSecret(guid) then self.secretGuidRefusals = self.secretGuidRefusals + 1 end
    return nil
  end
  if not container then return nil end
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
  -- kickable starts nil, NOT 0. A hard zero is a claim that nothing the party
  -- ate was interruptible; nil is "we never got a figure". The per-spell
  -- drill-down needs a readable guid, which 12.x never gives us, so every
  -- harvested pull has carried nil -- and summing those into 0 rendered the
  -- column as a measured zero in the run view while the live view, which
  -- computes nothing at all, rendered it blank. Same unknown, two answers.
  local total = { rows = {}, kicks = 0, deaths = 0, taken = 0, kickable = nil,
                  duration = 0, pulls = #self.pulls }

  for _, pull in ipairs(self.pulls) do
    total.duration = total.duration + (pull.duration or 0)
    for _, r in ipairs(pull.rows) do
      local key = r.name or r.identity or tostring(r)
      local acc = byKey[key]
      if not acc then
        acc = { name = r.name, class = r.class, isYou = r.isYou,
                kicks = 0, taken = 0, deaths = 0, kickable = nil }
        byKey[key] = acc
        order[#order + 1] = acc
      end
      acc.kicks = acc.kicks + r.kicks
      acc.taken = acc.taken + r.taken
      acc.deaths = acc.deaths + r.deaths
      if r.kickable then acc.kickable = (acc.kickable or 0) + r.kickable end
    end
  end

  for _, acc in ipairs(order) do
    total.kicks = total.kicks + acc.kicks
    total.deaths = total.deaths + acc.deaths
    total.taken = total.taken + acc.taken
    if acc.kickable then total.kickable = (total.kickable or 0) + acc.kickable end
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

-- --------------------------------------------------------------- diagnostics
-- Prints the raw shape of each metric list rather than our interpretation of
-- it, because the one discrepancy we cannot resolve offline (deaths) could live
-- on either side of the join.
function Meter:Audit()
  if not self:Available() then ns.Print("no damage meter on this client"); return end
  ns.Print("raw C_DamageMeter rows (current session):")
  for _, name in ipairs({ "Interrupts", "DamageTaken", "Deaths" }) do
    local attr = metric(name)
    local s = attr and sessionFor("current", attr)
    local list = s and s.combatSources
    if not list then
      print(("  %-12s no list"):format(name))
    else
      print(("  %-12s %d rows"):format(name, #list))
      -- The field names themselves, once per metric: if the identifier this
      -- code wants is simply spelled something other than `guid`, nothing else
      -- in this dump would ever reveal it.
      if list[1] then
        local keys = {}
        for k in pairs(list[1]) do keys[#keys + 1] = k end
        table.sort(keys)
        print("      fields: " .. table.concat(keys, ", "))
      end
      for i = 1, #list do
        local src = list[i]
        local n = ns.Plain(src.name)
        -- nil and secret are DIFFERENT diagnoses: nil means the field is not
        -- called `guid` at all, secret means it exists and may not be read.
        local g = src.guid == nil and "<absent>"
          or (ns.IsSecret(src.guid) and "<secret>" or "plain")
        print(("    [%d] %s guid=%s recap=%s amount=%s"):format(
          i, tostring(n or "<secret>"), g,
          tostring(ns.Plain(src.deathRecapID)),
          ns.IsSecret(src.totalAmount) and "<secret>" or tostring(ns.Plain(src.totalAmount))))
      end
    end
  end
  local counted = self:KeyDeaths()
  ns.Print("key death counter: %s; pulls harvested: %d; harvests refused by secrets: %d",
    tostring(counted), #self.pulls, self.blockedHarvests or 0)
  ns.Print("drill-downs refused for a secret guid: %d (kickable column needs these)",
    self.secretGuidRefusals or 0)
end

function Meter:Clock(s)
  s = math.floor(tonumber(s) or 0)
  return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

-- --------------------------------------------------------------- segments
-- What the panel's dropdown offers, in the order it offers it.
--
-- Four kinds, and they come from genuinely different places:
--
--   live    -- C_DamageMeter's Current session. Inside a key this is the KEY SO
--              FAR, not the pull in progress: measured on a real +13 it spanned
--              the whole 24:18 run, because secrets lift when you leave the
--              restricted map and not when you leave combat.
--   run     -- our own keystone total, summed from the harvested pulls, so it
--              agrees with the offline parser's --overall for the same key.
--   pull    -- one harvested pull, i.e. the difference between two readable
--              snapshots. These are the "past pulls" worth selecting. Inside a
--              key there is usually exactly ONE of them, arriving at
--              CHALLENGE_MODE_COMPLETED and covering the whole run, for the
--              reason above -- so a key with ten packs in it can still offer a
--              single pull entry. That is a client restriction, not a gap here.
--   session -- one of Blizzard's own past combat sessions, by id. Out in the
--              world each fight gets its own session and the amounts are plain,
--              so these are real selectable past combats. They carry no
--              per-spell drill-down (there is no by-id variant of it), so the
--              kickable column is blank on them.
local function segmentKey(kind, n)
  if kind == "pull" then return "pull:" .. tostring(n) end
  if kind == "session" then return "session:" .. tostring(n) end
  return kind == "run" and "overall" or "current"
end

-- Parses a stored key back into a kind. Unrecognised keys -- including a
-- "pull:7" left in SavedVariables after the pulls were wiped -- read as live,
-- which is the one segment that always exists.
function Meter:ParseSegment(key)
  if type(key) ~= "string" then return "live" end
  local n = key:match("^pull:(%d+)$")
  if n then return "pull", tonumber(n) end
  local id = key:match("^session:(.+)$")
  if id then return "session", tonumber(id) or id end
  if key == "overall" then return "run" end
  return "live"
end

-- The live segment's own name, which depends entirely on whether a key is open.
function Meter:LiveLabel()
  local clock = self:Clock(self:Duration("current") or 0)
  if not self.run then return ("session  %s  (no key)"):format(clock) end
  if self.run.endedAt then return ("key total  %s"):format(clock) end
  return ("key so far  %s"):format(clock)
end

function Meter:Segments()
  local out = {}
  out[#out + 1] = { key = "current", kind = "live", label = self:LiveLabel() }

  local total = self:Total()
  out[#out + 1] = {
    key = "overall", kind = "run",
    label = total
      and ("run  %s  %d pulls"):format(self:Clock(total.duration), total.pulls)
      or "run  no pulls yet",
    empty = (total == nil) or nil,
  }

  for i, pull in ipairs(self.pulls) do
    out[#out + 1] = {
      key = segmentKey("pull", i), kind = "pull", index = i,
      -- A pull flagged wholeRun IS the key: calling it "pull 1" is the exact lie
      -- R-20 was about.
      label = ("%s  %s  %d kicks"):format(
        pull.wholeRun and "whole key" or ("pull " .. i),
        self:Clock(pull.duration or 0), pull.kicks or 0),
    }
  end

  -- Newest first: the fight you just finished is the one you want to look at.
  local list = sessionList()
  for i = #list, 1, -1 do
    local id = idOf(list[i])
    if id ~= nil then
      local secs = self:Duration({ id = id })
      out[#out + 1] = {
        key = segmentKey("session", id), kind = "session", id = id,
        label = ("combat %d%s"):format(i, secs and ("  " .. self:Clock(secs)) or ""),
      }
    end
  end
  return out
end

function Meter:SegmentLabel(key)
  for _, seg in ipairs(self:Segments()) do
    if seg.key == key then return seg.label, seg end
  end
  return nil
end

-- Resolve a segment key to rows the panel can draw.
--
-- Returns rows, plain, label, kind -- or nil when the key names something that
-- no longer exists (a pull from a key that has since been reset, a session
-- Blizzard has expired). nil is the signal to fall back to the live segment and
-- SAY so, rather than drawing an empty table under a stale heading.
function Meter:View(key)
  local kind, n = self:ParseSegment(key)

  if kind == "pull" then
    local pull = self.pulls[n]
    if not pull then return nil end
    -- A harvested pull is plain by construction: it only exists because the
    -- values were readable at the moment it was taken.
    return pull.rows, true,
      ("%s  %s"):format(pull.wholeRun and "whole key" or ("pull " .. n),
        self:Clock(pull.duration or 0)), kind
  end

  if kind == "session" then
    local rows, plain = self:Rows({ id = n })
    if not rows then return nil end
    -- Take the label from the dropdown's own list so the heading and the entry
    -- that selected it read the same -- the list numbers sessions by position
    -- because the raw id is not a thing a player recognises.
    local label = self:SegmentLabel(key)
    if not label then
      local secs = self:Duration({ id = n })
      label = ("combat %s%s"):format(tostring(n), secs and ("  " .. self:Clock(secs)) or "")
    end
    return rows, plain ~= false, label, kind
  end

  if kind == "run" then
    local total = self:Total()
    if not total then return {}, true, "run  no pulls yet", kind end
    return total.rows, true,
      ("run  %s  %d pulls"):format(self:Clock(total.duration), total.pulls), kind
  end

  local rows, plain = self:Rows("current")
  return rows or {}, plain ~= false, self:LiveLabel(), "live"
end

-- A snapshot is cumulative; a pull is the difference between two of them.
-- Returns nil when nothing happened between the two.
local function rowKey(r) return r.name or r.identity or tostring(r) end

local function diffSnapshot(snap, base)
  if not base then return snap end
  -- A session that went BACKWARDS is a different session (a meter reset, or
  -- Blizzard opening a fresh one). Diffing against it would give negatives, so
  -- the snapshot stands on its own.
  if (snap.duration or 0) < (base.duration or 0)
    or snap.kicks < base.kicks or snap.taken < base.taken or snap.deaths < base.deaths then
    return snap
  end
  Meter.cumulative = true

  local was = {}
  for _, r in ipairs(base.rows) do was[rowKey(r)] = r end

  local out = { rows = {}, duration = (snap.duration or 0) - (base.duration or 0),
                kicks = 0, deaths = 0, taken = 0, kickable = 0 }
  for _, r in ipairs(snap.rows) do
    local b = was[rowKey(r)]
    local d = {
      name = r.name, class = r.class, isYou = r.isYou, identity = r.identity,
      kicks = r.kicks - (b and b.kicks or 0),
      taken = r.taken - (b and b.taken or 0),
      deaths = r.deaths - (b and b.deaths or 0),
      kickable = (r.kickable or 0) - (b and b.kickable or 0),
    }
    -- Per-spell kickable breakdowns are cumulative too and cannot be subtracted
    -- meaningfully, so a delta carries the total only.
    out.kicks = out.kicks + d.kicks
    out.taken = out.taken + d.taken
    out.deaths = out.deaths + d.deaths
    out.kickable = out.kickable + d.kickable
    out.rows[#out.rows + 1] = d
  end
  return out
end

-- ------------------------------------------------------------------- harvest
-- Values go plain when the RESTRICTION lifts, which on a dungeon map is not the
-- same thing as combat ending -- on a real +13 nothing was readable until the
-- key itself was over. So this tries, retries, and simply records nothing if the
-- map never lets go; the end-of-key harvest then captures the whole run at once.
local HARVEST_TRIES = 4
local HARVEST_GAP = 0.75

local function harvest(try)
  if not Meter.run then return end
  local snap = Meter:Snapshot("current")
  if not snap then
    Meter.blockedHarvests = (Meter.blockedHarvests or 0) + 1
    if try < HARVEST_TRIES and C_Timer and C_Timer.After then
      C_Timer.After(HARVEST_GAP, function() harvest(try + 1) end)
    end
    return
  end

  local pull = diffSnapshot(snap, Meter.baseline)
  Meter.baseline = snap

  -- A pull nobody did anything in is not a pull. Keeps the numbering stable
  -- enough to say out loud, the same rule the offline parser uses.
  if pull.kicks == 0 and pull.taken == 0 and pull.deaths == 0 then return end

  pull.index = #Meter.pulls + 1
  -- The honest name for "the first thing we could read was the finished key".
  pull.wholeRun = (pull == snap and Meter.run.endedAt ~= nil) or nil
  Meter.pulls[pull.index] = pull

  if ns.db and ns.db.pullReport then Meter:Announce(pull) end
  if ns.Panel then ns.Panel:Refresh() end

  -- The key may already be over by the time anything became readable. Report
  -- when the numbers actually arrive rather than at a fixed delay that was too
  -- early.
  if Meter.run.endedAt and not Meter.run.reported then
    Meter.run.reported = true
    Meter:Report()
  end
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
  Meter.baseline = nil
  Meter.run = { level = level, mapName = mapName or (GetInstanceInfo and GetInstanceInfo()) or nil,
                startedAt = GetTime() }
  if ns.Panel then ns.Panel:Refresh() end
end

ns.On("CHALLENGE_MODE_START", startRun)

ns.On("CHALLENGE_MODE_COMPLETED", function()
  if not Meter.run then return end
  Meter.run.endedAt = GetTime()
  -- Completing the key is usually the first moment the amounts are readable at
  -- all, so harvest before reporting -- and let the harvest itself report if it
  -- lands later still, rather than printing "no pulls recorded" on a timer.
  harvest(1)
  if not Meter.run.reported and #Meter.pulls > 0 then
    Meter.run.reported = true
    Meter:Report()
  end
end)

ns.On("CHALLENGE_MODE_RESET", function()
  Meter.pulls = {}; Meter.run = nil; Meter.baseline = nil
end)

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
