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
-- What the column can be asked to show.
--
-- "damage" is what it has always shown, and the question that prompted this was
-- why it is not a count of casts instead. The honest answer is that the API's
-- per-spell row has no count of any kind in it: DamageMeterCombatSpell is
-- spellID, totalAmount, amountPerSecond, creatureName, overkillAmount,
-- isAvoidable, isDeadly, combatSpellDetails -- checked against the documented
-- struct on 2026-10-03, and against whatever the live client actually returns by
-- /uk audit, which now prints the field names of a damage row for exactly this
-- reason.
--
-- So "casts" is offered, is read from a count field if the client turns out to
-- have one under any of the names a count could plausibly carry, and renders a
-- dash with its reason when it does not -- rather than being left off the menu
-- on the strength of a documentation page. The number of MISSED casts stays the
-- parser's answer either way; the panel can only ever report what landed.
--
-- "spells" is the count that IS reachable: how many different proven-
-- interruptible spells hit that player. It is not a cast count and is not
-- labelled as one.
Meter.KICKABLE_MODES = {
  { key = "damage",   label = "kickable", field = "damage",
    note = "damage taken from spells proven interruptible" },
  { key = "casts",    label = "kickable", field = "casts",
    note = "casts of those spells -- only if the client reports a count" },
  { key = "spells",   label = "kickable", field = "spells",
    note = "how many different interruptible spells hit them" },
  { key = "overkill", label = "overkill", field = "overkill",
    note = "overkill from those spells -- what actually killed someone" },
  { key = "off",      label = "", field = false,
    note = "hide the column entirely" },
}

local KMODE = {}
for _, m in ipairs(Meter.KICKABLE_MODES) do KMODE[m.key] = m end

function Meter:KickableMode()
  local want = ns.db and ns.db.kickableShow
  return KMODE[want or ""] or KMODE.damage
end

function Meter:SetKickableMode(key)
  if not KMODE[key or ""] then return nil end
  ns.db.kickableShow = key
  return KMODE[key]
end

-- Every name a cast count could plausibly be spelled, tried in order. Documented
-- fields first; the rest exist because the struct page is not the client.
local COUNT_FIELDS = { "count", "castCount", "hitCount", "casts", "hits", "numCasts", "numHits" }

local function countOf(sp)
  for _, f in ipairs(COUNT_FIELDS) do
    local v = tonumber(ns.Plain(sp[f]))
    if v then return v end
  end
  local d = sp.combatSpellDetails
  if type(d) == "table" then
    for _, f in ipairs(COUNT_FIELDS) do
      local v = tonumber(ns.Plain(d[f]))
      if v then return v end
    end
  end
  return nil
end

