-- Unkicked :: KickTracker.lua
--
-- Per-party-member interrupt cooldown model.
--
-- You cannot read another player's cooldowns, and inspecting their talent loadout
-- returns configID -1, so this infers state from the combat log:
--
--   * A spend is SPELL_CAST_SUCCESS on the interrupt spell, NOT SPELL_INTERRUPT.
--     A kick thrown into an immune cast still burns the cooldown; SPELL_INTERRUPT
--     only tells you it connected. Keying off INTERRUPT would show kicks as up
--     while they are down.
--
--   * Talent-reduced cooldowns are LEARNED, under three guards (REQUIREMENTS R-3):
--       downward only  -- a longer gap means they just did not press it
--       talent-gated   -- only specs with a real reduction node in the tree
--       floored        -- never below what that talent can actually achieve
--     and we keep the MINIMUM observed interval, so one mis-measured gap cannot
--     permanently widen the estimate.
--
--   * Refund-style talents (Coldthirst) make the cooldown CONDITIONAL, not
--     constant, so two values are learned per player: one for an interrupt that
--     connected, one for a whiff.

local ADDON, ns = ...

local Kick = {}
ns.Kick = Kick

local HUGE = math.huge

-- guid -> {
--   name, class, unit, spellID, baseMs, floorMs, eligible,
--   lastSpendAt, lastSpendConnected, connectMs, whiffMs, seenSpend, cc
-- }
local players = {}
Kick.players = players

-- Class -> the interrupts that class could possibly have. Where a class has more
-- than one, we cannot know which until we see them use it, so the spell stays
-- unbound and availability is reported as unknown rather than guessed.
local byClass = {}
for id, info in pairs(ns.INTERRUPTS) do
  byClass[info.class] = byClass[info.class] or {}
  table.insert(byClass[info.class], id)
end

local function bind(p, spellID)
  local info = ns.INTERRUPTS[spellID]
  if not info then return end
  p.spellID = spellID
  p.baseMs = info.baseMs
  p.floorMs = info.floorMs
  p.eligible = info.eligible
end

