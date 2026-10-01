-- Unkicked :: parser/session.lua
--
-- Drives the addon's model from combat-log lines and cuts the stream into pulls.
--
-- Segmentation:
--   * A boss pull is bracketed by ENCOUNTER_START / ENCOUNTER_END, which the log
--     states outright.
--   * A trash pull has no markers, so it opens on the first combat event
--     involving a hostile unit and closes after `quietGap` seconds with no such
--     event. That gap is also why a pull's report is emitted a few seconds after
--     the fighting stops rather than the instant it does.
--   * ZONE_CHANGE / MAP_CHANGE / CHALLENGE_MODE_START close whatever was open.
--
-- Runs:
--   One instance = one run, for the overall/end-of-dungeon totals. ZONE_CHANGE
--   states the instance id, name and difficulty and the next ZONE_CHANGE ends
--   it, so a run boundary is read from the log rather than inferred. A log with
--   three keys in it therefore produces three overall reports, not one blend.
--
-- Cooldown state deliberately survives across pulls -- a kick spent four seconds
-- before the next pack is still down -- so only the cast records are cleared.

local logline = require("logline")

local Session = {}
Session.__index = Session

local HOSTILE = 0x00000040
local PLAYER = 0x00000400
local MINE = 0x00000001
local PARTY = 0x00000002
local RAID = 0x00000004

local function band(a, b) return bit.band(a, b) end

-- Events that mean "fighting is happening", for trash segmentation.
local COMBATISH = {
  SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true, SWING_DAMAGE = true,
  RANGE_DAMAGE = true, SPELL_CAST_START = true, SPELL_CAST_SUCCESS = true,
  SPELL_AURA_APPLIED = true, SPELL_INTERRUPT = true, SPELL_MISSED = true,
  SWING_MISSED = true, UNIT_DIED = true,
}

function Session.new(ns, opts)
  local self = setmetatable({
    ns = ns,
    opts = opts or {},
    quietGap = (opts and opts.quietGap) or 5,
    knowledge = opts and opts.knowledge,
    onPull = opts and opts.onPull,
    onRun = opts and opts.onRun,
    host = opts and opts.host,
    advanced = true,
    pull = nil,
    run = nil,
    runs = 0,
    lastCombatAt = nil,
    pulls = 0,          -- reported pulls
    segments = 0,       -- everything we opened, including empty ones
    lines = 0,
    skipped = 0,
    roster = {},        -- guid -> true, for names we have already resolved
    stats = { interrupts = 0, spends = 0, casts = 0 },
  }, Session)
  return self
end

-- ----------------------------------------------------------------- the roster
-- Before the first boss of a run there is no COMBATANT_INFO, so party membership
-- falls back to combat-log flags: a player unit affiliated with my group. That
-- gives us the member but not their spec, so their interrupt stays unbound and
-- availability reports "unknown" until we actually see them press it -- the same
-- honest degradation the in-game version had.
local function isGroupPlayer(flags)
  if not flags or flags == 0 then return false end
  if band(flags, PLAYER) == 0 then return false end
  return band(flags, MINE) > 0 or band(flags, PARTY) > 0 or band(flags, RAID) > 0
end

function Session:noteActor(guid, name, flags)
  if not guid or guid == "" then return end
  -- A log line with no actor writes the null GUID and the literal name "nil", with
  -- the affiliation flags of whoever it concerned -- e.g. an environment DoT ticking
  -- on a party member. That passes the flag test, so without this it becomes a
  -- sixth, nameless party member in every roster and every availability line.
  if not guid:find("^Player%-") then return end
  if name == "nil" then name = nil end
  if not isGroupPlayer(flags) then return end
  local players = self.ns.Kick.players
  local p = players[guid]
  if not p then p = {}; players[guid] = p end
  if name and name ~= "" and not p.name then p.name = name end
end

function Session:onCombatantInfo(fields)
  local info = logline.combatantInfo(fields)
  if not info then return end
  self.ns.Kick:SetKnown(info.guid, info.specID, info.entries)
  self.roster[info.guid] = true
end

-- ------------------------------------------------------------------- the runs
function Session:openRun(at, zoneID, zone, difficulty)
  self:closeRun(at)
  self.runs = self.runs + 1
  self.run = {
    index = self.runs, zoneID = zoneID, zone = zone, difficulty = difficulty,
    startedAt = at, pulls = 0,
  }
  return self.run
end

