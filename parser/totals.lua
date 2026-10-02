-- Unkicked :: parser/totals.lua
--
-- The overall segment: everything that got through across a whole run, the way
-- a damage meter keeps a dungeon total beside the current fight.
--
-- A "run" is one instance. The log states it outright -- ZONE_CHANGE carries the
-- instance id, the name and the difficulty, and the next ZONE_CHANGE ends it --
-- so run boundaries are read, not guessed. A log containing three keys produces
-- three overall reports rather than one blended one.
--
-- What this deliberately does NOT do: rank players. The per-player column counts
-- how many unkicked casts happened while the model believed that player's
-- interrupt was available, which is a count of *chances*, not of failures. R-7
-- still holds -- the log cannot see whether they were in range of the caster, or
-- busy keeping the group alive. Printing "Bob: 9" next to "Bob's fault: 9" is the
-- same number dressed as an accusation, so the column is labelled chances and the
-- header says so.

local M = {}

local Totals = {}
Totals.__index = Totals

function M.new(run)
  return setmetatable({
    run = run or {},
    pulls = 0,
    bosses = 0,
    kills = 0,
    wipes = 0,
    duration = 0,       -- time spent in pulls, not wall time in the instance
    unkicked = 0,
    damage = 0,
    deaths = 0,
    unknown = 0,        -- casts we still cannot prove were kickable
    unknownDamage = 0,
    unknownDeaths = 0,  -- deaths caused by those, which are still deaths
    partyDeaths = 0,    -- every party death in the run, attributed or not
    spells = {},        -- spellID -> { name, count, damage, deaths }
    sources = {},       -- caster name -> { count, damage }
    players = {},       -- player name -> { chances, down, cc, unknown, spends, connects }
    worst = {},         -- every proven cast, trimmed on report
  }, Totals)
end

local function bucket(t, key, init)
  local b = t[key]
  if not b then b = init; t[key] = b end
  return b
end

-- Mirrors report.lua's partition: an immune cast is not a missed kick, and an
-- unproven one is counted separately rather than folded into the total.
function Totals:add(pull, minDamage)
  self.pulls = self.pulls + 1
  self.duration = self.duration + (pull.duration or 0)
  self.partyDeaths = self.partyDeaths + (pull.partyDeaths or 0)
  if pull.kind == "boss" then
    self.bosses = self.bosses + 1
    if pull.outcome == "kill" then self.kills = self.kills + 1
    elseif pull.outcome == "wipe" then self.wipes = self.wipes + 1 end
  end

  for _, r in ipairs(pull.records or {}) do
    if r.interruptible ~= false and (r.damage or 0) >= (minDamage or 0) then
      local dmg = r.damage or 0
      local deaths = 0
      for _ in pairs(r.deaths or {}) do deaths = deaths + 1 end

      if r.interruptible ~= true then
        -- Not provably kickable, so it is not a missed kick and must stay out of
        -- the unkicked total. But a death it caused is still a death: counting it
        -- nowhere let the overall print "no deaths caused" for a run whose pull
        -- reports said KILLED twice, which is the summary lying about the detail.
        self.unknown = self.unknown + 1
        self.unknownDamage = self.unknownDamage + dmg
        self.unknownDeaths = self.unknownDeaths + deaths
      else
        self.unkicked = self.unkicked + 1
        self.damage = self.damage + dmg
        self.deaths = self.deaths + deaths

        local s = bucket(self.spells, r.spellID,
          { name = r.spellName, count = 0, damage = 0, deaths = 0 })
        s.count, s.damage, s.deaths = s.count + 1, s.damage + dmg, s.deaths + deaths

        local src = bucket(self.sources, r.srcName or "?", { count = 0, damage = 0 })
        src.count, src.damage = src.count + 1, src.damage + dmg

        local k = r.kicks or {}
        local function note(list, field)
          for _, p in ipairs(list or {}) do
            local who = bucket(self.players, p.name or "?",
              { chances = 0, down = 0, cc = 0, unknown = 0 })
            who[field] = who[field] + 1
          end
        end
        note(k.ready, "chances")
        note(k.down, "down")
        note(k.cc, "cc")
        note(k.unknown, "unknown")

        self.worst[#self.worst + 1] = {
          spell = r.spellName, source = r.srcName or "?", damage = dmg,
          deaths = deaths, pull = pull.index,
        }
      end
    end
  end
end

-- Sorted views, built on demand so :add stays cheap in --follow mode.
function Totals:topSpells(n)
  local out = {}
  for id, s in pairs(self.spells) do
    out[#out + 1] = { spellID = id, name = s.name, count = s.count, damage = s.damage, deaths = s.deaths }
  end
  table.sort(out, function(a, b)
    if a.damage ~= b.damage then return a.damage > b.damage end
    return (a.name or "") < (b.name or "")
  end)
  while n and #out > n do table.remove(out) end
  return out
end

function Totals:topSources(n)
  local out = {}
  for name, s in pairs(self.sources) do
    out[#out + 1] = { name = name, count = s.count, damage = s.damage }
  end
  table.sort(out, function(a, b)
    if a.damage ~= b.damage then return a.damage > b.damage end
    return a.name < b.name
  end)
  while n and #out > n do table.remove(out) end
  return out
end

function Totals:byPlayer()
  local out = {}
  for name, p in pairs(self.players) do
    out[#out + 1] = { name = name, chances = p.chances, down = p.down, cc = p.cc, unknown = p.unknown }
  end
  table.sort(out, function(a, b)
    if a.chances ~= b.chances then return a.chances > b.chances end
    return a.name < b.name
  end)
  return out
end

function Totals:topCasts(n)
  local out = {}
  for i, c in ipairs(self.worst) do out[i] = c end
  table.sort(out, function(a, b)
    if a.deaths ~= b.deaths then return a.deaths > b.deaths end
    if a.damage ~= b.damage then return a.damage > b.damage end
    return (a.spell or "") < (b.spell or "")
  end)
  while n and #out > n do table.remove(out) end
  return out
end

function Totals:empty() return self.pulls == 0 end

return M
