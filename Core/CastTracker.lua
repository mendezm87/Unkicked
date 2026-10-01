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
  if isPartyPlayer(srcGUID) then
    ns.Kick:OnConnect(srcGUID, spellID, now)
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
  if ns.IS_INTERRUPT[spellID] and isPartyPlayer(srcGUID) then
    ns.Kick:OnSpend(srcGUID, spellID, now)
    if ns.Panel then ns.Panel:Refresh() end
    return
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

local function accumulate(srcGUID, spellID, dstGUID, amount)
  local now = GetTime()
  closeStale(now)
  for rec in pairs(open) do
    if rec.srcGUID == srcGUID and rec.spellID == spellID then
      rec.damage = rec.damage + (amount or 0)
      if dstGUID then
        rec.dmgTo[dstGUID] = (rec.dmgTo[dstGUID] or 0) + (amount or 0)
        rec.lastHitAt[dstGUID] = now
      end
      if ns.Panel then ns.Panel:Refresh() end
    end
  end
end

handle.SPELL_DAMAGE = function(ts, srcGUID, _, _, dstGUID, _, spellID, _, _, amount)
  accumulate(srcGUID, spellID, dstGUID, amount)
end
handle.SPELL_PERIODIC_DAMAGE = handle.SPELL_DAMAGE
handle.SPELL_ABSORBED = function() end  -- absorbed damage did not land; ignore

handle.UNIT_DIED = function(ts, _, _, _, dstGUID, dstName)
  local now = GetTime()
  if isPartyPlayer(dstGUID) then
    ns.Kick:OnDeath(dstGUID, now, true)
    for rec in pairs(open) do
      local hit = rec.lastHitAt[dstGUID]
      if hit and (now - hit) <= ns.DEATH_WINDOW and (rec.dmgTo[dstGUID] or 0) > 0 then
        rec.deaths[dstName or "?"] = rec.dmgTo[dstGUID]
      end
    end
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

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
  if not ns.db or not ns.db.enabled then return end
  local ts, event, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _,
        a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = CombatLogGetCurrentEventInfo()
  local fn = handle[event]
  if not fn then return end
  fn(ts, srcGUID, srcName, srcFlags, dstGUID, dstName, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
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
