-- Unkicked :: tests/run.lua
--   luajit tests/run.lua
--
-- Loads the Core modules against the stubbed client and replays synthetic
-- combat logs. Covers the requirements that are easy to get quietly wrong:
-- R-3 (the learning rule and its three guards), R-6 (CC is not blame),
-- R-8 (damage and death attribution), R-2 (a stopped cast is not recorded).

package.path = "./tests/?.lua;" .. package.path
local stub = dofile("tests/wow_stub.lua")

-- ------------------------------------------------------------------- harness
local pass, fail = 0, 0
local function ok(cond, what)
  if cond then pass = pass + 1; print("  ok   " .. what)
  else fail = fail + 1; print("  FAIL " .. what) end
end
local function eq(a, b, what)
  ok(a == b, ("%s  (got %s, want %s)"):format(what, tostring(a), tostring(b)))
end
local function near(a, b, tol, what)
  ok(a and math.abs(a - b) <= tol, ("%s  (got %s, want ~%s)"):format(what, tostring(a), tostring(b)))
end

-- ------------------------------------------------------------- load the addon
local ns
local function loadAddon()
  ns = {}
  local files = {
    "Data/InterruptData.lua", "Data/CCData.lua", "Data/Interruptible.lua",
    "Core/Init.lua", "Core/Logging.lua", "Core/Meter.lua", "Core/Nameplates.lua",
    "Core/KickTracker.lua", "Core/CastTracker.lua",
  }
  for _, f in ipairs(files) do
    local chunk = assert(loadfile(f), "cannot load " .. f)
    chunk("Unkicked", ns)
  end
  UnkickedDB = nil
  stub.fire("ADDON_LOADED", "Unkicked")
  stub.ns = ns
  return ns
end

local PLAYER = { guid = "P-self",  name = "Selfy",  class = "MAGE",        spells = { [2139] = true } }
local DK     = { guid = "P-dk",    name = "Grimm",  class = "DEATHKNIGHT" }
local WAR    = { guid = "P-war",   name = "Thrack", class = "WARRIOR" }
local ROG    = { guid = "P-rog",   name = "Slink",  class = "ROGUE" }

local function freshParty()
  stub.setParty({ PLAYER, DK, WAR, ROG })
  stub.fire("GROUP_ROSTER_UPDATE")
  stub.fire("PLAYER_REGEN_DISABLED")
end

local function spend(actor, spellID)
  stub.cleu("SPELL_CAST_SUCCESS", stub.friend(actor.guid, actor.name), nil, { spellID, "Interrupt", 1 })
end
local function connect(actor, spellID, target, targetSpell)
  stub.cleu("SPELL_INTERRUPT", stub.friend(actor.guid, actor.name),
    stub.enemy(target or "E-1", "Caster"), { spellID, "Interrupt", 1, targetSpell or 999, "Bolt", 1 })
end

-- =============================================================== generated data
print("\n[data] generated tables")
loadAddon()
eq(ns.DATA_BUILD, "12.1.0.69933", "interrupt data pinned to a build")
eq(ns.INTERRUPTS[1766].baseMs, 15000, "Kick base cooldown is 15s")
eq(ns.INTERRUPTS[57994].baseMs, 12000, "Wind Shear base cooldown is 12s")
eq(ns.INTERRUPTS[187707].baseMs, 15000, "Muzzle base cooldown is 15s, not 24s")
eq(ns.INTERRUPTS[351338].baseMs, 20000, "Quell base cooldown is 20s, not 40s")
eq(ns.INTERRUPTS[15487].baseMs, 30000, "Silence base cooldown is 30s, not 45s")
eq(ns.INTERRUPTS[2139].baseMs, 25000, "Counterspell base cooldown is 25s")
ok(ns.INTERRUPTS[47528].eligible, "Mind Freeze is talent-eligible (Coldthirst)")
eq(ns.INTERRUPTS[47528].floorMs, 12000, "Mind Freeze floor is 12s")
ok(ns.INTERRUPTS[6552].eligible, "Pummel is talent-eligible (Honed Reflexes)")
eq(ns.INTERRUPTS[6552].floorMs, 13500, "Pummel floor is 13.5s")
ok(not ns.INTERRUPTS[1766].eligible, "Kick has no reduction talent, so is not eligible")
ok(not ns.INTERRUPTS[15487].eligible, "Silence has no reduction talent")
ok(ns.IS_INTERRUPT[1766] and not ns.IS_INTERRUPT[12345], "reverse index only holds interrupts")
eq(ns.CC_AURAS[15487], "SILENCED", "Silence is in the blocking-aura table")
ok(ns.CC_AURAS[408] ~= nil, "Kidney Shot is a blocking aura")

-- =============================================================== roster binding
print("\n[roster] interrupt binding")
loadAddon(); freshParty()
eq(ns.Kick.players[DK.guid].spellID, 47528, "DK binds to Mind Freeze from class alone")
eq(ns.Kick.players[WAR.guid].spellID, 6552, "Warrior binds to Pummel from class alone")
eq(ns.Kick.players[PLAYER.guid].spellID, 2139, "player resolves own spell via IsPlayerSpell")

