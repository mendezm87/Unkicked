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

-- ====================================== R-30 specs that have no interrupt
-- Midnight took the interrupt off every healing spec but Restoration shaman. A
-- spec with no kick is not an unknown and is never a missed chance: the model
-- called a Holy paladin "up" for all 98 casts that got through two real keys,
-- which is blame for a button that does not exist.
print("\n[R-30] a spec with no interrupt is never a chance")
loadAddon(); freshParty()
eq(ns.SPEC_INTERRUPT[65].spellID, false, "Holy paladin has no interrupt")
eq(ns.SPEC_INTERRUPT[270].spellID, false, "Mistweaver has no interrupt")
eq(ns.SPEC_INTERRUPT[1468].spellID, false, "Preservation evoker has no interrupt")
eq(ns.SPEC_INTERRUPT[105].spellID, false, "Restoration druid has no interrupt")
eq(ns.SPEC_INTERRUPT[264].spellID, 57994, "Restoration shaman keeps Wind Shear")
eq(ns.SPEC_INTERRUPT[66].spellID, 96231, "Protection paladin keeps Rebuke")
eq(ns.SPEC_INTERRUPT[70].spellID, 96231, "Retribution paladin keeps Rebuke")
do
  local p = ns.Kick:SetKnown("P-hpal", 65, {}, "Holyhands")
  eq(p.spellID, nil, "a Holy paladin binds to no interrupt spell")
  eq(p.spec, "Holy", "but is still labelled with their spec, not left blank")
  local state, detail = ns.Kick:StateAt("P-hpal", stub.now())
  eq(state, "none", "and reports none, not ready")
  eq(detail, "no interrupt", "stating why, so a report can say it out loud")
  ns.Kick.players["P-hpal"] = nil
end
-- Class alone must not bind the player: paladin has exactly one interrupt, so
-- the single-candidate shortcut used to hand Rebuke to a Holy paladin.
loadAddon()
stub.setParty({ { guid = "P-me", name = "Holyhands", class = "PALADIN", spells = {} } })
stub.fire("GROUP_ROSTER_UPDATE")
eq(ns.Kick.players["P-me"].spellID, nil, "a paladin without Rebuke in their book stays unbound")
eq(select(1, ns.Kick:StateAt("P-me", stub.now())), "none", "and is reported as having none")
loadAddon()
stub.setParty({ { guid = "P-me", name = "Protchad", class = "PALADIN", spells = { [96231] = true } } })
stub.fire("GROUP_ROSTER_UPDATE")
eq(ns.Kick.players["P-me"].spellID, 96231, "a paladin who does have Rebuke still binds to it")

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

