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
    c.dim, clock(r.completedAt - t0), r.spellName, trunc(r.srcName or "?", 22),
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
    c.bold, pull.index, label, clock(pull.duration or 0), #sure, short(dmg), c.reset)

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
    for _, k in ipairs(pull.kicks or {}) do
      local src = k.exact and "from log" or (k.learned and "learned" or "base")
      local cd = k.cdMs and ("%.1fs"):format(k.cdMs / 1000) or "  -  "
      out[#out + 1] = ("  %s%-16s %-18s %-18s %5s  %s%s%s"):format(c.dim,
        k.name, k.spec or k.class or "?", k.spell or "unknown",
        cd, k.spell and src or "spec unknown", k.talent and (" +" .. k.talent) or "", c.reset)
    end
  end
  return table.concat(out, "\n")
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
    :format(pull.index, pull.kind, esc(pull.name or ""), pull.duration or 0,
      pull.outcome and ('"' .. esc(pull.outcome) .. '"') or "null", table.concat(parts, ","))
end

return M
