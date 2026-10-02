#!/usr/bin/env luajit
-- Unkicked :: offline combat-log parser
--
--   luajit parser/unkicked.lua --follow
--   luajit parser/unkicked.lua path/to/WoWCombatLog.txt --model
--   luajit parser/unkicked.lua --follow --json | your-overlay
--
-- Why this exists: patch 12.0.0 made COMBAT_LOG_EVENT_UNFILTERED unregisterable
-- by addons and turned every fallback read (enemy spell id, notInterruptible,
-- party auras, cooldown queries) into a secret value on dungeon maps. The file
-- the client writes to disk was untouched, so the whole feature set still works
-- -- just outside the game, a few seconds behind each pull instead of live.
--
-- The model doing the work is the addon's own Core/, unmodified.

-- The addon root is the directory above this script's. Both relative invocations
-- (`luajit parser/unkicked.lua` from the repo, `luajit unkicked.lua` from inside
-- parser/) have to resolve, so the no-separator cases are spelled out.
local HERE = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local ROOT = HERE:match("^(.*)[/\\][^/\\]*$") or (HERE == "." and ".." or ".")
package.path = HERE .. "/?.lua;" .. package.path

local host = require("host")
local Session = require("session")
local Knowledge = require("knowledge")
local report = require("report")
local Totals = require("totals")

-- --------------------------------------------------------------------- options
local opts = {
  follow = false, fromStart = false, json = false, model = false,
  quietGap = 5, minDamage = 0, color = true, file = nil,
  -- Which segment to print, the way a damage meter toggles current fight vs
  -- overall: "current" = per pull only, "overall" = the run total only,
  -- "both" = each pull as it ends plus the total when the run does.
  segment = "both", top = 8,
  -- What counts. Mythic+ only by default: that is the content the whole model is
  -- aimed at, and an open-world segment on the way to the key is clutter above
  -- the report you actually wanted. Raids are deliberately not included yet.
  scope = "mplus",
  knowledge = HERE .. "/learned-interruptible.lua",
  poll = 1,
}

local function usage()
  io.stderr:write([[
unkicked -- reports the enemy casts nobody stopped, per pull, from WoWCombatLog.txt

  unkicked [FILE] [options]

  --follow, -f        watch a live log and report each pull as it ends
  --from-start        with --follow, replay the existing file first
  --quiet-gap N       seconds of calm that end a trash pull (default 5)
  --min-damage N      hide casts below N damage
  --current           report each pull only, no run total
  --overall           report only the end-of-run total
  --both              both (default): each pull, then the total when the run ends
  --top N             rows per section in the overall report (default 8)
  --all               report every segment, not just mythic+ keys
  --mplus             mythic+ keys only (default)
  --model             append what we believe about each party member's interrupt
  --json              one JSON object per pull on stdout
  --no-color          plain output
  --knowledge PATH    interruptibility knowledge file
  --help

With no FILE, looks in the usual WoW Logs directories for WoWCombatLog.txt.
]])
end

local a, i = arg, 1
while i <= #a do
  local v = a[i]
  if v == "--follow" or v == "-f" then opts.follow = true
  elseif v == "--from-start" then opts.fromStart = true
  elseif v == "--json" then opts.json = true
  elseif v == "--model" then opts.model = true
  elseif v == "--current" then opts.segment = "current"
  elseif v == "--overall" then opts.segment = "overall"
  elseif v == "--both" then opts.segment = "both"
  elseif v == "--all" then opts.scope = "all"
  elseif v == "--mplus" then opts.scope = "mplus"
  elseif v == "--top" then i = i + 1; opts.top = tonumber(a[i]) or 8
  elseif v == "--no-color" then opts.color = false
  elseif v == "--quiet-gap" then i = i + 1; opts.quietGap = tonumber(a[i]) or 5
  elseif v == "--min-damage" then i = i + 1; opts.minDamage = tonumber(a[i]) or 0
  elseif v == "--knowledge" then i = i + 1; opts.knowledge = a[i]
  elseif v == "--poll" then i = i + 1; opts.poll = tonumber(a[i]) or 1
  elseif v == "--help" or v == "-h" then usage(); os.exit(0)
  elseif v:sub(1, 1) == "-" then io.stderr:write("unknown option " .. v .. "\n"); usage(); os.exit(2)
  else opts.file = v end
  i = i + 1
end

-- ------------------------------------------------------------- finding the log
local CANDIDATES = {
  "/Applications/World of Warcraft/_retail_/Logs/WoWCombatLog.txt",
  (os.getenv("HOME") or "") .. "/Applications/World of Warcraft/_retail_/Logs/WoWCombatLog.txt",
  "C:/Program Files (x86)/World of Warcraft/_retail_/Logs/WoWCombatLog.txt",
  "C:/Program Files/World of Warcraft/_retail_/Logs/WoWCombatLog.txt",
  "D:/World of Warcraft/_retail_/Logs/WoWCombatLog.txt",
  "C:/World of Warcraft/_retail_/Logs/WoWCombatLog.txt",
}

local function readable(p)
  local f = p and io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local path = opts.file
if not path then
  for _, c in ipairs(CANDIDATES) do if readable(c) then path = c break end end
end
if not path then
  io.stderr:write("unkicked: no log file given and none found in the usual places.\n"
    .. "         pass the path to WoWCombatLog.txt, and make sure /combatlog is on in game.\n")
  os.exit(1)