function Session:closeRun(at)
  local run = self.run
  self.run = nil
  if not run then return end
  run.endedAt = at or self.now or run.startedAt
  run.elapsed = run.endedAt - run.startedAt
  -- A zone we only walked through is not a run worth totalling.
  if run.pulls == 0 then self.runs = self.runs - 1; return end
  if self.onRun then self.onRun(run) end
end

-- A log can begin mid-dungeon -- the client rolls a new file whenever it likes --
-- so there may never be a ZONE_CHANGE to open the first run with. Rather than
-- drop every pull before the first zone line, open an implicit run at the first
-- reported pull and label it from whatever the log last told us.
function Session:ensureRun(at)
  if self.run then return self.run end
  return self:openRun(at, self.lastZoneID, self.lastZone or "run", self.lastDifficulty)
end

-- ------------------------------------------------------------------ the pulls
function Session:openPull(at, name, kind)
  self:closePull(at)
  self.ns.Cast:Wipe()
  for _, p in pairs(self.ns.Kick.players) do p.cc = nil; p.dead = false end
  self.pull = { startedAt = at, name = name, kind = kind, endedAt = nil }
  self.lastCombatAt = at
end

function Session:closePull(at, outcome)
  local pull = self.pull
  if not pull then return end
  self.pull = nil
  pull.endedAt = at or self.lastCombatAt or pull.startedAt
  pull.outcome = outcome
  pull.duration = pull.endedAt - pull.startedAt
  pull.records = {}
  for i, r in ipairs(self.ns.Cast.records) do pull.records[i] = r end
  self.segments = self.segments + 1

  -- A trash segment where nothing of ours happened is noise, not a pull: it would
  -- also shift every later pull number, which is the one thing a report has to
  -- keep stable if he is going to call them out by number.
  if #pull.records == 0 and pull.kind ~= "boss" then return end

  self.pulls = self.pulls + 1
  pull.index = self.pulls
  local run = self:ensureRun(pull.startedAt)
  run.pulls = run.pulls + 1
  pull.run = run
  pull.kicks = self:kickSnapshot()
  if self.onPull then self.onPull(pull) end
end

-- What we believe about each party member at the moment the pull closed, for the
-- report footer: which interrupt, where the number came from, how confident.
function Session:kickSnapshot()
  local out = {}
  for guid, p in pairs(self.ns.Kick.players) do
    local info = p.spellID and self.ns.INTERRUPTS[p.spellID]
    out[#out + 1] = {
      name = p.name or guid,
      class = p.class,
      spec = p.spec,
      spell = info and info.name,
      talent = p.talent,
      exact = p.exact or false,
      learned = (not p.exact) and (p.connectMs or p.whiffMs) and true or false,
      anomalies = p.anomalies or 0,
      cdMs = p.connectMs or p.whiffMs or (info and info.baseMs),
    }
  end
  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  return out
end

-- Retro-applies newly learned interruptibility to casts already recorded in the
-- open pull. Without this, the first cast of a spell is forever "unknown" even
-- though the log proves it interruptible ten seconds later.
function Session:applyKnowledge(spellID)
  for _, r in ipairs(self.ns.Cast.records) do
    if r.spellID == spellID and r.interruptible == nil then
      r.interruptible = true
      r.interruptibleFrom = "learned"
    end
  end
end