-- Returns value, by, stats, why.
--   value  -- the figure for the CURRENT mode, or nil when that mode has none
--   by     -- per-spell breakdown, for the tooltip
--   stats  -- every mode's figure, so the picker can say which ones are live
--   why    -- a reason code when there is no value, so a blank column can say
--             which of six different things happened instead of the footer
--             asserting "none of the known casts hit anyone", which is a
--             measurement, and was being claimed on a view that never measured.
function Meter:Kickable(which, guid)
  if guid == nil then return nil, nil, nil, "no-unit" end
  local spells, why = self:Spells(which, guid, nil, "DamageTaken")
  if not spells then return nil, nil, nil, why or "no-spells" end
  -- An EMPTY list is not a failure. The call succeeded and the answer is that
  -- nothing hit this player, which is a measured zero and renders as one.

  -- Whether a count field exists is a property of the CLIENT, so it is settled
  -- from every spell row in the list, not only the interruptible ones -- a pull
  -- where nothing kickable landed would otherwise say nothing about whether the
  -- "casts" mode can ever work.
  local sawCount = false
  for i = 1, #spells do
    if countOf(spells[i]) then sawCount = true; break end
  end
  -- An empty list says nothing about whether this client reports counts, so it
  -- must not be allowed to answer the question either way.
  if #spells > 0 then self.noCastCount = not sawCount end

  local stats = { damage = 0, spells = 0, overkill = 0 }
  if sawCount then stats.casts = 0 end

  local by = {}
  for i = 1, #spells do
    local sp = spells[i]
    local id = ns.Plain(sp.spellID)
    local amount = tonumber(ns.Plain(sp.totalAmount))
    if id and amount and ns.IsKickable(id) == true then
      local n = countOf(sp)
      local over = tonumber(ns.Plain(sp.overkillAmount)) or 0
      if n then stats.casts = (stats.casts or 0) + n end
      stats.damage = stats.damage + amount
      stats.spells = stats.spells + 1
      stats.overkill = stats.overkill + over
      by[#by + 1] = { spellID = id, amount = amount, casts = n, overkill = over }
    end
  end

  -- A drill-down that RAN and matched nothing is a measured zero, and stays a
  -- zero: R-34 cuts both ways. Only "we never got a figure" is blank.
  table.sort(by, function(a, b) return a.amount > b.amount end)

  local mode = self:KickableMode()
  if not mode.field then return nil, by, stats, "off" end
  local value = stats[mode.field]
  if value == nil then return nil, by, stats, "no-count" end
  return value, by, stats, nil
end

-- Set the moment any drill-down finds a spell row with no count field on it, so
-- the "casts" mode can be offered and then honestly marked unavailable rather
-- than silently showing nothing.
Meter.noCastCount = false

-- Summing two stats tables while keeping "never measured" distinct from zero:
-- a field absent on both sides stays absent, so a column nobody could measure
-- renders blank rather than as a confident 0 (R-34).
local STAT_FIELDS = { "damage", "casts", "spells", "overkill" }

function Meter.AddStats(into, add)
  if not add then return into end
  into = into or {}
  for _, f in ipairs(STAT_FIELDS) do
    if add[f] ~= nil then into[f] = (into[f] or 0) + add[f] end
  end
  return into
end
local addStats = Meter.AddStats

-- The figure this row should show for the column's current mode, or nil when
-- that mode has no answer for it. Rows stored by an older build carry only the
-- damage figure, so that one still resolves from the legacy field.
function Meter:KickValue(row)
  local mode = self:KickableMode()
  if not row or not mode.field then return nil end
  local st = row.kick
  if st and st[mode.field] ~= nil then return st[mode.field] end
  if not st and mode.field == "damage" then return row.kickable end
  return nil
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
    -- The whole stats table, not just the damage figure: the column's mode can
    -- be changed after a key is over, and a pull that stored only one of the
    -- four answers would go blank the moment the player asked for another.
    local _, by, stats = self:Kickable(which, row.unitGUID or row.guid)
    r.kickableBy, r.kick = by, stats
    r.kickable = stats and stats.damage or nil
    if r.kickable then out.kickable = (out.kickable or 0) + r.kickable end
    if stats then out.kick = addStats(out.kick, stats) end
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
  if not attr then return nil, "no-metric" end
  if guid == nil then return nil, "no-unit" end
  -- There is no by-id drill-down in the API, only by session TYPE. Serving the
  -- Current session's spells under a past session's label would be a lie, so a
  -- segment addressed by id has no breakdown at all.
  if type(which) == "table" then return nil, "by-id" end
  local value = sessionValue(which)
  if value == nil then return nil, "no-session" end
  local ok, container = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
    value, attr, guid, creatureID)
  if not ok then
    if ns.IsSecret(guid) then
      self.secretGuidRefusals = self.secretGuidRefusals + 1
      return nil, "secret-guid"
    end
    return nil, "refused"
  end
  if not container then return nil, "no-source" end
  if not container.combatSpells then return nil, "no-spells" end
  return container.combatSpells
end

-- Plain English for each reason code, for the one line under the table. Keyed
-- so the panel never has to carry the reasoning itself.
Meter.KICKABLE_WHY = {
  ["no-unit"]     = "cannot match a panel row to a party unit",
  ["no-metric"]   = "this client has no DamageTaken metric",
  ["by-id"]       = "a past session has no per-spell breakdown in the API",
  ["no-session"]  = "no readable session to drill into",
  ["secret-guid"] = "the API will not name a player's spells (guid is secret)",
  ["refused"]     = "the per-spell call was refused",
  ["no-source"]   = "nobody took damage in this segment",
  ["no-spells"]   = "the drill-down returned no spell list",
  ["empty"]       = "nobody took damage in this segment",
  ["no-match"]    = "none of the %d known interruptible casts hit anyone",
  ["no-count"]    = "this client reports no cast count -- parse the log for casts",
  ["off"]         = "column hidden",
  ["not-live"]    = "only a live segment can drill down per spell",
  ["in-combat"]   = "lands when the pull ends -- the amounts are secret in combat",
  ["stored"]      = "this segment was stored without one -- the live view measures it",
}