-- Offline only. A combat log's COMBATANT_INFO states a player's spec id and the
-- trait node entries they actually selected -- both unreadable in game on 12.x,
-- where inspecting a loadout returns configID -1. When we have them the cooldown
-- stops being an inference: we know which interrupt they have and whether they
-- took the one talent that shortens it, so the learning rule below is skipped.
--
-- `entries` may be an empty table, which is itself an answer ("they did not take
-- it") and still sets p.exact. Pass nil to mean "no talent information".
function Kick:SetKnown(guid, specID, entries, name)
  local p = players[guid]
  if not p then p = {}; players[guid] = p end
  if name then p.name = name end

  local spec = specID and ns.SPEC_INTERRUPT and ns.SPEC_INTERRUPT[specID]
  if spec then
    p.class = spec.class
    p.spec = spec.spec
    bind(p, spec.spellID)
  end

  if not entries or not p.spellID then return p end

  local base = ns.INTERRUPTS[p.spellID].baseMs
  p.connectMs, p.whiffMs, p.talent = nil, nil, nil
  for _, entryID in ipairs(entries) do
    local t = ns.TRAIT_CD and ns.TRAIT_CD[entryID]
    if t and t.spellID == p.spellID then
      local after = t.pctReduction and (base * (1 - t.pctReduction / 100))
                                    or (base - (t.flatReductionMs or 0))
      p.talent = t.name
      -- A conditional (proc-triggered) reduction only pays out on a successful
      -- interrupt, which is exactly the split the two-bucket model already has.
      p.connectMs = after
      p.whiffMs = t.conditional and base or after
    end
  end
  p.exact = true
  return p
end

function Kick:Rebuild()
  local seen = {}
  local n = GetNumGroupMembers()
  local units = { "player" }
  if IsInRaid() then
    for i = 1, n do units[#units + 1] = "raid" .. i end
  else
    for i = 1, n - 1 do units[#units + 1] = "party" .. i end
  end

  for _, unit in ipairs(units) do
    local guid = UnitGUID(unit)
    if guid then
      seen[guid] = true
      local p = players[guid] or {}
      players[guid] = p
      p.unit = unit
      p.name = UnitName(unit)
      p.class = select(2, UnitClass(unit))

      if not p.spellID then
        local candidates = byClass[p.class]
        if candidates and #candidates == 1 then
          bind(p, candidates[1])
        elseif unit == "player" then
          -- For ourselves we know the spec, so resolve the ambiguous classes.
          for _, id in ipairs(candidates or {}) do
            if IsPlayerSpell(id) then bind(p, id) break end
          end
        end
      end
    end
  end

  for guid in pairs(players) do
    if not seen[guid] then players[guid] = nil end
  end
end

ns.On("GROUP_ROSTER_UPDATE", function() Kick:Rebuild() end)
ns.On("PLAYER_ENTERING_WORLD", function() Kick:Rebuild() end)
ns.On("PLAYER_SPECIALIZATION_CHANGED", function() Kick:Rebuild() end)

-- Which cooldown applies right now depends on how the LAST spend resolved.
local function activeCdMs(p)
  if p.lastSpendConnected and p.connectMs then return p.connectMs end
  if (not p.lastSpendConnected) and p.whiffMs then return p.whiffMs end
  return p.baseMs
end

function Kick:OnSpend(guid, spellID, now)
  local p = players[guid]
  if not p then return end
  if not p.spellID then bind(p, spellID) end
  if p.spellID ~= spellID then return end

  -- Measure the interval the PREVIOUS spend actually took, and file it under
  -- whether that previous spend connected. Skipped when the cooldown is already
  -- known exactly from a log's talent list -- there is nothing left to learn, and
  -- a mis-measured gap could only make a known-correct number worse.
  if p.lastSpendAt and not p.exact then
    local observedMs = (now - p.lastSpendAt) * 1000
    local bucket = p.lastSpendConnected and "connectMs" or "whiffMs"
    local shorter = observedMs < (p.baseMs - ns.CD_EPSILON_MS)

    if shorter and p.eligible and observedMs >= (p.floorMs - ns.CD_EPSILON_MS) then
      p[bucket] = math.min(p[bucket] or HUGE, observedMs)
    elseif shorter then
      -- Below base but the spec has no reduction node, or below the talent's
      -- own floor. That is a clock problem or a missed spend, not a talent.
      p.anomalies = (p.anomalies or 0) + 1
    end
  end

  p.lastSpendAt = now
  p.lastSpendConnected = false
  p.seenSpend = true
end

-- SPELL_INTERRUPT from the same player right after their spend means it connected.
function Kick:OnConnect(guid, spellID, now)
  local p = players[guid]
  if not p or p.spellID ~= spellID then return end
  if p.lastSpendAt and (now - p.lastSpendAt) <= 1 then
    p.lastSpendConnected = true
  end
end

-- Returns: state, detail
--   "ready"   their interrupt should have been available
--   "down"    on cooldown, with seconds remaining at that moment
--   "cc"      available but they could not act, with the mechanic
--   "dead"    not a thing they could have done anything about
--   "unknown" we could not determine which interrupt they have, or cold start
function Kick:StateAt(guid, when)
  local p = players[guid]
  if not p then return "unknown" end
  if p.dead then return "dead" end

  local cc = p.cc
  if cc and when >= cc.from and (not cc.until_ or when <= cc.until_) then
    return "cc", cc.mechanic
  end

  if not p.spellID then return "unknown", "spec unknown" end

  if not p.lastSpendAt then
    -- Never seen them press it. Either it is genuinely up, or they spent it
    -- before we had log visibility. Only the opening seconds are suspect.
    if ns.combatStart and (when - ns.combatStart) < ns.COLD_START and not p.seenSpend then
      return "unknown", "cold start"
    end
    return "ready"
  end

  local readyAt = p.lastSpendAt + activeCdMs(p) / 1000
  if when >= readyAt then return "ready" end
  return "down", readyAt - when
end

function Kick:Describe(guid)
  local p = players[guid]
  if not p then return "?" end
  local cd = activeCdMs(p)
  local learned = (p.connectMs or p.whiffMs) and " (learned)" or ""
  return ("%s %s %.0fs%s"):format(p.name or "?", p.spellID and (ns.INTERRUPTS[p.spellID].name) or "unknown",
    (cd or 0) / 1000, learned)
end

-- ---------------------------------------------------------------- CC tracking
-- "Kick was up but they were in a Fear" must be a separate reason, never blame.
function Kick:OnAuraApplied(guid, spellID, now)
  local mechanic = ns.CC_AURAS[spellID]
  if not mechanic then return end
  local p = players[guid]
  if not p then return end
  p.cc = { mechanic = mechanic, from = now, spellID = spellID }
end

function Kick:OnAuraRemoved(guid, spellID, now)
  local p = players[guid]
  if not p or not p.cc then return end
  if p.cc.spellID == spellID then p.cc.until_ = now end
end

function Kick:OnDeath(guid, now, dead)
  local p = players[guid]
  if p then p.dead = dead end
end

ns.On("PLAYER_REGEN_DISABLED", function()
  ns.combatStart = GetTime()
  Kick:Rebuild()
  for _, p in pairs(players) do
    p.cc = nil
    p.dead = false
    -- Cooldown state deliberately SURVIVES across pulls: a kick spent 4s before
    -- the next pull is still down. Learned cooldowns survive the whole session.
  end
end)
