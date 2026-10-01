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