print("\n[meter] a cumulative session is differenced, not re-counted")
do
  -- R-21, from a real +13 (The Blinding Vale, 2026-10-01). C_DamageMeter's
  -- Current session does NOT reset between pulls inside a key: it spanned the
  -- whole 24:18 run and its per-player interrupt counts matched the combat log
  -- exactly. Treating each harvest as a pull would have counted pull one in
  -- every later pull as well, so the run total is only right if a pull is the
  -- DIFFERENCE between two snapshots.
  loadAddon()
  stub.meter.available = true
  stub.meter.secret = false
  stub.challenge = { level = 13, mapID = 500, mapName = "The Blinding Vale", deaths = 0 }
  stub.fire("CHALLENGE_MODE_START")

  stub.setMeter("current", {
    { name = "Kicker", class = "ROGUE", icon = 12, guid = "P-k", kicks = 5, taken = 100, deaths = 0 },
  }, { duration = 60 })
  stub.fire("PLAYER_REGEN_ENABLED")
  eq(#ns.Meter.pulls, 1, "the first readable snapshot is the first pull")
  eq(ns.Meter.pulls[1].kicks, 5, "and carries its own numbers")

  -- The session keeps growing rather than restarting.
  stub.setMeter("current", {
    { name = "Kicker", class = "ROGUE", icon = 12, guid = "P-k", kicks = 9, taken = 250, deaths = 1 },
  }, { duration = 150 })
  stub.fire("PLAYER_REGEN_ENABLED")
  eq(#ns.Meter.pulls, 2, "the second pull is recorded")
  eq(ns.Meter.pulls[2].kicks, 4, "as the DELTA (9 - 5), not the running total")
  eq(ns.Meter.pulls[2].taken, 150, "damage taken is differenced too")
  eq(ns.Meter.pulls[2].duration, 90, "and so is the clock")

  local total = ns.Meter:Total()
  eq(total and total.kicks, 9, "so the run total matches the session, instead of double-counting to 14")
  eq(total and total.duration, 150, "and the run clock is the session clock")
end

print("\n[meter] resummoned pets, and the row budget")
do
  -- Voidscar Arena +10, 2026-10-01. A warlock resummoned his felhunter twice, so
  -- its three Spell Locks came back as THREE rows all named "Maashon" with
  -- amount=1 (Pet-...-417-01/02/04). Blizzard's own meter draws them that way, so
  -- the shape is upstream -- but unmerged they ate three of the panel's six slots
  -- and pushed Dipndotz, the only member who actually died, off the list. That is
  -- what made the panel look like it was undercounting deaths.
  loadAddon()
  stub.meter.available = true
  stub.meter.secret = false
  stub.setMeter("current", {
    { name = "Mugzee",       class = "WARRIOR", icon = 21, guid = "P-1",   kicks = 18, taken = 77011323, deaths = 0 },
    { name = "Brucellosis",  class = "SHAMAN",  icon = 22, guid = "P-2",   kicks = 9,  taken = 40470250, deaths = 0 },
    { name = "Mandi",        class = "MAGE",    icon = 23, guid = "P-3",   kicks = 5,  taken = 38808425, deaths = 0 },
    { name = "Maashon",      class = "WARLOCK", icon = 24, guid = "Pet-1", kicks = 1,  taken = 0,        deaths = 0 },
    { name = "Maashon",      class = "WARLOCK", icon = 24, guid = "Pet-2", kicks = 1,  taken = 0,        deaths = 0 },
    { name = "Maashon",      class = "WARLOCK", icon = 24, guid = "Pet-4", kicks = 1,  taken = 0,        deaths = 0 },
    { name = "Dipndotz",     class = "WARLOCK", icon = 25, guid = "P-4",   kicks = 0,  taken = 37530085, deaths = 3 },
    { name = "Wafflezealot", class = "PALADIN", icon = 26, guid = "P-5",   kicks = 0,  taken = 36947172, deaths = 0, isYou = true },
  })

  local rows = ns.Meter:Rows("current")
  local by = {}
  for _, r in ipairs(rows) do by[r.name] = r end
  eq(by["Maashon"] and by["Maashon"].kicks, 3,
    "three resummons of one pet are one row carrying the summed count")
  eq(#rows, 6, "which leaves the whole group inside the panel's row budget")
  ok(by["Dipndotz"] ~= nil, "so the member who only died is on the list at all")
  eq(by["Dipndotz"] and by["Dipndotz"].deaths, 3,
    "with the three deaths the combat log recorded for that key")
  eq(by["Mugzee"] and by["Mugzee"].kicks, 18, "and the players are untouched by the merge")

  -- Merging READS the amounts, so in combat it must not happen at all: the
  -- rows that survive there do so through the identity dedupe, and every amount
  -- is still carried raw rather than added together.
  stub.meter.secret = true
  local srows = ns.Meter:Rows("current")
  local summed = false
  for _, r in ipairs(srows) do
    if r.merged then summed = true end
    if r.kicks ~= nil and not ns.IsSecret(r.kicks) and tonumber(r.kicks) then summed = true end
  end
  eq(summed, false, "in combat nothing is merged, because summing a secret is illegal")
  stub.meter.secret = false
end

print("\n[meter] a key where nothing was readable until it ended")
do
  -- Also from the real run: amounts stay secret for the whole restricted map,
  -- not merely while in combat, so every between-pull harvest came back secret
  -- and ZERO pulls were recorded across an entire dungeon. The panel then showed
  -- 24:18 of whole-key totals labelled "pull 1". The end-of-key harvest has to
  -- rescue the run.
  loadAddon()
  stub.meter.available = true
  stub.challenge = { level = 13, mapID = 500, mapName = "The Blinding Vale", deaths = 6 }
  stub.fire("CHALLENGE_MODE_START")

  stub.meter.secret = true
  stub.setMeter("current", {
    { name = "Kicker", class = "ROGUE", icon = 12, guid = "P-k", kicks = 26, taken = 45200000, deaths = 0 },
  }, { duration = 1458 })
  for _ = 1, 8 do stub.fire("PLAYER_REGEN_ENABLED") end
  eq(#ns.Meter.pulls, 0, "nothing is recorded while the map keeps the amounts secret")
  ok((ns.Meter.blockedHarvests or 0) > 0, "and the refusals are counted, not silently dropped")

  -- The key ends and the restriction lifts.
  stub.meter.secret = false
  stub.fire("CHALLENGE_MODE_COMPLETED")
  eq(#ns.Meter.pulls, 1, "completing the key harvests what was never readable before")
  eq(ns.Meter.pulls[1].kicks, 26, "with the whole key's numbers")
  ok(ns.Meter.pulls[1].wholeRun == true, "flagged as the whole run rather than one pull")
  local total = ns.Meter:Total()
  eq(total and total.kicks, 26, "so the run report is right even with no per-pull harvest")
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
  -- R-21. The live segment is the KEY so far, never "pull N": measured on a real
  -- +13, C_DamageMeter's Current session spanned the whole 24:18 run.
  ok(f.seg.text:GetText():find("key so far", 1, true) ~= nil,
    ("the header calls the live segment the key so far (%q)"):format(f.seg.text:GetText()))
  ok(f.seg.text:GetText():find("pull", 1, true) == nil,
    "and never claims the live view is one pull")
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

  -- R-22. One unreadable value used to poison the formatting of every other
  -- one. On the real +10 a row's name came back secret while the amounts beside
  -- it were plain, and the single global "plain" flag made the whole table
  -- render raw -- "77011323" where "77.0m" belonged. Plainness is per value.
  do
    ns.db.segment = "current"
    stub.meter.secretNames = true
    ns.Panel:Refresh()
    local taken = ns.Panel.rows[1].c4:GetText()
    ok(taken ~= nil and taken:find("|cff808080", 1, true) ~= nil,
      ("a readable amount is still formatted beside an unreadable name (%q)"):format(tostring(taken)))
    eq(ns.Panel.rows[1].c1:GetText():find("?", 1, true) ~= nil, true,
      "and the name it genuinely cannot read shows as ?")
    stub.meter.secretNames = false
    ns.Panel:Refresh()
  end

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

-- ================================================== the segment dropdown (R-31)
-- "Let me see past pulls and pick which section to view." The panel used to have
-- a two-state toggle, which could reach the live view and the run total and
-- nothing else -- there was no way to look at pull 3 once pull 4 had started.
print("\n[panel] the segment dropdown")
do
  loadAddon()
  stub.meter.available = true
  stub.meter.secret = false
  assert(loadfile("UI/Panel.lua"))("Unkicked", ns)
  assert(loadfile("Core/Commands.lua"))("Unkicked", ns)
  stub.fire("PLAYER_LOGIN")

  -- With no key and no pulls there are still the two segments that always exist,
  -- plus whatever past sessions Blizzard is holding (the stub holds one).
  local segs = ns.Meter:Segments()
  eq(segs[1] and segs[1].kind, "live", "the live segment is always first")
  eq(segs[2] and segs[2].kind, "run", "and the run total is always offered")
  ok(segs[2].label:find("no pulls yet", 1, true) ~= nil,
    "the run entry says it is empty rather than pretending to have pulls")

  stub.challenge = { level = 13, mapID = 500, mapName = "The Blinding Vale", deaths = 0 }
  stub.fire("CHALLENGE_MODE_START")
  stub.setMeter("current", {
    { name = "Kicker", class = "ROGUE", icon = 12, guid = "P-k", kicks = 5, taken = 100, deaths = 0 },
  }, { duration = 60 })
  stub.fire("PLAYER_REGEN_ENABLED")
  stub.setMeter("current", {
    { name = "Kicker", class = "ROGUE", icon = 12, guid = "P-k", kicks = 9, taken = 250, deaths = 1 },
  }, { duration = 150 })
  stub.fire("PLAYER_REGEN_ENABLED")
  eq(#ns.Meter.pulls, 2, "two pulls harvested, so two pulls are selectable")

  segs = ns.Meter:Segments()
  local byKey = {}
  for _, seg in ipairs(segs) do byKey[seg.key] = seg end
  ok(byKey["pull:1"] and byKey["pull:2"], "every harvested pull has its own entry")
  ok(byKey["pull:2"].label:find("pull 2", 1, true) ~= nil,
    ("and is labelled with its number and clock (%q)"):format(byKey["pull:2"].label))

  -- Selecting a past pull shows THAT pull's numbers, not the live session's.
  local f = stub.frames["UnkickedPanel"]
  ns.Panel:Segment("pull:1")
  eq(ns.db.segment, "pull:1", "the panel can be pointed at a specific past pull")
  ok(f.seg.text:GetText():find("pull 1", 1, true) ~= nil,
    ("and the heading names it (%q)"):format(f.seg.text:GetText()))
  eq(ns.Panel.rows[1].c2:GetText(), "|cffffd2005|r", "showing pull 1's own 5 kicks")
  ns.Panel:Segment("pull:2")
  eq(ns.Panel.rows[1].c2:GetText(), "|cffffd2004|r",
    "and pull 2's delta of 4, not the session's running 9")
  ok(f.footer:GetText():find("finished segment", 1, true) ~= nil,
    "the footer says this is a finished segment rather than the live one")

  -- Cycling still works for anyone who kept the old habit, and now walks the
  -- whole list instead of flipping between two.
  ns.db.segment = "current"
  eq(ns.Panel:Segment(), "overall", "right-click cycling goes live -> run")
  eq(ns.Panel:Segment(), "pull:1", "-> the first pull")

  -- The menu itself: one button per segment, the showing one marked, and a click
  -- actually selects it.
  local m = ns.Panel:Menu(true)
  ok(m._shown ~= false, "the dropdown opens")
  local items, live = ns.Panel.menuFrame.items, 0
  for _, b in ipairs(items) do if b.segKey then live = live + 1 end end
  eq(live, #segs, "with one entry per segment")
  local marked = 0
  for _, b in ipairs(items) do
    if b.segKey and b.text:GetText():find(">", 1, true) then marked = marked + 1 end
  end
  eq(marked, 1, "exactly one entry is marked as the one on screen")
  items[2]:Click()
  eq(ns.db.segment, "overall", "clicking an entry selects that segment")
  ok(ns.Panel.menuFrame._shown == false, "and closes the dropdown")

  -- A key stored from a previous run names a pull that no longer exists. The
  -- panel has to fall back and SAY so; an empty table under "pull 7" is worse
  -- than either the truth or the live view.
  ns.db.segment = "pull:7"
  ns.Panel:Refresh()
  eq(ns.db.segment, "current", "a stale segment key falls back to the live view")
  ok(f.footer:GetText():find("is gone", 1, true) ~= nil,
    ("and the footer says the old segment went away (%q)"):format(f.footer:GetText()))

  -- One of Blizzard's own past sessions, addressed by id. Out in the world each
  -- fight is its own session and the amounts are plain, so these are genuinely
  -- viewable -- but there is no by-id drill-down, so no kickable column.
  local rows, plain, label = ns.Meter:View("session:42")
  ok(rows and rows[1], "a past Blizzard session resolves to rows")
  eq(plain, true, "and out of combat its amounts are readable")
  eq(label, ns.Meter:SegmentLabel("session:42"),
    "and its heading reads the same as the dropdown entry that selected it")
  eq(ns.Meter:Spells({ id = 42 }, "P-k"), nil,
    "but a session addressed by id has no per-spell drill-down, rather than being served the Current session's")
  eq(ns.Meter:View("session:999"), nil, "an id Blizzard no longer holds resolves to nothing")

  -- The whole-key harvest must never be offered as "pull 1" (R-20).
  ns.Meter.pulls[1].wholeRun = true
  ok((ns.Meter:SegmentLabel("pull:1")):find("whole key", 1, true) ~= nil,
    "a harvest that covers the entire key is labelled the whole key, not pull 1")

  -- Commands reach the same places, and survive secret amounts.
  ok(pcall(SlashCmdList.UNKICKED, "segments"), "/uk segments lists them")
  ok(pcall(SlashCmdList.UNKICKED, "pull 2"), "/uk pull 2 selects a pull")
  eq(ns.db.segment, "pull:2", "and the panel follows")
  ok(pcall(SlashCmdList.UNKICKED, "pull 99"), "/uk pull on a pull that does not exist is refused, not an error")
  eq(ns.db.segment, "pull:2", "leaving the selection alone")
  stub.meter.secret = true
  ns.db.segment = "current"
  ok(pcall(function() return ns.Panel:Menu(true) end), "the dropdown builds mid-combat, where every amount is secret")
  ok(pcall(SlashCmdList.UNKICKED, "segments"), "and /uk segments survives it too")
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