-- ------------------------------------------------------------- the run ledger
-- The run total is the sum of the pulls inside the keystone window, deliberately
-- -- not the Overall session, which spans everything since login including the
-- target dummy you hit in the city. Same window the offline parser reports on,
-- so the two agree.
-- TotalOf, not Total: the same arithmetic has to serve a run restored from
-- SavedVariables (R-37) as serves the one in memory, and a stored run's pulls
-- are plain by construction exactly as a freshly harvested one's are.
function Meter:TotalOf(pulls)
  pulls = pulls or {}
  if #pulls == 0 then return nil end
  local byKey, order = {}, {}
  -- kickable starts nil, NOT 0. A hard zero is a claim that nothing the party
  -- ate was interruptible; nil is "we never got a figure". The per-spell
  -- drill-down needs a readable guid, which 12.x never gives us, so every
  -- harvested pull has carried nil -- and summing those into 0 rendered the
  -- column as a measured zero in the run view while the live view, which
  -- computes nothing at all, rendered it blank. Same unknown, two answers.
  local total = { rows = {}, kicks = 0, deaths = 0, taken = 0, kickable = nil,
                  duration = 0, pulls = #pulls }

  for _, pull in ipairs(pulls) do
    total.duration = total.duration + (pull.duration or 0)
    for _, r in ipairs(pull.rows) do
      local key = r.name or r.identity or tostring(r)
      local acc = byKey[key]
      if not acc then
        acc = { name = r.name, class = r.class, isYou = r.isYou,
                kicks = 0, taken = 0, deaths = 0, kickable = nil, kick = nil }
        byKey[key] = acc
        order[#order + 1] = acc
      end
      acc.kicks = acc.kicks + r.kicks
      acc.taken = acc.taken + r.taken
      acc.deaths = acc.deaths + r.deaths
      if r.kickable then acc.kickable = (acc.kickable or 0) + r.kickable end
      if r.kick then acc.kick = addStats(acc.kick, r.kick) end
    end
  end

  for _, acc in ipairs(order) do
    total.kicks = total.kicks + acc.kicks
    total.deaths = total.deaths + acc.deaths
    total.taken = total.taken + acc.taken
    if acc.kickable then total.kickable = (total.kickable or 0) + acc.kickable end
    if acc.kick then total.kick = addStats(total.kick, acc.kick) end
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

function Meter:Total() return self:TotalOf(self.pulls) end

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

  -- The question this answers: the documented DamageMeterCombatSpell has no
  -- count field of any kind, so "show casts instead of damage" has no source in
  -- the API. The struct page is not the client, though, so dump what a real
  -- damage row actually carries and let the next run settle it rather than the
  -- column being left off the menu on the strength of a wiki table.
  ns.Print("per-spell drill-down (DamageTaken) -- does a cast count exist?")
  local sawAny = false
  for i = 0, 4 do
    local unit = (i == 0) and "player" or ("party" .. i)
    local guid = ns.GUID(unit)
    if guid ~= nil then
      local spells, why = self:Spells("current", guid, nil, "DamageTaken")
      if not spells then
        print(("    %-7s no spell list: %s"):format(unit, tostring(why)))
      else
        sawAny = true
        print(("    %-7s %d spell(s)"):format(unit, #spells))
        if spells[1] then
          local keys = {}
          for k in pairs(spells[1]) do keys[#keys + 1] = k end
          table.sort(keys)
          print("      fields: " .. table.concat(keys, ", "))
          local d = spells[1].combatSpellDetails
          if type(d) == "table" then
            local dk = {}
            for k in pairs(d) do dk[#dk + 1] = k end
            table.sort(dk)
            print("      combatSpellDetails: " .. table.concat(dk, ", "))
          end
        end
      end
    end
  end
  if sawAny then
    ns.Print("cast count found on a spell row: %s", self.noCastCount and "NO" or "yes")
  end
end

function Meter:Clock(s)
  s = math.floor(tonumber(s) or 0)
  return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

-- ----------------------------------------------------- persistence (R-37)
-- Harvested pulls used to die with the session. Meter.pulls is a plain Lua
-- table and UnkickedDB held nothing but settings, so logging out to update the
-- addon threw away a finished key's whole report -- which is exactly what
-- happened on the Ruby Life Pools +10 -- and left the dropdown with nothing but
-- the live segment on the next login.
--
-- They persist now, under four rules. The rules ARE the feature: a stored report
-- that is subtly wrong is worse than one that was never stored, because it
-- cannot be told apart from a measured one.
--
-- 1) NOTHING SECRET IS EVER WRITTEN. A pull only exists because Snapshot() found
--    every value readable, but SavedVariables is the one boundary where a secret
--    would be serialised to a file and read back next login as an ordinary
--    number -- an invented fact, indistinguishable from a measured one forever
--    after. So every field is re-checked through ns.Plain on the way out, and
--    anything that is not a plain finite number or string is dropped.
-- 2) THE SCHEMA IS VERSIONED, AND A VERSION WE DO NOT KNOW IS DISCARDED. Not
--    half-read: a renamed field read as nil would report zeroes for a key that
--    really happened.
-- 3) A RESTORED PULL IS NEVER COUNTED TWICE. The baseline snapshot is stored
--    beside the run, so a /reload mid-key resumes with it; and diffSnapshot's
--    own backwards-check means a fresh post-reload session, which starts from
--    zero, is taken whole instead of subtracted from last login's larger
--    numbers. Double-counting is the one corruption this file already knew how
--    to detect.
-- 4) A RESTORED RUN IS NEVER TREATED AS LIVE. It resumes only while the client
--    says that keystone is still running; otherwise it goes to the history,
--    where nothing harvests into it.
local HISTORY_VERSION = 1
local MAX_RUNS = 5    -- keys kept across logins
local MAX_PULLS = 30  -- pulls kept per key
local MAX_ROWS = 10   -- rows kept per pull (a party is five, a pet makes six)

local function epoch()
  -- time() is the wall clock and survives a login; GetTime() is uptime and does
  -- not, so a stored run is stamped with the former.
  local t = rawget(_G, "time")
  local v = type(t) == "function" and tonumber(t()) or nil
  return v or 0
end

local function numOut(v)
  v = tonumber(ns.Plain(v))
  -- nan and inf serialise as something Lua cannot read back.
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

local function strOut(v)
  v = ns.Plain(v)
  if type(v) ~= "string" then return nil end
  return v:sub(1, 48)
end

-- Field by field, and only the fields that are actually there: a stats table
-- written with zeroes for the modes nobody measured would come back next login
-- indistinguishable from a measured zero, which is the one thing the file
-- boundary must not do.
local function statsOut(st)
  if type(st) ~= "table" then return nil end
  local out, any = {}, false
  for _, f in ipairs(STAT_FIELDS) do
    local v = numOut(st[f])
    if v ~= nil then out[f] = v; any = true end
  end
  return any and out or nil
end
local statsIn = statsOut

local function rowOut(r)
  return {
    name = strOut(r.name), class = strOut(r.class), identity = strOut(r.identity),
    isYou = (r.isYou == true) or nil,
    kicks = numOut(r.kicks) or 0,
    deaths = numOut(r.deaths) or 0,
    taken = numOut(r.taken) or 0,
    -- Stays nil when it was never measured: R-34 is that an unmeasured kickable
    -- figure must not come back as a confident zero, and a round trip through a
    -- file is the easiest place to lose that distinction.
    kickable = numOut(r.kickable),
    kick = statsOut(r.kick),
  }
end

local function pullOut(p)
  local out = {
    duration = numOut(p.duration) or 0,
    kicks = numOut(p.kicks) or 0,
    deaths = numOut(p.deaths) or 0,
    taken = numOut(p.taken) or 0,
    kickable = numOut(p.kickable),
    kick = statsOut(p.kick),
    wholeRun = p.wholeRun and true or nil,
    rows = {},
  }
  local rows = p.rows or {}
  for i = 1, math.min(#rows, MAX_ROWS) do out.rows[i] = rowOut(rows[i]) end
  return out
end

local function runOut(run, pulls, baseline)
  local out = {
    map = strOut(run.mapName), level = numOut(run.level),
    at = numOut(run.at) or epoch(),
    done = (run.endedAt ~= nil) or nil,
    pulls = {},
  }
  -- Keep the LAST MAX_PULLS. A key that overran the cap has its recent packs
  -- kept, and the run total is the sum of what is actually stored rather than a
  -- figure that claims pulls the file threw away.
  local list = pulls or {}
  for i = math.max(1, #list - MAX_PULLS + 1), #list do
    out.pulls[#out.pulls + 1] = pullOut(list[i])
  end
  if baseline then out.carry = pullOut(baseline) end
  return out
end

-- Reading back. The stored table is a file: the player can edit it, an older
-- build can have written it, a crash can have truncated it. So every field is
-- checked and a record that does not survive the check is DROPPED, never
-- repaired into something that then looks measured.
local function rowIn(r)
  if type(r) ~= "table" then return nil end
  local name, ident = strOut(r.name), strOut(r.identity)
  if name == nil and ident == nil then return nil end
  return {
    name = name, class = strOut(r.class), identity = ident,
    isYou = (r.isYou == true) or nil,
    kicks = numOut(r.kicks) or 0,
    deaths = numOut(r.deaths) or 0,
    taken = numOut(r.taken) or 0,
    kickable = numOut(r.kickable),
    kick = statsIn(r.kick),
    stored = true,
  }
end

local function pullIn(p)
  if type(p) ~= "table" or type(p.rows) ~= "table" then return nil end
  local out = {
    duration = numOut(p.duration) or 0,
    kicks = numOut(p.kicks) or 0,
    deaths = numOut(p.deaths) or 0,
    taken = numOut(p.taken) or 0,
    kickable = numOut(p.kickable),
    kick = statsIn(p.kick),
    wholeRun = p.wholeRun and true or nil,
    rows = {}, stored = true,
  }
  for i = 1, math.min(#p.rows, MAX_ROWS) do
    local row = rowIn(p.rows[i])
    if row then out.rows[#out.rows + 1] = row end
  end
  if #out.rows == 0 then return nil end
  return out
end

local function runIn(rec)
  if type(rec) ~= "table" or type(rec.pulls) ~= "table" then return nil end
  local out = {
    map = strOut(rec.map), level = numOut(rec.level), at = numOut(rec.at) or 0,
    open = (rec.done ~= true) or nil, pulls = {}, stored = true,
  }
  for i = 1, math.min(#rec.pulls, MAX_PULLS) do
    local pull = pullIn(rec.pulls[i])
    if pull then out.pulls[#out.pulls + 1] = pull end
  end
  if #out.pulls == 0 then return nil end
  out.carry = pullIn(rec.carry)
  return out
end

-- Keys from earlier sessions, newest first.
Meter.history = {}

local function trimHistory()
  for i = #Meter.history, MAX_RUNS + 1, -1 do Meter.history[i] = nil end
end

function Meter:Persist()
  if not ns.db then return nil end
  local h = { version = HISTORY_VERSION, runs = {} }
  for i = 1, math.min(#self.history, MAX_RUNS) do
    local run = self.history[i]
    h.runs[i] = runOut({ mapName = run.map, level = run.level, at = run.at,
                         endedAt = run.open and nil or true }, run.pulls, nil)
  end
  -- A run with no pulls in it is not worth a record, and writing one would make
  -- "we were in a key" survive a logout as a key with nothing in it.
  if self.run and #self.pulls > 0 then
    h.current = runOut(self.run, self.pulls, self.baseline)
  end
  ns.db.history = h
  return h
end

-- Move the run in memory to the front of the history. Called when a key ends,
-- when another one starts, and when one is abandoned -- a reset key's packs
-- really happened, so they are kept rather than deleted.
function Meter:Archive()
  if not self.run or #self.pulls == 0 then return nil end
  local run = { map = self.run.mapName, level = self.run.level,
                at = self.run.at or epoch(), pulls = {} }
  for i, pull in ipairs(self.pulls) do run.pulls[i] = pull end
  table.insert(self.history, 1, run)
  trimHistory()
  return run
end

-- Is the client still inside the keystone the stored run belongs to? Two
-- questions, because IsChallengeModeActive is the direct answer and the
-- keystone info is the one every build has had.
local function keyIsActive()
  local C = C_ChallengeMode
  if not C then return false end
  if C.IsChallengeModeActive then
    local ok, active = pcall(C.IsChallengeModeActive)
    if ok and ns.Plain(active) ~= nil then return ns.Plain(active) == true end
  end
  if C.GetActiveKeystoneInfo then
    local ok, level = pcall(C.GetActiveKeystoneInfo)
    if ok and ns.Plain(level) then return true end
  end
  return false
end

function Meter:Restore()
  local h = ns.db and ns.db.history
  if type(h) ~= "table" then return false end
  if h.version ~= HISTORY_VERSION then
    -- Rule 2. Dropped whole, and recorded so /uk history can say so instead of
    -- the dropdown simply being empty for no stated reason.
    self.historyDropped = h.version or true
    ns.db.history = nil
    return false
  end

  self.history = {}
  for _, rec in ipairs(h.runs or {}) do
    local run = runIn(rec)
    if run then self.history[#self.history + 1] = run end
  end
  trimHistory()

  local cur = runIn(h.current)
  if cur then
    if cur.open and keyIsActive() then
      -- Same key, after a /reload or a relog inside it. The pulls already
      -- harvested are real; the stored baseline is what keeps the next harvest
      -- from counting them again (rule 3).
      self.run = { level = cur.level, mapName = cur.map, at = cur.at,
                   startedAt = GetTime() }
      self.pulls = cur.pulls
      self.baseline = cur.carry
      self.resumed = #cur.pulls
    else
      cur.open = nil
      table.insert(self.history, 1, cur)
      trimHistory()
    end
  end

  self:Persist()
  return true
end

-- ------------------------------------------------------------------- clearing
-- A harvested pull is the one thing in this addon that cannot be got back by
-- playing the game again: the session it came from is gone and the amounts were
-- only readable for the moment we read them. So clearing is scoped, it says how
-- much it actually threw away, and it never clears more than it was asked to.
--   "saved"    every stored key; the key in progress is untouched
--   <n>        one stored key, by its /uk history index
--   "current"  the pulls harvested in the key in progress
--   "live"     the game's own combat sessions -- see below
--   "all"      all three
--
-- "live" is the one that was missing, and its absence is why clearing LOOKED
-- like it did nothing: the panel's default segment is not ours at all, it is
-- C_DamageMeter's Current session, read live at every refresh. Dropping our
-- harvested pulls never touched it, so the same rows were still on screen a
-- moment after we reported throwing them away. The only thing that empties it
-- is ResetAllCombatSessions -- which is the CLIENT's meter, so it clears
-- Blizzard's own window and any other meter reading the same sessions too.
-- That is worth saying out loud wherever it is offered rather than doing it
-- quietly, so it is its own scope instead of a hidden side effect of "current".
--
-- Returns keys, pulls, live -- or nil, reason, so a caller can report what went
-- rather than claiming success blindly.
function Meter:Forget(scope)
  local n = tonumber(scope)
  local keys, pulls, live = 0, 0, false

  if n then
    local run = self.history[n]
    if not run then return nil, ("no stored key %s"):format(tostring(scope)) end
    pulls = #run.pulls
    table.remove(self.history, n)
    keys = 1
  elseif scope == "saved" or scope == "all" then
    keys = #self.history
    for _, run in ipairs(self.history) do pulls = pulls + #run.pulls end
    self.history = {}
  elseif scope ~= "current" and scope ~= "live" then
    return nil, ("clear what? all, saved, current, live, or a number (%s)")
      :format(tostring(scope))
  end

  if scope == "live" or scope == "all" then
    live = self:ResetLive()
  end

  if scope == "current" or scope == "all" then
    pulls = pulls + #self.pulls
    self.pulls = {}
    -- The baseline is what the next harvest subtracts from. Dropping the pulls
    -- and keeping it would make the next pull a delta from numbers nobody can
    -- see any more; with it gone, diffSnapshot takes the next snapshot whole.
    self.baseline = nil
    self.resumed = nil
  end

  -- Written through to the file in the same breath, not at logout: a clear that
  -- only took effect on a clean exit would come back after a crash, and "I
  -- cleared it and it is still there" is the worst possible answer.
  self:Persist()
  -- A discarded schema version was the reason the list was empty; once it has
  -- been cleared deliberately, saying so is stale.
  if keys > 0 then self.historyDropped = nil end
  self:Reselect()
  -- Unconditionally, not only when Reselect moved the selection: the commonest
  -- clear of all leaves the selection exactly where it was and changes only
  -- what is under it, and that is precisely the case that looked broken.
  if ns.Panel and ns.Panel.Refresh then ns.Panel:Refresh() end
  return keys, pulls, live
end

-- Empty the CLIENT's combat sessions. Separated from Forget so the one call
-- that reaches outside this addon is in one place and can be read on its own.
-- Returns true only if the client actually accepted it.
function Meter:ResetLive()
  local C = C_DamageMeter
  if not C or not C.ResetAllCombatSessions then return false end
  if not pcall(C.ResetAllCombatSessions) then return false end
  -- The baseline is what the next harvest subtracts from, and it describes
  -- numbers that no longer exist. diffSnapshot's backwards-check would cope,
  -- but only by inference; dropping it states the fact.
  self.baseline = nil
  self.resumed = nil
  return true
end

-- Every clear that can be asked for, each with what it would ACTUALLY take.
-- One list, read by the panel's Clear dialog, by /uk forget's help and by the
-- tests, so the dialog cannot offer a scope the command does not have or
-- describe it as costing something different.
--
-- `count` is how much this scope would throw away. Zero means the entry is
-- shown but not armable: a button that discards nothing reads as broken, and
-- hiding it entirely is what made clearing undiscoverable in the first place.
function Meter:ClearScopes()
  local runs = self.history or {}
  local savedPulls = 0
  for _, run in ipairs(runs) do savedPulls = savedPulls + #run.pulls end
  local mine = #self.pulls
  local liveOn = self:Available() and 1 or 0

  local function plural(n, word)
    return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
  end

  return {
    { act = "current", count = mine,
      label = ("this key: %s"):format(plural(mine, "pull")),
      note = "harvested this session -- stored keys untouched" },
    { act = "saved", count = #runs,
      label = ("stored keys: %s, %s"):format(plural(#runs, "key"), plural(savedPulls, "pull")),
      note = "keys kept from earlier logins -- this key untouched" },
    -- The scope that was missing, and the only one that empties what the panel
    -- shows by default. It reaches outside this addon, so it says so here
    -- rather than in a changelog.
    { act = "live", count = liveOn,
      label = "the game's live meter",
      note = "resets Blizzard's own meter too, and any other reading it" },
    { act = "all", count = mine + #runs + liveOn,
      label = "all three", note = "our pulls, the stored keys and the live meter" },
    { act = "settings", count = 1,
      label = "everything, and every setting",
      note = "window position, sort, thresholds -- back to a fresh install" },
  }
end

-- The one entry point both the dialog and the slash command go through, so
-- "settings" cannot mean one thing when typed and another when clicked.
-- Returns ok, message.
function Meter:ClearBy(act)
  if act == "settings" or act == "everything" then
    local keys, pulls = self:Forget("all")
    if ns.ResetDB then ns.ResetDB() end
    if ns.Panel and ns.Panel.Reset then ns.Panel:Reset() end
    if ns.Panel and ns.Panel.Refresh then ns.Panel:Refresh() end
    return true, ("discarded %d stored key(s) and %d pull(s), and put every "
      .. "setting back to a fresh install"):format(keys or 0, pulls or 0)
  end
  local keys, pulls, live = self:Forget(act)
  if not keys then return false, tostring(pulls) end
  local tail = (act == "saved" and " -- the key in progress is untouched")
    or (act == "current" and " -- stored keys are untouched") or ""
  if live then tail = tail .. " and reset the game's live meter" end
  return true, ("discarded %d stored key(s) and %d pull(s)%s")
    :format(keys, pulls, tail)
end

-- Whatever the panel was showing may be what just went. Falling back to the
-- live segment is the same rule a stale stored selection already followed: a
-- heading over an empty table is the one outcome worth engineering against.
function Meter:Reselect()
  local key = ns.db and ns.db.segment
  if type(key) ~= "string" then return nil end
  for _, seg in ipairs(self:Segments()) do
    if seg.key == key then return key end
  end
  ns.db.segment = "current"
  if ns.Panel and ns.Panel.Refresh then ns.Panel:Refresh() end
  return "current"
end

local function ago(at)
  local nowSecs = epoch()
  if not at or at <= 0 or nowSecs <= 0 or nowSecs < at then return nil end
  local s = nowSecs - at
  if s < 3600 then return ("%dm ago"):format(math.max(1, math.floor(s / 60))) end
  if s < 86400 then return ("%dh ago"):format(math.floor(s / 3600)) end
  return ("%dd ago"):format(math.floor(s / 86400))
end

function Meter:RunLabel(run)
  local total = self:TotalOf(run.pulls)
  local when = ago(run.at)
  return ("%s%s  %s  %d pull%s%s"):format(
    run.map or "key", run.level and (" +" .. run.level) or "",
    self:Clock(total and total.duration or 0), #run.pulls,
    #run.pulls == 1 and "" or "s", when and ("  " .. when) or "")
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
  -- A stored key, and a stored key's own pull. Matched before "pull:" so the
  -- two namespaces cannot be confused: pull 2 of this key and pull 2 of the key
  -- you ran yesterday are different pulls.
  local run, pull = key:match("^saved:(%d+):(%d+)$")
  if run then return "savedpull", tonumber(run), tonumber(pull) end
  local saved = key:match("^saved:(%d+)$")
  if saved then return "saved", tonumber(saved) end
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

  -- Keys from earlier logins (R-37), newest first. Only each run's TOTAL is
  -- listed: five keys times their pulls is a menu taller than the screen. The
  -- run you have SELECTED expands to its own pulls underneath it, so a stored
  -- pull is two clicks away rather than unreachable, and the list stays short.
  local selected = (ns.db and type(ns.db.segment) == "string" and ns.db.segment) or ""
  for i, run in ipairs(self.history) do
    out[#out + 1] = {
      key = ("saved:%d"):format(i), kind = "saved", index = i,
      label = ("saved  %s"):format(self:RunLabel(run)),
    }
    local open = selected == ("saved:%d"):format(i)
      or selected:match(("^saved:%d:%%d+$"):format(i)) ~= nil
    if open then
      for n, pull in ipairs(run.pulls) do
        out[#out + 1] = {
          key = ("saved:%d:%d"):format(i, n), kind = "savedpull", index = n,
          label = ("   %s  %s  %d kicks"):format(
            pull.wholeRun and "whole key" or ("pull " .. n),
            self:Clock(pull.duration or 0), pull.kicks or 0),
        }
      end
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
  local kind, n, n2 = self:ParseSegment(key)

  -- A stored run, or one of its pulls. Plain by construction twice over: it was
  -- only harvested because the values were readable, and only written because
  -- every one of them survived ns.Plain on the way to the file.
  if kind == "saved" or kind == "savedpull" then
    local run = self.history[n]
    if not run then return nil end
    if kind == "savedpull" then
      local pull = run.pulls[n2]
      if not pull then return nil end
      return pull.rows, true, ("%s  %s  %s"):format(run.map or "saved key",
        pull.wholeRun and "whole key" or ("pull " .. n2),
        self:Clock(pull.duration or 0)), kind
    end
    local total = self:TotalOf(run.pulls)
    if not total then return nil end
    return total.rows, true, ("saved  %s"):format(self:RunLabel(run)), kind
  end

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
  rows = rows or {}
  -- MEASURED 2026-10-03, Voidscar Arena +11: this is the view the player was
  -- looking at -- "key total 18:44" is LiveLabel, not the run segment -- and it
  -- had never called the drill-down at ALL. kickable was only ever computed in
  -- Snapshot, i.e. on a harvested pull, so on the live segment the column was
  -- structurally blank in every key ever run, while the footer underneath it
  -- said "none of the 158 known interruptible casts hit anyone" -- a
  -- measurement, asserted by a code path that took none.
  self:FillKickable(rows, "current", plain ~= false)
  return rows, plain ~= false, self:LiveLabel(), "live"
end

-- Annotate a live row list with the per-spell drill-down, and record WHY when
-- there is nothing to show. The reason is kept because a blank column has six
-- possible causes and only one of them -- "no known interruptible spell hit
-- anyone" -- is a fact about the fight rather than about the API or about us.
--
-- Only ever runs on a plain segment: the drill-down reads amounts, which is
-- illegal while they are secret.
function Meter:FillKickable(rows, which, plain)
  self.kickableWhy = nil
  if not plain then self.kickableWhy = "in-combat"; return rows end
  if self:KickableMode().field == false then self.kickableWhy = "off"; return rows end

  local worst
  -- Reason precedence: the thing furthest from the player's control wins, so a
  -- party where one row drilled down fine and four were refused reports the
  -- refusal rather than the one row's happy answer.
  local RANK = { ["no-match"] = 1, ["empty"] = 2, ["no-count"] = 3, ["no-unit"] = 4,
                 ["no-source"] = 5, ["no-spells"] = 6, ["no-session"] = 7,
                 ["refused"] = 8, ["secret-guid"] = 9, ["no-metric"] = 10 }
  for _, row in ipairs(rows or {}) do
    local value, by, stats, why = self:Kickable(which, row.unitGUID or row.guid)
    row.kick, row.kickableBy = stats, by
    row.kickable = stats and stats.damage or nil
    if why and (not worst or (RANK[why] or 0) > (RANK[worst] or 0)) then worst = why end
  end
  self.kickableWhy = worst
  return rows
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

  -- kickable is NOT seeded to 0 here. It used to be, and `(r.kickable or 0) -
  -- ...` below turned every unmeasured pull into a measured zero on the way
  -- through the differencing path -- the same R-34 lie the run total was fixed
  -- for, reintroduced one function over.
  local out = { rows = {}, duration = (snap.duration or 0) - (base.duration or 0),
                kicks = 0, deaths = 0, taken = 0, kickable = nil }
  for _, r in ipairs(snap.rows) do
    local b = was[rowKey(r)]
    local d = {
      name = r.name, class = r.class, isYou = r.isYou, identity = r.identity,
      kicks = r.kicks - (b and b.kicks or 0),
      taken = r.taken - (b and b.taken or 0),
      deaths = r.deaths - (b and b.deaths or 0),
      kickable = r.kickable and (r.kickable - (b and b.kickable or 0)) or nil,
    }
    -- Cumulative too, so the same subtraction applies -- and the same rule: a
    -- field nobody measured stays absent instead of arriving as a zero.
    if r.kick then
      d.kick = {}
      for _, f in ipairs(STAT_FIELDS) do
        if r.kick[f] ~= nil then
          d.kick[f] = r.kick[f] - ((b and b.kick and b.kick[f]) or 0)
        end
      end
    end
    -- Per-spell kickable breakdowns are cumulative too and cannot be subtracted
    -- meaningfully, so a delta carries the total only.
    out.kicks = out.kicks + d.kicks
    out.taken = out.taken + d.taken
    out.deaths = out.deaths + d.deaths
    if d.kickable then out.kickable = (out.kickable or 0) + d.kickable end
    if d.kick then out.kick = addStats(out.kick, d.kick) end
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

  -- Written the moment it exists, not at logout: the report of a key you just
  -- finished should survive a crash, a disconnect, or an alt-F4 as well as it
  -- survives a tidy /reload.
  Meter:Persist()

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
  -- Whatever was in memory belongs to the key that just ended, not to this one.
  Meter:Archive()
  Meter.pulls = {}
  Meter.baseline = nil
  Meter.run = { level = level, mapName = mapName or (GetInstanceInfo and GetInstanceInfo()) or nil,
                startedAt = GetTime(), at = epoch() }
  Meter:Persist()
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
  -- Re-written with endedAt set, so a login after this will not try to resume a
  -- key that is over.
  Meter:Persist()
end)

ns.On("CHALLENGE_MODE_RESET", function()
  -- An abandoned key's packs really happened, so they are archived rather than
  -- deleted -- the run simply stops being the live one.
  Meter:Archive()
  Meter.pulls = {}; Meter.run = nil; Meter.baseline = nil
  Meter:Persist()
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

-- Restored after Init's own ADDON_LOADED handler, which is what creates ns.db --
-- handlers run in registration order and Core/Init.lua loads first.
ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  Meter:Restore()
  if Meter.resumed then
    ns.Print("picked up this key where you left it -- %d pull%s already harvested",
      Meter.resumed, Meter.resumed == 1 and "" or "s")
  end
  if Meter.historyDropped then
    ns.Print("stored pulls were written by a different version and have been discarded")
  end
end)

-- Belt and braces. Everything is already written as it happens, so this only
-- matters for a run whose last pull predates a settings change.
ns.On("PLAYER_LOGOUT", function() Meter:Persist() end)
