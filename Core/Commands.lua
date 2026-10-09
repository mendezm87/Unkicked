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
  print("  /uk current    panel shows the live segment")
  print("  /uk overall    panel shows the whole key")
  print("  /uk pull <n>   panel shows pull n (see /uk segments)")
  print("  /uk segments   list every segment the panel can show")
  print("  /uk history    keys kept from earlier logins; /uk history <n> shows one")
  print("  /uk forget     clear stored keys, harvested pulls or the live meter")
  print("  |cff808080               -- or just use the panel's clear button|r")
  print("  /uk sort <col> [asc|desc]  sort the panel; or click a column heading")
  print("  /uk pulls      toggle the one-line chat report after each pull")
  print("  /uk log        is the client writing WoWCombatLog.txt right now?")
  print("  /uk log on|off set combat logging (same as /combatlog)")
  print("  /uk why        why the addon reports nothing on this client")
  print("  /uk audit      dump what C_DamageMeter returns on this client")
  print("  |cff808080               -- taken automatically when a key completes|r")
  print("  /uk audit last|copy|trace|on|off|forget   read, copy or stop the stored one")
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
    ns.Panel:Segment(cmd)
    ns.Print("panel showing %s", (ns.Meter:SegmentLabel(ns.db.segment)) or ns.db.segment)

  elseif cmd == "pull" then
    local n = tonumber(arg)
    if not n or not ns.Meter.pulls[n] then
      ns.Print("no pull %s harvested in this run -- |cffffd200/uk segments|r lists what there is",
        tostring(arg ~= "" and arg or "?"))
    else
      ns.Panel:Segment("pull:" .. n)
      ns.Print("panel showing %s", (ns.Meter:SegmentLabel(ns.db.segment)) or ns.db.segment)
    end

  elseif cmd == "history" then
    -- Stored keys (R-37). A finished key's report used to die with the session,
    -- so this list is the thing that was missing entirely.
    local runs = ns.Meter.history or {}
    local n = tonumber(arg)
    if n and runs[n] then
      ns.Panel:Segment("saved:" .. n)
      ns.Print("panel showing %s", (ns.Meter:SegmentLabel(ns.db.segment)) or ns.db.segment)
    elseif #runs == 0 then
      ns.Print(ns.Meter.historyDropped
        and "no stored keys -- what was stored came from a different version and was discarded"
        or "no stored keys yet -- one is kept each time a key ends")
    else
      ns.Print("keys kept from earlier sessions (%d):", #runs)
      for i, run in ipairs(runs) do
        local total = ns.Meter:TotalOf(run.pulls, run.whole)
        print(("  |cff808080%d.|r %s  |cff808080%d kicks, %d deaths|r  |cff505050saved:%d|r")
          :format(i, ns.Meter:RunLabel(run), total and total.kicks or 0,
                  total and total.deaths or 0, i))
      end
      print("  |cff808080/uk history <n> shows one; its own pulls appear in the dropdown under it.|r")
    end

  elseif cmd == "forget" or cmd == "wipe" then
    -- Clearing is the one irreversible thing here, so the bare command states
    -- what it would throw away and makes you name the scope. That is a
    -- confirmation, not an obstruction: every scope below clears on the spot.
    local what = tostring(arg):match("^(%S*)")
    local n = tonumber(what)

    if what == "" then
      -- The scopes and their costs come from Meter:ClearScopes, the same list
      -- the panel's clear box draws, so the two can never describe the same
      -- scope differently.
      ns.Print("clear what? nothing has been cleared yet. The panel's "
        .. "|cffffd200clear|r button offers the same list.")
      for _, sc in ipairs(ns.Meter:ClearScopes()) do
        print(("  |cffffd200/uk forget %s|r%s %s  |cff808080%s|r"):format(
          sc.act, (" "):rep(math.max(1, 9 - #sc.act)), sc.label, sc.note or ""))
      end
      print("  |cffffd200/uk forget <n>|r  one stored key -- |cffffd200/uk history|r for the numbers")
      print("  |cff808080Pulls cannot be re-harvested: the session they came from is gone.|r")

    else
      local ok, msg = ns.Meter:ClearBy(n or what)
      ns.Print("%s", msg)
    end

  elseif cmd == "sort" then
    -- Same thing the column headings do, for anyone who would rather type it.
    local col, dir = tostring(arg):match("^(%S+)%s*(%S*)$")
    if not col or not ns.Meter:Column(col) then
      local names = {}
      for _, c in ipairs(ns.Meter.COLUMNS) do names[#names + 1] = c.key end
      ns.Print("sort by which column? %s", table.concat(names, ", "))
    else
      if dir == "asc" or dir == "desc" then
        ns.db.sort = { by = col, desc = (dir == "desc") }
        ns.Panel:Refresh()
      else
        ns.Panel:SortBy(col)
      end
      local by, desc = ns.Meter:SortSpec()
      ns.Print("panel sorted by %s, %s", by, desc and "descending" or "ascending")
      if ns.Panel.sortNote then
        print("  |cffff9933" .. ns.Panel.sortNote .. "|r")
      end
    end

  elseif cmd == "segments" then
    -- The same list the panel's dropdown draws, for anyone who would rather
    -- type than click -- and so that "there is only one pull in here" is
    -- visible as a fact about the client rather than a missing feature.
    local segs = ns.Meter:Segments()
    ns.Print("segments the panel can show (%d):", #segs)
    for _, seg in ipairs(segs) do
      print(("  %s%-26s|r %s"):format(
        seg.key == ns.db.segment and "|cffffd200" or "|cff808080",
        seg.label, seg.key == ns.db.segment and "<- showing" or ("|cff505050" .. seg.key .. "|r")))
    end
    if #ns.Meter.pulls <= 1 and ns.Meter.run then
      print("  |cff808080inside a key the amounts stay secret until you leave the map,|r")
      print("  |cff808080so there is usually one harvestable segment, not one per pull.|r")
    end

  elseif cmd == "pulls" then
    ns.db.pullReport = not ns.db.pullReport
    ns.Print(ns.db.pullReport and "reporting kick counts in chat after each pull"
      or "no chat report after pulls")

  elseif cmd == "audit" then
    -- A real +13 showed 3 deaths in the panel where the combat log had 6 (all
    -- three of one player's were missing). Nothing on this Mac can tell whether
    -- that is Blizzard's Deaths list, the deathRecapID filter, or our join, so
    -- this dumps the raw rows and lets the next run answer it.
    --
    -- It is taken automatically at the end of a key now, because typing it by
    -- hand before logging out was forgotten every time -- and the logout
    -- destroys the sessions it reads. These subcommands are for reading what
    -- was already taken.
    if arg == "last" or arg == "stored" then
      local stored = ns.Meter:StoredAudits()
      if #stored == 0 then
        ns.Print("no audit stored yet -- one is taken when a key completes")
      else
        for i, e in ipairs(stored) do
          ns.Print("audit %d: %s%s, restrictions %s%s", i,
            e.map or "no map", e.level and ("+" .. e.level) or "",
            e.restricted and "active" or "lifted",
            i == 1 and "" or " (older)")
          if i == 1 then
            for _, line in ipairs(e.lines) do print(line) end
          else
            print(("  |cff808080%d lines -- the panel's audit button copies them|r"):format(#e.lines))
          end
        end
      end
    elseif arg == "trace" then
      -- The one section worth reading on its own: it is short, it is the thing
      -- the run-total shortfall turns on, and it is readable mid-key rather
      -- than only after the automatic capture.
      ns.Print("harvest trace -- read k/d/dmg, the baseline it was differenced against, the delta recorded")
      for _, line in ipairs(ns.Meter:TraceLines()) do print(line) end
    elseif arg == "copy" then
      ns.Panel:AuditBox(true)
    elseif arg == "off" then
      ns.db.autoAudit = false
      ns.Print("no automatic audit; /uk audit still works by hand")
    elseif arg == "on" then
      ns.db.autoAudit = true
      ns.Print("an audit will be taken when a key completes, and again when restrictions lift")
    elseif arg == "forget" then
      ns.Print("discarded %d stored audit(s)", ns.Meter:ForgetAudits())
    else
      ns.Meter:Audit()
      ns.Meter:AuditCapture("asked for")
    end

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
