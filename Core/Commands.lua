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
  print("  /uk immune     show casts that were immune to interrupts too")
  print("  /uk min <n>    hide casts under n damage")
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
    print("  The log file WoW writes to disk is unaffected -- post-run analysis of")
    print("  WoWCombatLog.txt can still answer every question this panel wanted to.")
    print("  That file right now: " .. (ns.Logging:Label()))

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
