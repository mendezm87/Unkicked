-- Unkicked :: CastTracker.lua
--
-- The actual subject of the addon: enemy casts that STARTED, were interruptible,
-- and finished anyway. For each one we record what it cost and who had a kick.
--
-- Three things worth knowing about the data:
--
--   * There is no cast -> damage link in the combat log. Damage is correlated by
--     (sourceGUID, spellID) inside a window after the cast completes, and keeps
--     accumulating for channels and DoT ticks.
--   * "Stopped" is not only a kick. Stuns, silences and knockbacks that break a
--     cast all produce SPELL_INTERRUPT with the stopping player as source, so
--     "somebody stopped this" is a direct read rather than an inference.
--   * Death attribution is a contribution claim, not a killing blow: if a cast's
--     damage landed on someone who died within DEATH_WINDOW, it is flagged.

local ADDON, ns = ...

local Cast = {}
ns.Cast = Cast

local pending = {}   -- "guid:spellID" -> { startedAt, interruptible, name }
local open = {}      -- records still accumulating damage
local records = {}   -- newest first, what the panel renders
Cast.records = records

local function key(guid, spellID) return guid .. ":" .. spellID end

local function isEnemy(flags)
  return flags and bit.band(flags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
end

local function isPartyPlayer(guid)
  return ns.Kick.players[guid] ~= nil
end

-- Whose interrupt was that? A warlock does not cast Spell Lock -- his felhunter
-- does -- so the spend arrives with a Pet-* source that is not in the roster. Fold
-- it onto the owner, or the warlock is reported "up" for a cooldown he spent.
-- Returns the party GUID to credit, plus whether it came via a pet.
local function kicker(guid)
  if not guid then return nil end
  if ns.Kick.players[guid] then return guid, false end
  local owner = ns.Pets and ns.Pets:Owner(guid)
  if owner and ns.Kick.players[owner] then return owner, true end
  return nil
end

-- Who had their interrupt up when this cast began.
local function snapshotParty(at)
  local ready, down, cc, unknown = {}, {}, {}, {}
  for guid, p in pairs(ns.Kick.players) do
    local state, detail = ns.Kick:StateAt(guid, at)
    local row = { name = p.name, class = p.class, detail = detail }
    if state == "ready" then table.insert(ready, row)
    elseif state == "down" then table.insert(down, row)
    elseif state == "cc" then table.insert(cc, row)
    elseif state == "unknown" then table.insert(unknown, row) end
  end
  return { ready = ready, down = down, cc = cc, unknown = unknown }
end

function Cast:Record(rec)
  table.insert(records, 1, rec)
  for i = #records, (ns.db.maxRows or 12) * 4 + 1, -1 do records[i] = nil end
  open[rec] = true
  if ns.Panel then ns.Panel:Refresh() end
end

local function closeStale(now)
  for rec in pairs(open) do
    if now - rec.completedAt > ns.DAMAGE_WINDOW then open[rec] = nil end
  end
end

-- ------------------------------------------------------------------- handlers
local handle = {}

-- Pet ownership, straight from the log. The advanced block's ownerGUID covers
-- lines that carry one; this covers the rest, and is the only thing that tells us
-- a pet came BACK after dying.
handle.SPELL_SUMMON = function(ts, srcGUID, srcName, srcFlags, dstGUID, dstName)
  if ns.Pets then ns.Pets:Note(dstGUID, srcGUID, dstName) end
end

handle.SPELL_CAST_START = function(ts, srcGUID, srcName, srcFlags, _, _, spellID, spellName)
  if not isEnemy(srcFlags) then return end
  pending[key(srcGUID, spellID)] = {
    startedAt = GetTime(),
    spellName = spellName,
    srcName = srcName,
    interruptible = ns.Nameplates:Interruptible(srcGUID, spellID),
  }
end

handle.SPELL_CAST_FAILED = function(ts, srcGUID, _, _, _, _, spellID)
  pending[key(srcGUID, spellID)] = nil
end

handle.SPELL_INTERRUPT = function(ts, srcGUID, srcName, _, dstGUID, _, spellID, _, _, extraSpellID)
  local now = GetTime()
  -- The kick connected. Credit the stopper and drop the cast; it never completed.
  pending[key(dstGUID, extraSpellID)] = nil
  local who = kicker(srcGUID)
  if who then
    ns.Kick:OnConnect(who, spellID, now)
  end
  -- An interrupt landing ON a party member locks their school; treat as cannot-act.
  if isPartyPlayer(dstGUID) then
    local p = ns.Kick.players[dstGUID]
    p.cc = { mechanic = "SILENCED", from = now, until_ = now + 3, spellID = spellID }
  end
end

handle.SPELL_CAST_SUCCESS = function(ts, srcGUID, srcName, srcFlags, _, _, spellID, spellName)
  local now = GetTime()

  -- A party member spending their interrupt. This fires whether or not it landed,
  -- which is exactly why cooldown tracking keys off this and not SPELL_INTERRUPT.
  if ns.IS_INTERRUPT[spellID] then
    local who, viaPet = kicker(srcGUID)
    if who then
      ns.Kick:OnSpend(who, spellID, now, viaPet)
      if ns.Panel then ns.Panel:Refresh() end
      return
    end
  end

  if not isEnemy(srcFlags) then return end
  local k = key(srcGUID, spellID)
  local p = pending[k]
  if not p then return end       -- instant cast, or we never saw it start
  pending[k] = nil

  if p.interruptible == false and ns.db.onlyInterruptible then return end
  if p.interruptible == nil and not ns.db.includeUnknown then return end

  Cast:Record({
    spellID = spellID,
    spellName = spellName or ("spell " .. spellID),
    srcGUID = srcGUID,
    srcName = srcName,
    startedAt = p.startedAt,
    completedAt = now,
    interruptible = p.interruptible,
    kicks = snapshotParty(p.startedAt),
    damage = 0,
    dmgTo = {},
    lastHitAt = {},
    deaths = {},
  })
end

-- The cast a hit belongs to: the most recent one from this source for this spell
-- that had already completed when the hit landed. A boss recasting the same spell
-- every few seconds keeps several records inside DAMAGE_WINDOW at once, and a tick
-- belongs to exactly one of them -- crediting every match inflates the total by the
-- number of overlapping casts, which is how a 957k spell reported 4.7m.
local function owningCast(srcGUID, spellID, at)
  for i = 1, #records do          -- records is newest first
    local rec = records[i]
    if open[rec] and rec.srcGUID == srcGUID and rec.spellID == spellID
       and rec.completedAt <= at then
      return rec
    end
  end
  return nil
end

local function accumulate(srcGUID, spellID, dstGUID, amount)
  local now = GetTime()
  closeStale(now)
  local rec = owningCast(srcGUID, spellID, now)
  if not rec then return end
  rec.damage = rec.damage + (amount or 0)
  if dstGUID then
    rec.dmgTo[dstGUID] = (rec.dmgTo[dstGUID] or 0) + (amount or 0)
    rec.lastHitAt[dstGUID] = now
  end
  if ns.Panel then ns.Panel:Refresh() end
end

handle.SPELL_DAMAGE = function(ts, srcGUID, _, _, dstGUID, _, spellID, _, _, amount)
  accumulate(srcGUID, spellID, dstGUID, amount)
end
handle.SPELL_PERIODIC_DAMAGE = handle.SPELL_DAMAGE
handle.SPELL_ABSORBED = function() end  -- absorbed damage did not land; ignore

handle.UNIT_DIED = function(ts, _, _, _, dstGUID, dstName)
  local now = GetTime()
  -- A warlock whose felhunter is dead has no interrupt at all until he resummons.
  if ns.Pets then ns.Pets:OnDeath(dstGUID) end
  if isPartyPlayer(dstGUID) then
    ns.Kick:OnDeath(dstGUID, now, true)
    -- One death is one death: claimed by the single cast that hit them last, not by
    -- every cast still inside the window. Otherwise a channel recast five times
    -- reports five kills for one UNIT_DIED.
    local best, bestHit = nil, nil
    for rec in pairs(open) do
      local hit = rec.lastHitAt[dstGUID]
      if hit and (now - hit) <= ns.DEATH_WINDOW and (rec.dmgTo[dstGUID] or 0) > 0 then
        if not bestHit or hit > bestHit or (hit == bestHit and rec.completedAt > best.completedAt) then
          best, bestHit = rec, hit
        end
      end
    end
    if best then best.deaths[dstName or "?"] = best.dmgTo[dstGUID] end
    if ns.Panel then ns.Panel:Refresh() end
  end
  -- The caster died mid-cast; nothing completed.
  for k in pairs(pending) do
    if k:find(dstGUID, 1, true) == 1 then pending[k] = nil end
  end
end

handle.SPELL_AURA_APPLIED = function(ts, _, _, _, dstGUID, _, spellID)
  if isPartyPlayer(dstGUID) then ns.Kick:OnAuraApplied(dstGUID, spellID, GetTime()) end
end
handle.SPELL_AURA_REFRESH = handle.SPELL_AURA_APPLIED
handle.SPELL_AURA_REMOVED = function(ts, _, _, _, dstGUID, _, spellID)
  if isPartyPlayer(dstGUID) then ns.Kick:OnAuraRemoved(dstGUID, spellID, GetTime()) end
end

-- The combat-log feed, kept as a named entry point rather than an anonymous
-- handler. Since 12.0.0 the client will not deliver it (see ns.blocked), so the
-- only things that can drive it are the test harness and an offline parser of
-- WoWCombatLog.txt -- both of which hand us the same field order.
function Cast:Ingest(ts, event, srcGUID, srcName, srcFlags, dstGUID, dstName, ...)
  if not ns.db or not ns.db.enabled then return end
  local fn = handle[event]
  if not fn then return end
  fn(ts, srcGUID, srcName, srcFlags, dstGUID, dstName, ...)
end

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
  local ts, event, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _,
        a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = CombatLogGetCurrentEventInfo()
  Cast:Ingest(ts, event, srcGUID, srcName, srcFlags, dstGUID, dstName,
    a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
end)

ns.On("PLAYER_REGEN_DISABLED", function()
  wipe(pending)
end)

function Cast:Wipe()
  wipe(pending)
  wipe(open)
  wipe(records)
  if ns.Panel then ns.Panel:Refresh() end
end

-- End-of-pull summary numbers.
function Cast:Summary()
  local casts, damage, deaths = 0, 0, 0
  for _, r in ipairs(records) do
    casts = casts + 1
    damage = damage + r.damage
    for _ in pairs(r.deaths) do deaths = deaths + 1 end
  end
  return casts, damage, deaths
end