-- Hunter/Druid/Priest are ambiguous from class, so they must stay unbound.
loadAddon()
stub.setParty({ PLAYER, { guid = "P-hunt", name = "Arrow", class = "HUNTER" } })
stub.fire("GROUP_ROSTER_UPDATE"); stub.fire("PLAYER_REGEN_DISABLED")
eq(ns.Kick.players["P-hunt"].spellID, nil, "Hunter stays unbound (Muzzle vs Counter Shot)")
eq(select(1, ns.Kick:StateAt("P-hunt", stub.now())), "unknown", "unbound Hunter reports unknown, not ready")
spend({ guid = "P-hunt", name = "Arrow" }, 147362)
eq(ns.Kick.players["P-hunt"].spellID, 147362, "Hunter binds on first observed cast")

-- ================================================== R-3 the learning rule
print("\n[R-3] cooldown learning, downward-only and talent-gated")

-- (a) eligible spec, interval below base and above floor -> learn it
loadAddon(); freshParty()
spend(DK, 47528); connect(DK, 47528, "E-1", 999)
stub.advance(12.4)
spend(DK, 47528)
near(ns.Kick.players[DK.guid].connectMs, 12400, 50, "DK post-connect cooldown learned at 12.4s")
eq(ns.Kick.players[DK.guid].whiffMs, nil, "a connect does not teach the whiff cooldown")

-- (b) same spec, interval BELOW the talent floor -> rejected as noise
loadAddon(); freshParty()
spend(DK, 47528); connect(DK, 47528, "E-1", 999)
stub.advance(6)
spend(DK, 47528)
eq(ns.Kick.players[DK.guid].connectMs, nil, "6s interval is below the 12s floor, so not learned")
eq(ns.Kick.players[DK.guid].anomalies, 1, "sub-floor interval is recorded as an anomaly")

-- (c) ineligible spec, short interval -> clamped to base, never learned
loadAddon(); freshParty()
spend(ROG, 1766)
stub.advance(11)
spend(ROG, 1766)
eq(ns.Kick.players[ROG.guid].whiffMs, nil, "Rogue has no reduction talent, so 11s is not learned")
eq(ns.Kick.players[ROG.guid].anomalies, 1, "ineligible short interval is flagged, not adopted")

-- (d) longer-than-base interval is never learned in either direction
loadAddon(); freshParty()
spend(WAR, 6552)
stub.advance(40)
spend(WAR, 6552)
eq(ns.Kick.players[WAR.guid].whiffMs, nil, "a 40s gap teaches nothing -- they just did not press it")
eq(ns.Kick.players[WAR.guid].anomalies, nil, "a long gap is not an anomaly either")

-- (e) minimum wins: a later, longer measurement must not widen the estimate
loadAddon(); freshParty()
spend(WAR, 6552); stub.advance(13.6); spend(WAR, 6552)
near(ns.Kick.players[WAR.guid].whiffMs, 13600, 50, "first measurement adopted")
stub.advance(14.5); spend(WAR, 6552)
near(ns.Kick.players[WAR.guid].whiffMs, 13600, 50, "later longer measurement does not widen it")

-- ================================================ R-9 two cooldowns per player
print("\n[R-9] refund talents learn two cooldowns")
loadAddon(); freshParty()
-- Intervals must sit clearly below base: an interval within CD_EPSILON_MS of
-- base is indistinguishable from base and is deliberately not learned.
spend(DK, 47528)                      -- whiff: no SPELL_INTERRUPT follows
stub.advance(13.5); spend(DK, 47528)
connect(DK, 47528, "E-1", 999)        -- this one connects
stub.advance(12.2); spend(DK, 47528)
local p = ns.Kick.players[DK.guid]
near(p.whiffMs, 13500, 50, "post-whiff cooldown learned separately")
near(p.connectMs, 12200, 50, "post-connect cooldown learned separately")
ok(p.connectMs and p.whiffMs and p.connectMs < p.whiffMs, "connect cooldown is the shorter of the two")

-- and the epsilon guard itself: a gap only marginally under base is kept at base
loadAddon(); freshParty()
spend(DK, 47528)
stub.advance(14.8); spend(DK, 47528)
eq(ns.Kick.players[DK.guid].whiffMs, nil, "a gap within epsilon of base is not learned")

-- the active cooldown must follow how the LAST spend resolved
loadAddon(); freshParty()
spend(DK, 47528); connect(DK, 47528, "E-1", 999)
stub.advance(12.5); spend(DK, 47528); connect(DK, 47528, "E-1", 999)
stub.advance(12.6)
eq(select(1, ns.Kick:StateAt(DK.guid, stub.now())), "ready", "after a connect, 12.6s is enough")
loadAddon(); freshParty()
spend(DK, 47528)
stub.advance(12.6)
eq(select(1, ns.Kick:StateAt(DK.guid, stub.now())), "down", "after a whiff, 12.6s is NOT enough")

-- =========================================== R-3 spend tracking off CAST_SUCCESS
print("\n[R-3] a whiffed kick still burns the cooldown")
loadAddon(); freshParty()
spend(ROG, 1766)                      -- kicked into an immune cast: no INTERRUPT
stub.advance(5)
local state, detail = ns.Kick:StateAt(ROG.guid, stub.now())
eq(state, "down", "whiffed kick counts as spent")
near(detail, 10, 0.2, "10s remaining on a 15s cooldown")
stub.advance(10.1)
eq(select(1, ns.Kick:StateAt(ROG.guid, stub.now())), "ready", "ready again after the full 15s")