-- --------------------------------------------------------------------- feeding
function Session:line(line)
  -- WoW writes WoWCombatLog.txt with CRLF endings on Windows. Reading it on any
  -- platform leaves a trailing \r on the LAST field of every line, which quietly
  -- corrupts the fields we read from the end -- notably SPELL_AURA_APPLIED's
  -- auraType, i.e. the whole CC model. Strip it once, here, rather than at each
  -- comparison site.
  line = line:gsub("[\r\n]+$", "")
  local ts, rest = logline.timestamp(line)
  if not ts then return end
  self.lines = self.lines + 1
  local f = logline.split(rest)
  local event = f[1]

  self.host.setClock(ts)
  self.now = ts

  -- Cold start (R-3) means "we have not been watching long enough to know whether
  -- their interrupt was already down". In game that reset every pull, because the
  -- addon only saw the fight it was in. A log is continuous, so it only applies to
  -- the first seconds of the FILE -- after that, not having seen a spend is itself
  -- evidence the interrupt is up.
  if not self.ns.combatStart then self.ns.combatStart = ts end

  -- Trash pulls close on silence, which only a later line can reveal.
  if self.pull and self.pull.kind == "trash" and self.lastCombatAt
     and (ts - self.lastCombatAt) > self.quietGap then
    self:closePull(self.lastCombatAt)
  end

  if event == "COMBAT_LOG_VERSION" then
    local h = logline.header(f)
    if h then self.advanced = h.advanced ~= false; self.build = h.build end
    return
  end

  if event == "COMBATANT_INFO" then return self:onCombatantInfo(f) end

  if event == "ENCOUNTER_START" then
    return self:openPull(ts, f[3] or ("encounter " .. tostring(f[2])), "boss")
  end
  if event == "ENCOUNTER_END" then
    return self:closePull(ts, f[6] == "1" and "kill" or "wipe")
  end
  if event == "ZONE_CHANGE" then
    self:closePull(ts)
    local zoneID = tonumber(f[2])
    local zone, difficulty = f[3], tonumber(f[4])
    -- Several ZONE_CHANGE lines for the same instance appear back to back on
    -- load; only a genuinely different instance id is a new run.
    if not self.run or self.run.zoneID ~= zoneID then
      self:closeRun(ts)
      self.lastZoneID, self.lastZone, self.lastDifficulty = zoneID, zone, difficulty
      -- difficulty 0 / instance id 0 is the open world, which is not a run.
      if zoneID and zoneID ~= 0 then self:openRun(ts, zoneID, zone, difficulty) end
    end
    return
  end
  if event == "CHALLENGE_MODE_START" then
    self:closePull(ts)
    -- Enriches the run label with the key rather than starting a new one: the
    -- ZONE_CHANGE that put us in the instance already opened it.
    local run = self:ensureRun(ts)
    run.keystone = tonumber(f[5])
    run.zone = f[2] or run.zone
    return
  end
  if event == "MAP_CHANGE" or event == "CHALLENGE_MODE_END" then
    return self:closePull(ts)
  end

  local srcFlags = tonumber(f[4]) or tonumber((f[4] or ""):match("0x(%x+)") or "", 16) or 0
  local dstFlags = tonumber(f[8]) or tonumber((f[8] or ""):match("0x(%x+)") or "", 16) or 0
  self:noteActor(f[2], f[3], srcFlags)
  self:noteActor(f[6], f[7], dstFlags)

  -- Open a trash pull on the first sign of fighting with something hostile.
  local hostile = band(srcFlags, HOSTILE) > 0 or band(dstFlags, HOSTILE) > 0
  if COMBATISH[event] and hostile then
    if not self.pull then self:openPull(ts, "trash", "trash") end
    self.lastCombatAt = ts
  end

  local args, why = logline.normalize(ts, f, self.advanced)
  if not args then
    if why then self.skipped = self.skipped + 1 end
    return
  end

  -- Interruptibility is resolved at cast start, so the knowledge lookup has to be
  -- in place before Ingest sees SPELL_CAST_START.
  if event == "SPELL_CAST_START" and self.knowledge then
    local k = self.knowledge:get(args[8])
    self.ns.Nameplates.Interruptible = function() return k end
  end

  if event == "SPELL_INTERRUPT" then
    self.stats.interrupts = self.stats.interrupts + 1
    local stopped = args[11]
    if self.knowledge and self.knowledge:observe(stopped, f[14]) then
      self:applyKnowledge(stopped)
    end
  end
  if event == "SPELL_CAST_SUCCESS" and self.ns.IS_INTERRUPT[args[8]] then
    self.stats.spends = self.stats.spends + 1
  end

  self.ns.Cast:Ingest(unpack(args, 1, args.n))
end

-- In --follow mode a trash pull ends in silence, and silence produces no line to
-- notice it with. The caller nudges us with the wall clock instead; log
-- timestamps are wall-clock dates, so the two are directly comparable.
function Session:idle(now)
  if not self.now then return end
  -- Only once we have caught up to live. Replaying an old file with --from-start
  -- would otherwise close every trash pull on the first poll, because its
  -- timestamps are hours behind the wall clock, and cut pulls in half.
  if (now - self.now) > 60 then return end
  if self.pull and self.pull.kind == "trash" and self.lastCombatAt
     and (now - self.lastCombatAt) > self.quietGap then
    self:closePull(self.lastCombatAt)
  end
end

-- Called when the input ends (or the tail is paused) so a pull in flight is still
-- reported rather than silently dropped.
function Session:flush()
  self:closePull(self.now)
  self:closeRun(self.now)
end

return Session
