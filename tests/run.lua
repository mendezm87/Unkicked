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
    "Data/InterruptData.lua", "Data/CCData.lua",
    "Core/Init.lua", "Core/Nameplates.lua", "Core/KickTracker.lua", "Core/CastTracker.lua",
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