end
if not readable(path) then
  io.stderr:write(("unkicked: cannot read %s\n"):format(path))
  os.exit(1)
end

-- ------------------------------------------------------------------ the engine
local ns = host.init(ROOT)
local knowledge = Knowledge.load(opts.knowledge)

local emitted = 0
local skippedPulls, skippedRuns, reportedRuns = 0, {}, 0

-- The mythic+ gate. Interruptibility knowledge is still learned from every line
-- in the file -- that is additive and costs nothing -- but only pulls inside a
-- key window are reported or totalled.
local function counts(pull)
  if opts.scope == "all" then return true end
  return Session.inKeystone(pull)
end
local showPulls = opts.segment ~= "overall"
local showOverall = opts.segment ~= "current"

-- One Totals per run, plus a grand total in case the log covers several runs.
local totals, grand = nil, Totals.new({ zone = "all runs" })

local session = Session.new(ns, {
  host = host,
  quietGap = opts.quietGap,
  knowledge = knowledge,
  onPull = function(pull)
    knowledge:save()
    if not counts(pull) then skippedPulls = skippedPulls + 1; return end
    emitted = emitted + 1
    if not totals or totals.run ~= pull.run then totals = Totals.new(pull.run) end
    totals:add(pull, opts.minDamage)
    grand:add(pull, opts.minDamage)

    if showPulls then
      if opts.json then
        io.write(report.json(pull, opts), "\n")
      else
        io.write(report.text(pull, opts), "\n")
        -- In --follow this is the only thing keeping the run total in view
        -- between pulls; when replaying a file the overall follows anyway.
        if showOverall and opts.follow then
          io.write(report.runningLine(totals, opts), "\n")
        end
        io.write("\n")
      end
    end
    io.stdout:flush()
  end,
  onRun = function(run)
    if opts.scope ~= "all" and not run.keyStart then
      -- Say what was dropped and why. A report that silently omits the five
      -- pulls you remember fighting looks broken, even when it is right.
      skippedRuns[#skippedRuns + 1] = ("%s (%d pulls, no keystone)")
        :format(run.zone or "?", run.pulls or 0)
      return
    end
    reportedRuns = reportedRuns + 1
    if not (showOverall and totals and totals.run == run) then return end
    if opts.json then
      io.write(report.overallJson(totals), "\n")
    else
      io.write(report.overall(totals, opts), "\n\n")
    end
    io.stdout:flush()
  end,
})

-- ------------------------------------------------------------------- the feed
local function sleep(s)
  -- No portable sleep in stock Lua. os.execute is fine at a one-second cadence.
  if package.config:sub(1, 1) == "\\" then
    os.execute(("ping -n %d 127.0.0.1 >NUL"):format(math.max(2, s + 1)))
  else
    os.execute(("sleep %s"):format(s))
  end
end

local f = assert(io.open(path, "rb"))
if opts.follow and not opts.fromStart then
  f:seek("end")
  io.stderr:write(("unkicked: following %s -- reports appear %ds after each pull ends\n")
    :format(path, opts.quietGap))
end

local function drain()
  while true do
    local line = f:read("*l")
    if not line then break end
    session:line(line)
  end
end

if opts.follow then
  while true do
    drain()
    session:idle(os.time())
    sleep(opts.poll)
  end
else
  drain()
  session:flush()
  knowledge:save()
  -- Several instances in one file: the per-run reports are the useful ones, but
  -- a file-wide total is what "overall" means if you pointed this at an archive.
  -- A file-wide total only says something new when more than one run was
  -- actually reported; with the mythic+ gate on, one key makes it a duplicate.
  if showOverall and reportedRuns > 1 and not grand:empty() then
    if opts.json then
      io.write(report.overallJson(grand), "\n")
    else
      io.write(report.overall(grand, opts), "\n\n")
    end
  end
  if opts.scope ~= "all" then
    if #skippedRuns > 0 then
      io.stderr:write("unkicked: not a mythic+ key, skipped -- "
        .. table.concat(skippedRuns, "; ") .. "  (--all to include)\n")
    end
    if emitted == 0 then
      io.stderr:write("unkicked: no mythic+ key in this log. A key is proven by a "
        .. "CHALLENGE_MODE_START line; a plain Mythic dungeon has none. Re-run with "
        .. "--all to report every segment anyway.\n")
    end
  end
  io.stderr:write(("unkicked: %d lines, %d pulls (%d reported), %d interrupts seen, %d spends"
    .. ", %d spells newly proven kickable%s\n"):format(
    session.lines, session.segments, emitted, session.stats.interrupts, session.stats.spends,
    knowledge.learned, session.skipped > 0 and (", " .. session.skipped .. " lines skipped") or ""))
  if opts.scope ~= "all" and skippedPulls > 0 then
    io.stderr:write(("unkicked: %d pulls outside a key window were not counted\n"):format(skippedPulls))
  end
  -- The offline half of the same question the in-game panel answers: a log
  -- written without advanced logging has no unit fields, so there are no damage
  -- amounts and no deaths to attribute. Say so rather than reporting zeroes.
  if not session.advanced then
    io.stderr:write("unkicked: this log was written with ADVANCED_LOG_ENABLED,0 -- "
      .. "no damage or death data is present. Turn on Options > System > Network > "
      .. "Advanced Combat Logging and log the run again.\n")
  end
end
f:close()
