-- Unkicked :: Commands.lua

local ADDON, ns = ...

SLASH_UNKICKED1 = "/unkicked"
SLASH_UNKICKED2 = "/uk"

local function usage()
  ns.Print("commands:")
  print("  /uk            toggle the panel")
  print("  /uk clear      drop the current list")
  print("  /uk model      what the addon believes about each party interrupt")
  print("  /uk data       which build the cooldown and CC tables came from")
  print("  /uk lock       stop the panel being dragged")
  print("  /uk reset      put the panel back in the middle of the screen and show it")
  print("  /uk immune     show casts that were immune to interrupts too")
  print("  /uk min <n>    hide casts under n damage")
  print("  /uk kicks      interrupts pressed per player, this pull and this key")
  print("  /uk current    panel shows the current pull")
  print("  /uk overall    panel shows the whole key")
  print("  /uk pulls      toggle the one-line chat report after each pull")
  print("  /uk log        is the client writing WoWCombatLog.txt right now?")
  print("  /uk log on|off set combat logging (same as /combatlog)")
  print("  /uk why        why the addon reports nothing on this client")
end

SlashCmdList.UNKICKED = function(msg)
  local cmd, arg = msg:lower():match("^(%S*)%s*(.-)$")

  if cmd == "" then
    ns.Panel:Toggle()

  elseif cmd == "clear" then
    ns.Cast:Wipe()
    ns.Print("cleared")

  elseif cmd == "model" then
    ns.Print("interrupt model:")
    for guid in pairs(ns.Kick.players) do
      local state, detail = ns.Kick:StateAt(guid, GetTime())
      print(("  %s -- %s%s"):format(ns.Kick:Describe(guid), state,
        detail and (" (" .. tostring(detail) .. ")") or ""))
    end

  elseif cmd == "data" then
    ns.Print("cooldowns from build %s, CC table from build %s",
      ns.DATA_BUILD or "?", ns.CC_BUILD or "?")
    if ns.staleData then
      ns.Print("|cffff9933you are on a different client build -- regenerate the data files|r")
    end

  elseif cmd == "log" then
    if arg == "on" or arg == "off" then
      ns.Logging:Set(arg == "on")
    end
    -- Asked explicitly, so spend a call rather than serve the cache.
    ns.Logging:Query(true)
    ns.Print("combat log: %s", (ns.Logging:Label()))
    for _, l in ipairs(ns.Logging:Lines()) do print("  " .. l.text) end

  elseif cmd == "kicks" then
    if not ns.Meter:Available() then
      ns.Print("C_DamageMeter is not available on this client, so there is no live view at all")
    else
      ns.Meter:Report()
      local snap = ns.Meter:Snapshot("current")
      if snap then
        print(("  this pull: %d kicks, %d deaths, %s taken")
          :format(snap.kicks, snap.deaths, ns.Short(snap.taken)))
      else
        print("  this pull: in combat -- the numbers are secret until it ends")
      end
    end

  elseif cmd == "current" or cmd == "overall" then
    ns.Print("panel showing %s", ns.Panel:Segment(cmd) == "overall" and "the whole key" or "this pull")

  elseif cmd == "pulls" then
    ns.db.pullReport = not ns.db.pullReport
    ns.Print(ns.db.pullReport and "reporting kick counts in chat after each pull"
      or "no chat report after pulls")

  elseif cmd == "why" then
    ns.Print("what this client allows:")
    if ns.blocked["COMBAT_LOG_EVENT_UNFILTERED"] then
      print("  |cffff2020COMBAT_LOG_EVENT_UNFILTERED|r -- not registerable since 12.0.0.")
      print("  Without it there is no cast, damage, death or interrupt feed at all.")
    end
    print("  |cffff9933Secret values|r -- in a dungeon, raid, M+ or encounter, anything")
    print("  read about a unit that is not you or your pet (enemy spell IDs, the")
    print("  notInterruptible flag, party auras, cooldowns) comes back as a secret")
    print("  value that addon code may hold but never compare or test.")
    print("  Restrictions active right now: " ..
      (ns.Restricted() and "|cffff2020yes|r" or "|cff40c860no|r"))
    if ns.Meter:Available() then
      print("  |cff40c860C_DamageMeter|r -- the sanctioned replacement. The server aggregates")
      print("  and hands back a finished list, so per-player |cffffd200interrupts|r, deaths and")
      print("  damage taken DO work live, per pull and per key. In combat the amounts")
      print("  are secret values that can be shown but not read, which is why the")
      print("  panel can display them and still not be able to sort or total them.")
      print("  What it cannot give: whether an enemy cast was interruptible, or which")
      print("  cast got through. Those are not in the API. |cffffd200/uk kicks|r for the live view.")
    else
      print("  |cffff2020C_DamageMeter|r -- not available, so there is no live view either.")
    end
    print("  The log file WoW writes to disk is unaffected -- post-run analysis of")
    print("  WoWCombatLog.txt can still answer every question this panel wanted to.")
    print("  That file right now: " .. (ns.Logging:Label()))

  elseif cmd == "reset" then
    ns.Panel:Reset()
    ns.Print("panel reset to the centre of the screen and shown")

  elseif cmd == "lock" then
    ns.db.locked = not ns.db.locked
    ns.Print(ns.db.locked and "panel locked" or "panel unlocked")

  elseif cmd == "immune" then
    ns.db.onlyInterruptible = not ns.db.onlyInterruptible
    ns.Print(ns.db.onlyInterruptible and "showing interruptible casts only"
      or "showing immune casts too")

  elseif cmd == "min" then
    local n = tonumber(arg)
    if n then
      ns.db.minDamage = n
      ns.Panel:Refresh()
      ns.Print("hiding casts under %d damage", n)
    else
      usage()
    end

  else
    usage()
  end
end
