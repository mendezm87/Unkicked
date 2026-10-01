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

-- --------------------------------------------------------------------- options
local opts = {
  follow = false, fromStart = false, json = false, model = false,
  quietGap = 5, minDamage = 0, color = true, file = nil,
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
local session = Session.new(ns, {
  host = host,
  quietGap = opts.quietGap,
  knowledge = knowledge,
  onPull = function(pull)
    emitted = emitted + 1
    knowledge:save()
    if opts.json then
      io.write(report.json(pull, opts), "\n")
    else
      io.write(report.text(pull, opts), "\n\n")
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
  io.stderr:write(("unkicked: %d lines, %d pulls (%d reported), %d interrupts seen, %d spends"
    .. ", %d spells newly proven kickable%s\n"):format(
    session.lines, session.segments, emitted, session.stats.interrupts, session.stats.spends,
    knowledge.learned, session.skipped > 0 and (", " .. session.skipped .. " lines skipped") or ""))
end
f:close()
