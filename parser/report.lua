-- Unkicked :: parser/report.lua
-- Renders one pull. Plain text by default; --json for piping somewhere else.

local M = {}

local function short(n)
  if not n or n <= 0 then return "0" end
  if n >= 1e6 then return ("%.1fm"):format(n / 1e6) end
  if n >= 1e3 then return ("%.0fk"):format(n / 1e3) end
  return ("%d"):format(n)
end

local function clock(secs)
  return ("%d:%02d"):format(math.floor(secs / 60), math.floor(secs % 60))
end

local COLOR = {
  reset = "\27[0m", dim = "\27[2m", bold = "\27[1m",
  red = "\27[31m", yellow = "\27[33m", green = "\27[32m", cyan = "\27[36m",
}
local function paint(on)
  if on then return COLOR end
  return setmetatable({}, { __index = function() return "" end })
end

local function names(list)
  local out = {}
  for _, r in ipairs(list or {}) do out[#out + 1] = r.name or "?" end
  table.sort(out)
  return table.concat(out, ", ")
end

-- Casts we know were immune are not failures to kick, so they never appear.
-- Casts of unknown interruptibility are shown but kept in their own section.
local function partition(records, minDamage)
  local sure, unsure = {}, {}
  for _, r in ipairs(records) do
    if r.interruptible ~= false and (r.damage or 0) >= (minDamage or 0) then
      if r.interruptible == true then sure[#sure + 1] = r else unsure[#unsure + 1] = r end
    end
  end
  local function oldestFirst(a, b) return a.completedAt < b.completedAt end
  table.sort(sure, oldestFirst)
  table.sort(unsure, oldestFirst)
  return sure, unsure
end

local function trunc(s, n)
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "\xE2\x80\xA6"
end

local function row(c, r, t0)
  local deaths = {}
  for who, amount in pairs(r.deaths or {}) do
    deaths[#deaths + 1] = ("%s (%s)"):format(who, short(amount))
  end
  -- Name the caster. Two mobs of the same type casting the same spell in the same
  -- second is normal (a real pack had two Hexes at 0:18 from different GUIDs), and
  -- without the source those read as a duplicated row rather than two casts.
  local line = ("  %s%s  %-26s %-22s %s%8s%s"):format(
    c.dim, clock(r.completedAt - t0), trunc(r.spellName or "?", 26), trunc(r.srcName or "?", 22),
    c.bold, short(r.damage or 0), c.reset)
  if #deaths > 0 then
    line = line .. ("  %sKILLED %s%s"):format(c.red, table.concat(deaths, ", "), c.reset)
  end
  local k = r.kicks or {}
  local bits = {}
  if #(k.ready or {}) > 0 then bits[#bits + 1] = ("%sup: %s%s"):format(c.yellow, names(k.ready), c.reset) end
  if #(k.down or {}) > 0 then bits[#bits + 1] = ("%sdown: %s%s"):format(c.dim, names(k.down), c.reset) end
  if #(k.cc or {}) > 0 then bits[#bits + 1] = ("%scc: %s%s"):format(c.cyan, names(k.cc), c.reset) end
  if #(k.unknown or {}) > 0 then bits[#bits + 1] = ("%s?: %s%s"):format(c.dim, names(k.unknown), c.reset) end
  if #bits > 0 then line = line .. "\n        " .. table.concat(bits, "  ") end
  return line
end

function M.text(pull, opts)
  opts = opts or {}
  local c = paint(opts.color)
  local out = {}
  local sure, unsure = partition(pull.records, opts.minDamage)

  local label = pull.kind == "boss" and (pull.name .. (pull.outcome and (" -- " .. pull.outcome) or ""))
                                     or "trash"
  local dmg = 0
  for _, r in ipairs(sure) do dmg = dmg + (r.damage or 0) end

  out[#out + 1] = ("%s== pull %d  %s  %s  %d unkicked (%s dmg)%s"):format(
    c.bold, pull.runIndex or pull.index, label, clock(pull.duration or 0), #sure, short(dmg), c.reset)

  if #sure == 0 and #unsure == 0 then
    out[#out + 1] = ("  %snothing got through%s"):format(c.green, c.reset)
  end
  for _, r in ipairs(sure) do out[#out + 1] = row(c, r, pull.startedAt) end

  if #unsure > 0 then
    out[#out + 1] = ("  %s-- %d cast%s of unknown interruptibility (not yet proven kickable) --%s")
      :format(c.dim, #unsure, #unsure == 1 and "" or "s", c.reset)
    for _, r in ipairs(unsure) do out[#out + 1] = row(c, r, pull.startedAt) end
  end

  if opts.model then
    local model = {}
    for _, k in ipairs(pull.kicks or {}) do
      local src = k.exact and "from log" or (k.learned and "learned" or "base")
      local cd = k.cdMs and ("%.1fs"):format(k.cdMs / 1000) or "  -  "
      local spell = k.spell or (k.noInterrupt and "none" or "unknown")
      local note = k.spell and src or (k.noInterrupt and "no interrupt in 12.x" or "spec unknown")
      if k.pet then note = note .. " (pet)" end
      -- Names are truncated to the column, not merely left-padded: a 25-character
      -- "Brucellosis-Ghostlands-US" in a 16-wide field shoves every later column
      -- right and the table stops being a table.
      model[#model + 1] = ("  %s%-20s %-18s %-18s %5s  %s%s%s"):format(c.dim,
        trunc(k.name, 20), k.spec or k.class or "?", spell,
        k.noInterrupt and "  -  " or cd, note, k.talent and (" +" .. k.talent) or "", c.reset)
    end
    -- The model only changes when a spec, cooldown or talent read changes, so
    -- repeating all five rows under every pull is ten copies of one fact. Print it
    -- the first time and then only when it actually moved.
    local sig = table.concat(model, "\n")
    if sig ~= "" and sig ~= opts.modelSeen then
      opts.modelSeen = sig
      for _, line in ipairs(model) do out[#out + 1] = line end
    end
  end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------- overall
-- The end-of-run segment. Same data as the per-pull reports, aggregated: what
-- got through across the whole instance, which spells cost the most, who was
-- casting them, and -- carefully labelled -- how often each party member's
-- interrupt was believed available while something got through.
local function runLabel(run)
  local bits = { (run and run.zone) or "run" }
  if run and run.keystone then bits[#bits + 1] = ("+%d"):format(run.keystone) end
  return table.concat(bits, " ")
end

function M.overall(t, opts)
  opts = opts or {}
  local c = paint(opts.color)
  local out = {}
  local run = t.run or {}

  out[#out + 1] = ("%s== overall  %s  %s in combat  %d pull%s%s%s"):format(
    c.bold, runLabel(run), clock(t.duration or 0), t.pulls, t.pulls == 1 and "" or "s",
    t.bosses > 0 and ("  %d/%d bosses"):format(t.kills, t.bosses) or "", c.reset)

  -- Deaths caused by a cast we cannot yet prove was kickable are reported
  -- separately rather than folded in or dropped: they are not missed kicks, but
  -- "no deaths caused" would contradict the pull reports that said KILLED.
  local deathBit
  if t.deaths > 0 then
    deathBit = ("%s%d death%s caused%s"):format(c.red, t.deaths,
      t.deaths == 1 and "" or "s", c.reset)
  elseif (t.unknownDeaths or 0) > 0 then
    deathBit = ("%sno deaths from a proven cast%s"):format(c.green, c.reset)
  else
    deathBit = c.green .. "no deaths caused" .. c.reset
  end
  out[#out + 1] = ("  %s%d unkicked cast%s  %s%s dmg%s  %s"):format(
    c.bold, t.unkicked, t.unkicked == 1 and "" or "s", c.reset .. c.bold,
    short(t.damage), c.reset, deathBit)

  if t.unkicked == 0 and t.unknown == 0 then
    out[#out + 1] = ("  %snothing got through all run%s"):format(c.green, c.reset)
  end

  local spells = t:topSpells(opts.top or 8, opts.sort)
  if #spells > 0 then
    -- Two different spell ids can carry the same name -- The Blinding Vale has two
    -- "Light Bolt"s (1235616 and 1238063) -- and two rows with one label read as a
    -- duplicated bug rather than as two spells. Label the collision with the id.
    local seen, dupe = {}, {}
    for _, sp in ipairs(spells) do
      local n = sp.name or "?"
      if seen[n] and seen[n] ~= sp.spellID then dupe[n] = true end
      seen[n] = sp.spellID
    end
    out[#out + 1] = ("  %s-- by spell --%s%s"):format(c.dim, t:sortTag("spells", opts.sort), c.reset)
    for _, sp in ipairs(spells) do
      local label = sp.name or "?"
      if dupe[label] then label = ("%s (%d)"):format(label, sp.spellID or 0) end
      out[#out + 1] = ("  %-28s %s%8s%s  %s%2d cast%s%s%s"):format(
        trunc(label, 28), c.bold, short(sp.damage), c.reset,
        c.dim, sp.count, sp.count == 1 and " " or "s", c.reset,
        sp.deaths > 0 and ("  %s%d death%s%s"):format(c.red, sp.deaths,
          sp.deaths == 1 and "" or "s", c.reset) or "")
    end
  end

  local sources = t:topSources(opts.top or 8, opts.sort)
  if #sources > 1 then
    out[#out + 1] = ("  %s-- by caster --%s%s"):format(c.dim, t:sortTag("sources", opts.sort), c.reset)
    for _, sp in ipairs(sources) do
      out[#out + 1] = ("  %-28s %s%8s%s  %s%2d cast%s%s"):format(
        trunc(sp.name, 28), c.bold, short(sp.damage), c.reset,
        c.dim, sp.count, sp.count == 1 and " " or "s", c.reset)
    end
  end

  -- What the in-game `kickable` column shows, read from the log instead -- and in
  -- every mode the column offers, since the log has the cast and spell counts the
  -- API has no field for. Damage from a cast whose hits named nobody is in the run
  -- total and in no row here, so this table is not expected to sum to it.
  local victims = t:byVictim(opts.sort)
  if #victims > 0 then
    out[#out + 1] = ("  %s-- who ate it (damage from casts that could have been stopped) --%s%s")
      :format(c.dim, t:sortTag("victims", opts.sort), c.reset)
    for _, v in ipairs(victims) do
      out[#out + 1] = ("  %-20s %s%8s%s  %s%3d cast%s  %2d spell%s%s%s"):format(
        trunc(v.name, 20), c.bold, short(v.damage), c.reset,
        c.dim, v.casts, v.casts == 1 and " " or "s",
        v.distinct, v.distinct == 1 and " " or "s", c.reset,
        v.deaths > 0 and ("  %sdied %d%s"):format(c.red, v.deaths, c.reset) or "")
    end
  end

  local players = t:byPlayer(opts.sort)
  if #players > 0 then
    -- R-7: this is a count of chances, not of failures. The log cannot see
    -- whether a player was in range of the caster or busy keeping the group
    -- alive, so the header says chances and the verdict stays with the human.
    out[#out + 1] = ("  %s-- interrupt available when a cast got through (chances, not blame) --%s%s")
      :format(c.dim, t:sortTag("players", opts.sort), c.reset)
    for _, p in ipairs(players) do
      out[#out + 1] = ("  %-20s %s%3d up%s  %s%3d on cd   %3d cc   %3d unknown%s"):format(
        trunc(p.name, 20), c.yellow, p.chances, c.reset, c.dim, p.down, p.cc, p.unknown, c.reset)
    end
  end

  local worst = t:topCasts(opts.top or 5, opts.sort)
  if #worst > 0 then
    out[#out + 1] = ("  %s-- worst single casts --%s%s"):format(c.dim, t:sortTag("worst", opts.sort), c.reset)
    for _, w in ipairs(worst) do
      out[#out + 1] = ("  %spull %-3d%s %-26s %-20s %s%8s%s%s"):format(
        c.dim, w.pull, c.reset, trunc(w.spell or "?", 26), trunc(w.source, 20),
        c.bold, short(w.damage), c.reset,
        w.deaths > 0 and ("  %sKILLED %d%s"):format(c.red, w.deaths, c.reset) or "")
    end
  end

  -- Not every death comes from a cast: a melee killing blow or a ground effect
  -- belongs to nobody's missed kick. Say so, so the run total reconciles with the
  -- death count a damage meter shows for the same fight instead of looking short.
  local attributed = (t.deaths or 0) + (t.unknownDeaths or 0)
  local unattributed = (t.partyDeaths or 0) - attributed
  if unattributed > 0 then
    out[#out + 1] = ("  %s%d further death%s from no tracked cast (melee, ground damage) -- %d of %d accounted for%s")
      :format(c.dim, unattributed, unattributed == 1 and "" or "s",
        attributed, t.partyDeaths, c.reset)
  end

  if t.unknown > 0 then
    out[#out + 1] = ("  %s%d further cast%s (%s dmg%s) not yet proven kickable -- excluded above%s")
      :format(c.dim, t.unknown, t.unknown == 1 and "" or "s", short(t.unknownDamage),
        (t.unknownDeaths or 0) > 0
          and (", %s%d death%s%s"):format(c.red, t.unknownDeaths,
            t.unknownDeaths == 1 and "" or "s", c.reset .. c.dim) or "",
        c.reset)
  end
  return table.concat(out, "\n")
end

-- A single line, for keeping a running total visible between pulls in --follow.
function M.runningLine(t, opts)
  local c = paint((opts or {}).color)
  return ("  %srun so far: %d pull%s, %d unkicked, %s dmg, %d death%s%s"):format(
    c.dim, t.pulls, t.pulls == 1 and "" or "s", t.unkicked, short(t.damage),
    t.deaths, t.deaths == 1 and "" or "s", c.reset)
end

local function esc(s)
  return (tostring(s):gsub('[%c"\\]', function(ch)
    if ch == '"' then return '\\"' elseif ch == "\\" then return "\\\\" end
    return ("\\u%04x"):format(ch:byte())
  end))
end

-- Deliberately hand-rolled: a parser that works on a bare Lua install anywhere,
-- rather than one that needs a JSON rock on his gaming PC.
function M.json(pull, opts)
  local sure, unsure = partition(pull.records, (opts or {}).minDamage)
  local parts = {}
  local function emit(r, proven)
    local deaths = {}
    for who, amount in pairs(r.deaths or {}) do
      deaths[#deaths + 1] = ('{"name":"%s","damage":%d}'):format(esc(who), amount)
    end
    -- Sorted, because the model builds these by iterating a GUID-keyed table and
    -- an unstable order makes two reports of the same pull diff against each other.
    local function who(list)
      local n = {}
      for _, x in ipairs(list or {}) do n[#n + 1] = esc(x.name or "?") end
      table.sort(n)
      for i = 1, #n do n[i] = '"' .. n[i] .. '"' end
      return "[" .. table.concat(n, ",") .. "]"
    end
    local k = r.kicks or {}
    parts[#parts + 1] = ('{"at":%.3f,"spellID":%d,"spell":"%s","source":"%s","damage":%d,'
      .. '"interruptible":%s,"deaths":[%s],"kicksUp":%s,"kicksDown":%s,"cc":%s,"unknown":%s}')
      :format(r.completedAt - pull.startedAt, r.spellID, esc(r.spellName), esc(r.srcName or "?"),
        r.damage or 0, proven and "true" or "null", table.concat(deaths, ","),
        who(k.ready), who(k.down), who(k.cc), who(k.unknown))
  end
  for _, r in ipairs(sure) do emit(r, true) end
  for _, r in ipairs(unsure) do emit(r, false) end
  return ('{"pull":%d,"kind":"%s","name":"%s","duration":%.1f,"outcome":%s,"casts":[%s]}')
    :format(pull.runIndex or pull.index, pull.kind, esc(pull.name or ""), pull.duration or 0,
      pull.outcome and ('"' .. esc(pull.outcome) .. '"') or "null", table.concat(parts, ","))
end

function M.overallJson(t)
  local run = t.run or {}
  local parts = {}
  for _, sp in ipairs(t:topSpells(nil)) do
    parts[#parts + 1] = ('{"spellID":%d,"spell":"%s","casts":%d,"damage":%d,"deaths":%d}')
      :format(sp.spellID, esc(sp.name or "?"), sp.count, sp.damage, sp.deaths)
  end
  local who = {}
  for _, p in ipairs(t:byPlayer()) do
    who[#who + 1] = ('{"name":"%s","available":%d,"onCooldown":%d,"cc":%d,"unknown":%d}')
      :format(esc(p.name), p.chances, p.down, p.cc, p.unknown)
  end
  return ('{"overall":true,"run":%d,"zone":"%s","keystone":%s,"pulls":%d,"bosses":%d,'
    .. '"kills":%d,"combatSeconds":%.1f,"unkicked":%d,"damage":%d,"deaths":%d,'
    .. '"unprovenCasts":%d,"unprovenDamage":%d,"unprovenDeaths":%d,"spells":[%s],"players":[%s]}')
    :format(run.index or 0, esc(run.zone or ""), run.keystone and tostring(run.keystone) or "null",
      t.pulls, t.bosses, t.kills, t.duration or 0, t.unkicked, t.damage, t.deaths,
      t.unknown, t.unknownDamage, t.unknownDeaths or 0,
      table.concat(parts, ","), table.concat(who, ","))
end

return M