-- ===================================================== R-10 cold start handling
print("\n[R-10] cold start")
loadAddon(); freshParty()
eq(select(1, ns.Kick:StateAt(ROG.guid, stub.now())), "unknown", "unseen player in first seconds is unknown")
stub.advance(ns.COLD_START + 1)
eq(select(1, ns.Kick:StateAt(ROG.guid, stub.now())), "ready", "past the cold-start window, assume ready")

-- ============================================================= R-6 CC is not blame
print("\n[R-6] cannot-act is its own reason")
loadAddon(); freshParty()
stub.advance(ns.COLD_START + 1)
stub.cleu("SPELL_AURA_APPLIED", stub.enemy("E-1", "Caster"), stub.friend(ROG.guid, ROG.name),
  { 408, "Kidney Shot", 1, "DEBUFF" })
local s, d = ns.Kick:StateAt(ROG.guid, stub.now())
eq(s, "cc", "stunned player reports cc, not ready")
eq(d, "STUNNED", "the mechanic is named")
stub.advance(4)
stub.cleu("SPELL_AURA_REMOVED", stub.enemy("E-1", "Caster"), stub.friend(ROG.guid, ROG.name),
  { 408, "Kidney Shot", 1, "DEBUFF" })
stub.advance(1)
eq(select(1, ns.Kick:StateAt(ROG.guid, stub.now())), "ready", "ready again once the stun falls off")

-- an aura with no blocking mechanic must not register as CC
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
stub.cleu("SPELL_AURA_APPLIED", stub.enemy("E-1", "Caster"), stub.friend(ROG.guid, ROG.name),
  { 589, "Shadow Word: Pain", 1, "DEBUFF" })
eq(select(1, ns.Kick:StateAt(ROG.guid, stub.now())), "ready", "a DoT is not a cannot-act reason")

-- ====================================================== R-1/R-2 cast recording
print("\n[R-1/R-2] which casts get recorded")
local E = stub.enemy("E-boss", "Caster")
local function castStart(spellID) stub.cleu("SPELL_CAST_START", E, nil, { spellID, "Big Bolt", 1 }) end
local function castDone(spellID) stub.cleu("SPELL_CAST_SUCCESS", E, nil, { spellID, "Big Bolt", 1 }) end

loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(2); castDone(777)
eq(#ns.Cast.records, 1, "a cast that started and completed is recorded")
eq(ns.Cast.records[1].spellName, "Big Bolt", "the spell name is captured")
eq(ns.Cast.records[1].interruptible, nil, "no nameplate means interruptibility is unknown, not assumed")

-- interrupted: nothing recorded
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(1)
connect(ROG, 1766, "E-boss", 777)
castDone(777)
eq(#ns.Cast.records, 0, "a cast somebody stopped is not an unkicked cast")

-- a stun that breaks the cast also produces SPELL_INTERRUPT, so it counts as stopped
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(1)
connect(WAR, 408, "E-boss", 777)
castDone(777)
eq(#ns.Cast.records, 0, "a cast broken by a stun is also 'stopped'")

-- instant casts (no START) are not recorded
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castDone(888)
eq(#ns.Cast.records, 0, "a cast we never saw start is not recorded")

-- caster dies mid-cast
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777)
stub.cleu("UNIT_DIED", nil, E, {})
castDone(777)
eq(#ns.Cast.records, 0, "a caster that died mid-cast completed nothing")

-- friendly casts are ignored entirely
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
stub.cleu("SPELL_CAST_START", stub.friend("P-rog", "Slink"), nil, { 777, "Big Bolt", 1 })
stub.cleu("SPELL_CAST_SUCCESS", stub.friend("P-rog", "Slink"), nil, { 777, "Big Bolt", 1 })
eq(#ns.Cast.records, 0, "a party member's own cast is not an enemy cast")

-- ====================================================== R-1 availability snapshot
print("\n[R-1] the snapshot is taken at cast START")
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
spend(ROG, 1766)              -- Rogue kick now down for 15s
castStart(777)
stub.advance(2); castDone(777)
local rec = ns.Cast.records[1]
local readyNames, downNames = {}, {}
for _, r in ipairs(rec.kicks.ready) do readyNames[r.name] = true end
for _, r in ipairs(rec.kicks.down) do downNames[r.name] = true end
ok(downNames["Slink"], "Rogue who just kicked is listed as on cooldown")
ok(readyNames["Grimm"] and readyNames["Thrack"], "DK and Warrior are listed as available")
eq(#rec.kicks.cc, 0, "nobody was in CC")

-- ======================================================= R-8 damage attribution
print("\n[R-8] damage and death attribution")
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(2); castDone(777)
stub.cleu("SPELL_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 777, "Big Bolt", 1, 50000 })
stub.cleu("SPELL_DAMAGE", E, stub.friend(WAR.guid, WAR.name), { 777, "Big Bolt", 1, 30000 })
eq(ns.Cast.records[1].damage, 80000, "damage from the same spell and source accumulates")
stub.cleu("SPELL_PERIODIC_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 777, "Big Bolt", 1, 5000 })
eq(ns.Cast.records[1].damage, 85000, "DoT ticks keep accumulating after the cast finished")

-- damage from a different spell must not land on this record
stub.cleu("SPELL_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 999, "Something Else", 1, 99999 })
eq(ns.Cast.records[1].damage, 85000, "unrelated spell damage is not attributed")

-- death inside the window
stub.advance(2)
stub.cleu("UNIT_DIED", nil, stub.friend(ROG.guid, ROG.name), {})
eq(ns.Cast.records[1].deaths["Slink"], 55000, "death within the window is attributed to the cast")

-- death outside the window
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(2); castDone(777)
stub.cleu("SPELL_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 777, "Big Bolt", 1, 10 })
stub.advance(ns.DEATH_WINDOW + 2)
stub.cleu("UNIT_DIED", nil, stub.friend(ROG.guid, ROG.name), {})
eq(next(ns.Cast.records[1].deaths), nil, "a death long after the hit is not attributed")

-- damage stops attaching once the window closes
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(2); castDone(777)
stub.advance(ns.DAMAGE_WINDOW + 1)
stub.cleu("SPELL_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 777, "Big Bolt", 1, 1234 })
eq(ns.Cast.records[1].damage, 0, "damage after the attribution window is dropped")

-- ============================== R-19 overlapping casts of the SAME spell
-- From a real Kings' Rest log: "Shadow of Zul" recast Shadow Barrage ten times in
-- 25s, so up to seven records sat inside DAMAGE_WINDOW at once. Crediting every
-- matching open record reported 4.7m for a spell that actually did 957k, and one
-- UNIT_DIED was reported as five separate kills.
print("\n[R-19] a hit belongs to exactly one cast, and a death to exactly one cast")
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(1); castDone(777)          -- cast A
stub.advance(2)
castStart(777); stub.advance(1); castDone(777)          -- cast B, A still open
eq(#ns.Cast.records, 2, "both casts of the same spell are recorded")
stub.cleu("SPELL_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 777, "Big Bolt", 1, 40000 })
eq(ns.Cast.records[1].damage, 40000, "the hit lands on the most recent completed cast")
eq(ns.Cast.records[2].damage, 0, "and is NOT double-counted onto the earlier one")
local casts, dmg = ns.Cast:Summary()
eq(dmg, 40000, "so the pull total is the damage that actually happened")

stub.advance(1)
stub.cleu("UNIT_DIED", nil, stub.friend(ROG.guid, ROG.name), {})
eq(ns.Cast.records[1].deaths["Slink"], 40000, "the cast that hit them last claims the death")
eq(next(ns.Cast.records[2].deaths), nil, "the earlier overlapping cast does not also claim it")
local _, _, deaths = ns.Cast:Summary()
eq(deaths, 1, "one UNIT_DIED counts as one death, not one per overlapping cast")

-- a hit that arrives before a later cast completed still belongs to the earlier one
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(1); castDone(777)
stub.cleu("SPELL_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 777, "Big Bolt", 1, 7000 })
castStart(777); stub.advance(1); castDone(777)
eq(ns.Cast.records[2].damage, 7000, "a tick before the recast stays with the cast that was live")
eq(ns.Cast.records[1].damage, 0, "the later cast does not retroactively absorb it")

-- ============================================================= summary + wipe
print("\n[misc] summary and wipe")
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
castStart(777); stub.advance(1); castDone(777)
stub.cleu("SPELL_DAMAGE", E, stub.friend(ROG.guid, ROG.name), { 777, "Big Bolt", 1, 1000 })
castStart(778); stub.advance(1); castDone(778)
local casts, dmg = ns.Cast:Summary()
eq(casts, 2, "summary counts both casts")
eq(dmg, 1000, "summary totals the damage")
ns.Cast:Wipe()
eq(#ns.Cast.records, 0, "wipe clears the list")

-- ====================================== 12.0 restrictions (R-15, R-16, R-17)
-- These pin the client's new refusals so a future "it reports nothing" bug is
-- distinguishable from the client simply not handing us the data.
print("\n[R-15] Midnight restrictions are handled, not hit")
loadAddon()
ok(ns.blocked["COMBAT_LOG_EVENT_UNFILTERED"] == true,
  "CLEU registration is refused up front, never attempted")
ok(not stub.registered("COMBAT_LOG_EVENT_UNFILTERED"),
  "RegisterEvent is never called for the forbidden event")
ok(stub.registered("NAME_PLATE_UNIT_ADDED"),
  "unrestricted events still register normally")

print("\n[R-16] secret values are held, never tested")
eq(ns.Plain(42), 42, "a plain value passes through")
eq(ns.Plain(stub.secret(42)), nil, "a secret value is reported as unknown")
eq(ns.IsSecret(stub.secret(true)), true, "secrets are detected")
eq(ns.IsSecret(false), false, "plain false is not a secret")

print("\n[R-17] an unreadable interruptible flag reads as unknown, not as yes")
loadAddon(); freshParty(); stub.advance(ns.COLD_START + 1)
stub.nameplates["nameplate1"] = E.guid
stub.setCasting("nameplate1", { name = "Big Bolt", spellID = 777,
  notInterruptible = stub.secret(false) })
stub.fire("UNIT_SPELLCAST_START", "nameplate1")
eq(ns.Nameplates:Interruptible(E.guid, 777), nil,
  "a secret notInterruptible yields nil (unknown), not true")

print("\n[R-18] a secret GUID is never used as a table key")
loadAddon(); freshParty()
-- The real 12.x client returns a secret string from UnitGUID for any nameplate
-- on a restricted map. Indexing with it is a hard error, so the module must drop
-- the unit rather than store it.
stub.nameplates["nameplate1"] = stub.secret(E.guid)
stub.setCasting("nameplate1", { name = "Big Bolt", spellID = 777, notInterruptible = false })
ok(pcall(stub.fire, "NAME_PLATE_UNIT_ADDED", "nameplate1"),
  "NAME_PLATE_UNIT_ADDED survives a secret GUID")
ok(pcall(stub.fire, "UNIT_SPELLCAST_START", "nameplate1"),
  "UNIT_SPELLCAST_START survives a secret GUID")
ok(pcall(stub.fire, "NAME_PLATE_UNIT_REMOVED", "nameplate1"),
  "NAME_PLATE_UNIT_REMOVED survives a secret GUID")
eq(ns.Nameplates:Interruptible(stub.secret(E.guid), 777), nil,
  "a secret GUID reads as unknown rather than erroring")
eq(ns.GUID("nameplate1"), nil, "ns.GUID refuses a secret GUID")
stub.nameplates["nameplate1"] = nil

-- Same hazard on the party side: the roster scan keys players by GUID.
stub.units.party1 = { guid = stub.secret(DK.guid), name = DK.name, class = DK.class }
ok(pcall(function() ns.Kick:Rebuild() end),
  "roster rebuild survives a secret party GUID")
eq(ns.Kick.players[DK.guid], nil,
  "a player whose GUID is unusable is dropped, not keyed by a secret")

-- ======================================== R-21: is the client writing the log?
-- The offline parser is the whole product now, and it is worthless against a run
-- you forgot to /combatlog. The panel reports that state -- and must never claim
-- "off" when the truth is "the rate limiter would not tell me".
print("\n[logging] combat-log state indicator")

local function freshLogging()
  local n = loadAddon()
  stub.logging.calls, stub.logging.budget = 0, math.huge
  return n
end

-- on + advanced: the parser will get everything
ns = freshLogging()
stub.logging.on, stub.logging.advanced = true, true
eq(ns.Logging:Verdict(), "ready", "logging on with advanced data reads as ready")

-- on, advanced off: a log with no unit fields is not a usable log
ns = freshLogging()
stub.logging.on, stub.logging.advanced = true, false
eq(ns.Logging:Verdict(), "basic", "advanced logging off is reported separately, not as ready")

ns = freshLogging()
stub.logging.on, stub.logging.advanced = false, true
eq(ns.Logging:Verdict(), "off", "logging off reads as off")

-- An unreadable cvar must not masquerade as "advanced is off".
ns = freshLogging()
stub.logging.on, stub.logging.advanced = true, nil
eq(ns.Logging:Verdict(), "unknown-advanced",
  "an unreadable advanced cvar reads as unknown, not as off")

-- THE important one. Over the shared 5-per-10s budget LoggingCombat returns nil.
-- Treating that as false would tell you to /combatlog while you already were.
ns = freshLogging()
stub.logging.on, stub.logging.advanced = true, true
eq(ns.Logging:Verdict(), "ready", "first query answers")
stub.logging.budget = stub.logging.calls      -- every further call is rate limited
stub.advance(30)
eq(ns.Logging:Verdict(), "ready", "a rate limited query keeps the last known state")
local _, _, limited = ns.Logging:State()
eq(limited, true, "a rate limited query is flagged stale")
ok(ns.Logging:Label():find("stale", 1, true) ~= nil, "the panel label says stale")

-- Never seen an answer at all is distinct from "off".
ns = freshLogging()
stub.logging.budget = 0
eq(ns.Logging:Verdict(), "unknown", "with no answer ever, the state is unknown -- not off")

-- And the budget is respected: a panel refresh every frame must not poll.
ns = freshLogging()
stub.logging.on = true
ns.Logging:Query(true)
local spent = stub.logging.calls
for _ = 1, 50 do ns.Logging:Query() end
eq(stub.logging.calls, spent, "50 cached queries inside the gap spend no further calls")
stub.advance(6)
ns.Logging:Query()
eq(stub.logging.calls, spent + 1, "one call is spent once the rate-limit gap elapses")

-- Entering a dungeon with logging off says so, once.
ns = freshLogging()
stub.logging.on = false
stub.instance = "party"
local said = 0
local realPrint = print
print = function(...) said = said + 1; realPrint(...) end
stub.fire("PLAYER_ENTERING_WORLD")
stub.fire("PLAYER_REGEN_DISABLED")
stub.fire("PLAYER_REGEN_DISABLED")
print = realPrint
eq(said, 1, "the logging-off reminder fires once per zone, not once per pull")
stub.instance = nil

-- ===================================================================== the panel
-- R-19. The in-game panel has never rendered in a real 12.x client -- there is no
-- WoW install on the build machine -- so this does not prove it looks right. What
-- it does prove is that the file loads, the frame is created, it is SHOWN by
-- default, and Refresh() survives being called with no data: the failure modes
-- that leave an empty screen and no error anyone can read.
print("\n[panel] it loads, builds and shows itself")
do
  for _, f in ipairs({ "UI/Panel.lua", "Core/Commands.lua" }) do
    local chunk = assert(loadfile(f), "cannot load " .. f)
    chunk("Unkicked", ns)
  end
  ok(ns.Panel ~= nil, "UI/Panel.lua loads outside the game")
  stub.fire("PLAYER_LOGIN")
  local f = stub.frames["UnkickedPanel"]
  ok(f ~= nil, "the panel frame is created at login")
  ok(f and f:IsShown(), "and shown by default, without needing /uk first")

  -- With no feed the row area can never fill, so the frame collapses instead of
  -- showing a dozen empty rows that read as a broken addon.
  ok(ns.blocked["COMBAT_LOG_EVENT_UNFILTERED"], "the combat log event is blocked on this client")
  local collapsed = f._h
  ok(collapsed and collapsed < 100, ("the panel collapses with no feed (height %s)"):format(tostring(collapsed)))
  ns.Panel:Refresh()
  ok(f._shown, "Refresh with no records does not hide or error out")

  -- The one genuinely load-bearing thing it still reports.
  stub.logging.on = true
  stub.logging.advanced = true
  ns.Logging:Query(true)
  local label = ns.Logging:Label()
  ok(label and label:find("log: on", 1, true) ~= nil,
    ("the panel's bottom line states the logging state (%s)"):format(tostring(label)))

  -- Recovering a panel you cannot see, without wiping SavedVariables.
  ns.Panel:Toggle(false)
  ok(not f:IsShown(), "it can be hidden")
  ns.db.point = { "TOPLEFT", -9000, 9000 }
  SlashCmdList.UNKICKED("reset")
  ok(f:IsShown(), "/uk reset shows it again")
  eq(ns.db.point[1], "CENTER", "and puts it back at a position on screen")

  SlashCmdList.UNKICKED("")
  ok(not f:IsShown(), "/uk with no argument toggles it")
  SlashCmdList.UNKICKED("")
  ok(f:IsShown(), "and back")
end


-- ======================================================= C_DamageMeter (R-19)
-- The one live feed 12.x left. Everything here is about the four ways the real
-- API punishes a naive reader: secret amounts, a deaths metric that is a list,
-- session enum values that are not 0/1, and an empty Current session mid-fight.
print("\n[meter] C_DamageMeter -- the live per-player view")
do
  loadAddon()
  assert(loadfile("UI/Panel.lua"))("Unkicked", ns)
  stub.fire("PLAYER_LOGIN")

  eq(ns.Meter:Available(), false, "with no C_DamageMeter there is no live view")
  stub.meter.available = true
  eq(ns.Meter:Available(), true, "and it reports available once the client has it")

  -- kicks deliberately out of order: the API hands back a SORTED list and
  -- position is the only ranking that exists when amounts cannot be compared.
  stub.setMeter("current", {
    { name = "Healer",  class = "PRIEST",  icon = 11, guid = "P-h", kicks = 0, taken = 400000, deaths = 0 },
    { name = "Kicker",  class = "ROGUE",   icon = 12, guid = "P-k", kicks = 5, taken = 100000, deaths = 0 },
    { name = "Selfy",   class = "MAGE",    icon = 13, guid = "P-s", kicks = 2, taken = 250000, deaths = 2, isYou = true },
  })
  stub.setMeter("overall", {
    { name = "Kicker",  class = "ROGUE",   icon = 12, guid = "P-k", kicks = 99, taken = 1, deaths = 0 },
  })

  local rows, plain = ns.Meter:Rows("current")
  ok(rows ~= nil and #rows == 3, ("one row per player who was there (got %s)")
    :format(rows and #rows or "nil"))
  eq(plain, true, "out of combat the amounts are plain, so they can be totalled")
  eq(rows[1].name, "Kicker", "rank is list position -- the API's own ordering, not ours")
  eq(rows[1].kicks, 5, "and the interrupt count comes off that row")

  -- A healer who kicked nothing still has to be on screen with a zero, or the
  -- panel is reporting who scored rather than who was in the group.
  local healer
  for _, r in ipairs(rows) do if r.name == "Healer" then healer = r end end
  ok(healer ~= nil, "a player with zero interrupts is still listed")
  eq(healer and healer.kicks, 0, "with an explicit zero, not a blank")
  eq(healer and healer.deaths, 0, "and no deaths")

  -- Deaths is a LIST of deaths; reading totalAmount there gives 0 for someone
  -- who died and nothing for someone who did not.
  local you
  for _, r in ipairs(rows) do if r.isYou then you = r end end
  ok(you ~= nil, "the local player's row is identifiable (isLocalPlayer is never secret)")
  eq(you and you.deaths, 2, "two deaths means two rows in the Deaths metric, counted not summed")

  -- Session values are 7/8 in the stub on purpose: a module that hardcoded 0/1
  -- would read the wrong session and this would come back as the current one.
  local orows = ns.Meter:Rows("overall")
  eq(orows and #orows, 1, "the overall session is a different list")
  eq(orows and orows[1] and orows[1].kicks, 99, "so the session enum is asked, never assumed")

  -- Post-reset: Current comes back empty while the data sits in a session
  -- addressed by id. Without the fallback the panel blanks during combat.
  stub.meter.emptyCurrent = true
  local recovered = ns.Meter:Rows("current")
  eq(recovered and #recovered, 3, "an empty Current session falls back to the newest session by id")
  stub.meter.emptyCurrent = false

  -- ------------------------------------------------------------- secret values
  stub.meter.secret = true
  local srows, splain = ns.Meter:Rows("current")
  eq(splain, false, "in combat the amounts are secret, so nothing may be totalled")
  ok(srows ~= nil and #srows == 3, "but the rows still exist -- a secret can be displayed")
  ok(ns.IsSecret(srows[1].kicks), "and the amount is carried raw, never read")
  eq(ns.Meter:Snapshot("current"), nil, "Snapshot refuses to invent numbers from secrets")
  -- Handing a secret GUID back to the API errors in the real client and takes
  -- the whole draw down, so it must never be attempted.
  eq(ns.Meter:Spells("current", srows[1].guid), nil,
    "the per-spell call refuses a secret GUID instead of erroring")
  stub.meter.secret = false

  -- -------------------------------------------- damage from kickable casts
  -- The one shape of "missed kick" the live client can produce: the DamageTaken
  -- drill-down names the spell that hit each player, and the parser has already
  -- proven which ids are interruptible. A spell NOT in that table contributes
  -- nothing -- unknown is never counted as kickable.
  local KNOWN = next(ns.KNOWN_INTERRUPTIBLE)
  ok(KNOWN ~= nil, "the addon ships the parser's proven-interruptible ids")
  stub.meter.damageSpells = {
    ["P-h"] = {
      { spellID = KNOWN,   totalAmount = 300000 },
      { spellID = 9999999, totalAmount = 900000 },   -- never proven: not ours
      { spellID = KNOWN,   totalAmount = 50000 },
    },
  }
  local total, by = ns.Meter:Kickable("current", "P-h")
  eq(total, 350000, "kickable damage sums only the spells proven interruptible")
  eq(#by, 2, "and keeps the per-spell breakdown for the tooltip")
  eq(ns.Meter:Kickable("current", "P-k"), 0, "a player hit by nothing kickable reads zero")

  local snap = ns.Meter:Snapshot("current")
  eq(snap and snap.kickable, 350000, "the pull snapshot carries the run-wide kickable total")

  stub.meter.secret = true
  eq(ns.Meter:Kickable("current", ns.Meter:Rows("current")[1].guid), nil,
    "and it refuses to run against a secret GUID rather than erroring the draw")
  stub.meter.secret = false
  stub.meter.damageSpells = {}

  -- ------------------------------------------------------------- the key ledger
  stub.challenge = { level = 13, mapID = 500, mapName = "The Blinding Vale", deaths = 3 }
  stub.fire("CHALLENGE_MODE_START")
  eq(#ns.Meter.pulls, 0, "a fresh key starts with no pulls")
  eq(ns.Meter.run and ns.Meter.run.level, 13, "and records the keystone level from the client")

  stub.fire("PLAYER_REGEN_ENABLED")
  eq(#ns.Meter.pulls, 1, "a pull is harvested when combat ends, where the numbers go plain")
  eq(ns.Meter.pulls[1].kicks, 7, "with the pull's total interrupts")

  -- A segment nobody did anything in is not a pull; numbering has to stay stable
  -- enough to say out loud.
  stub.setMeter("current", {
    { name = "Healer", class = "PRIEST", icon = 11, guid = "P-h", kicks = 0, taken = 0, deaths = 0 },
  })
  stub.fire("PLAYER_REGEN_ENABLED")
  eq(#ns.Meter.pulls, 1, "an empty segment is not recorded as a pull")

  stub.setMeter("current", {
    { name = "Kicker", class = "ROGUE", icon = 12, guid = "P-k", kicks = 3, taken = 10, deaths = 0 },
    { name = "Selfy",  class = "MAGE",  icon = 13, guid = "P-s", kicks = 1, taken = 10, deaths = 1, isYou = true },
  })
  stub.fire("PLAYER_REGEN_ENABLED")
  eq(#ns.Meter.pulls, 2, "the next real pull is recorded")

  local total = ns.Meter:Total()
  eq(total and total.pulls, 2, "the run total covers the pulls inside the key")
  eq(total and total.kicks, 11, "summing interrupts across pulls (7 + 4)")
  eq(total and total.rows[1] and total.rows[1].name, "Kicker",
    "most interrupts first -- legal here because a snapshot is plain by construction")
  eq(total and total.rows[1].kicks, 8, "Kicker's 5 and 3 add up")
  eq(total and total.deaths, 3, "deaths accumulate too")

  -- The key's own counter can disagree with ours; it is reported beside our
  -- number rather than replacing it.
  eq(ns.Meter:KeyDeaths(), 3, "the client's keystone death count is readable")

  -- A new key wipes the ledger rather than blending two runs.
  stub.fire("CHALLENGE_MODE_START")
  eq(#ns.Meter.pulls, 0, "starting another key clears the previous run's pulls")
end

print("\n[panel] meter mode")
do
  loadAddon()
  stub.meter.available = true
  stub.meter.secret = false
  stub.setMeter("current", {
    { name = "Kicker", class = "ROGUE", icon = 12, guid = "P-k", kicks = 4, taken = 100, deaths = 0 },
    { name = "Selfy",  class = "MAGE",  icon = 13, guid = "P-s", kicks = 0, taken = 900, deaths = 1, isYou = true },
  })
  assert(loadfile("UI/Panel.lua"))("Unkicked", ns)
  assert(loadfile("Core/Commands.lua"))("Unkicked", ns)
  stub.fire("PLAYER_LOGIN")
  -- In a key: the per-pull strings below only apply inside one. Until R-20 this
  -- block asserted them with no key running, so the test agreed with the bug.
  stub.challenge = { level = 13, mapID = 500, mapName = "The Blinding Vale", deaths = 0 }
  stub.fire("CHALLENGE_MODE_START")
  ns.Panel:Refresh()

  local f = stub.frames["UnkickedPanel"]
  ok(f._h and f._h > 100, ("with a meter the panel is a real list, not a 2-line card (height %s)")
    :format(tostring(f._h)))
  ok(f.footer:GetText():find("not a cast count", 1, true) ~= nil,
    "and says plainly that kickable damage is a cost, not a count of missed casts")

  -- R-19. The header used to be anchored at the same y as row one, which put
  -- "kicks died taken" on top of the first player on screen.
  local headY = f.head and f.head._points[1] and f.head._points[1][3]
  local rowY = ns.Panel.rows and ns.Panel.rows[1]._points[1] and ns.Panel.rows[1]._points[1][3]
  ok(headY ~= nil and rowY ~= nil and headY ~= rowY,
    ("the header sits on its own line, not on row one (head %s, row %s)")
      :format(tostring(headY), tostring(rowY)))
  ok(rowY ~= nil and headY ~= nil and math.abs(rowY - headY) >= 16,
    "with a full row of clearance between them")
  ok(f.seg.text:GetText():find("pull", 1, true) ~= nil, "the header names the segment")
  ok(f.footer:GetText():find("live", 1, true) == nil, "out of combat the footer is not the live one")

  -- R-20. Pulls are only harvested inside a key, so outside one the Current
  -- session is not "pull 1" -- it is whatever Blizzard accumulated since the
  -- last reset, which on a real run read 24:18 of whole-dungeon totals under a
  -- label claiming it was the first pull.
  do
    local keptRun, keptPulls = ns.Meter.run, ns.Meter.pulls
    ns.Meter.run, ns.Meter.pulls = nil, {}
    ns.db.segment = "current"
    ns.Panel:Refresh()
    ok(f.seg.text:GetText():find("pull", 1, true) == nil,
      ("outside a key the header does not claim a pull number (%q)"):format(f.seg.text:GetText()))
    ok(f.seg.text:GetText():find("session", 1, true) ~= nil,
      "it calls the Current session what it is")
    ok(f.footer:GetText():find("not in a key", 1, true) ~= nil,
      "and the footer says per-pull totals have not started")
    ns.Meter.run, ns.Meter.pulls = keptRun, keptPulls
    ns.Panel:Refresh()
  end

  eq(ns.Panel:Segment(), "overall", "clicking the segment switches to the whole key")
  ok(f.seg.text:GetText():find("run", 1, true) ~= nil, "and the header follows")
  SlashCmdList.UNKICKED("current")
  eq(ns.db.segment, "current", "/uk current switches back")

  -- The crash that matters: a refresh during combat, when every amount is a
  -- secret value that may be handed to a widget but never formatted or compared.
  stub.meter.secret = true
  local okRefresh, err = pcall(function() ns.Panel:Refresh() end)
  ok(okRefresh, ("a refresh mid-pull survives secret amounts (%s)"):format(tostring(err)))
  -- And says it is the live view, which is the honest label: these numbers are
  -- being displayed without ever having been read.
  ok(f.footer:GetText():find("live", 1, true) ~= nil,
    ("mid-pull the footer marks it live (%s)"):format(tostring(f.footer:GetText())))
  stub.meter.secret = false

  -- Both commands have to be safe in combat too: /uk kicks is the one a player
  -- types while something is going wrong.
  stub.meter.secret = true
  ok(pcall(SlashCmdList.UNKICKED, "kicks"), "/uk kicks survives secret amounts")
  ok(pcall(SlashCmdList.UNKICKED, "why"), "/uk why survives secret amounts")
  stub.meter.secret = false
end

-- ============================================================ the offline path
-- parser/host.lua defines the same client globals this file stubs, so the offline
-- suite runs in its own process rather than fighting over them. Same interpreter,
-- so `luajit tests/run.lua` covers everything.
print("\n[parser] handing off to tests/parser.lua")
local interp = arg[-1] or "luajit"
local okParser = os.execute(("%s tests/parser.lua"):format(interp))
okParser = (okParser == true or okParser == 0)

-- ================================================================== the result
print(("\n%d passed, %d failed  (model)"):format(pass, fail))
if not okParser then print("the offline parser suite FAILED -- see above") end
os.exit((fail == 0 and okParser) and 0 or 1)
