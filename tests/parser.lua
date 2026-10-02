-- Unkicked :: tests/parser.lua
--   luajit tests/parser.lua
--
-- The offline path. Runs in its own process because it installs the real headless
-- host (parser/host.lua) rather than the test stub, and the two define the same
-- client globals.
--
-- What is worth testing here is everything that is a FORMAT guess rather than a
-- model rule: the advanced-logging field offset, the COMBATANT_INFO anchor, pull
-- segmentation, and the two things the log can do that the in-game addon never
-- could -- prove a cast interruptible, and read a talent that was actually taken.

package.path = "./parser/?.lua;" .. package.path

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
local function has(hay, needle, what)
  ok(type(hay) == "string" and hay:find(needle, 1, true) ~= nil,
    ("%s  (looking for %q)"):format(what, needle))
end

local logline = require("logline")
local host = require("host")
local Session = require("session")
local Knowledge = require("knowledge")
local report = require("report")
local Totals = require("totals")

-- ===================================================== the line format itself
print("\n[parser] timestamps and field splitting")
local ts, rest = logline.timestamp(
  '9/30/2026 21:43:01.500-7  SPELL_CAST_START,Creature-0-1,"Mystic",0xa48,0x0,0000000000000000,nil,0x80000000,0x0,400001,"Tidal Bolt",8')
ok(ts ~= nil, "a retail timestamp parses")
near(ts % 1, 0.5, 0.001, "sub-second precision survives")
local f = logline.split(rest)
eq(f[1], "SPELL_CAST_START", "subevent is the first field")
eq(f[3], "Mystic", "quoted names are unquoted")
eq(f[11], "Tidal Bolt", "spell name lands in the right column")
eq(logline.timestamp("random text with no timestamp"), nil, "a line with no timestamp is rejected")

print("\n[parser] commas inside bracketed groups do not split a field")
local g = logline.split('COMBATANT_INFO,Player-1,0,(1,2,3),(4,5),[a,b,[c,d]],7')
eq(#g, 7, "nested parens and brackets stay whole")
eq(g[4], "(1,2,3)", "a paren group is one field")
eq(g[6], "[a,b,[c,d]]", "nesting is tracked, not just matched")

print("\n[parser] advanced logging moves the damage amount, and a bad guess is refused")
-- This block is copied field-for-field from a real retail log (build 12.1.0,
-- COMBAT_LOG_VERSION 22). It is 19 fields, not the 17 the layout is usually
-- documented as, and it ends on the posX, posY, uiMapID, facing, level shape
-- that M.advancedSuffix anchors to.
local ADV = "Player-1,0000000000000000,1387024,1400670,0,0,1470,0,0,0,1,0,0,0,4443.13,-453.19,2574,1.8436,90"
local dmg = ('SPELL_DAMAGE,Creature-0-1,"Mystic",0xa48,0x0,Player-1,"Rek",0x511,0x0,400001,"Tidal Bolt",8,%s,1250000,1250000,0,8,0,0,0,nil,nil,nil')
  :format(ADV)
local a = logline.normalize(1000, logline.split(dmg), true)
eq(a and a[11], 1250000, "the amount is found past a real 19-field advanced block")

-- A block with one MORE unit field than we know about must still resolve, because
-- the boundary is located by shape rather than counted. This is the regression
-- that a hand-counted 17 could not survive.
local wider = ('SPELL_DAMAGE,Creature-0-1,"Mystic",0xa48,0x0,Player-1,"Rek",0x511,0x0,400001,"Tidal Bolt",8,Player-1,0000000000000000,1387024,1400670,0,0,1470,0,0,0,1,0,0,0,7,4443.13,-453.19,2574,1.8436,90,1250000,1250000,0,8,0,0,0,nil,nil,nil')
local b = logline.normalize(1000, logline.split(wider), true)
eq(b and b[11], 1250000, "an extra unit field does not shift the amount")

-- The original bug: a mis-measured block lands on `facing`, which IS numeric, so
-- "is it a number" was not a sufficient guard. Amounts are always whole.
local badfrac = logline.normalize(1000, logline.split(
  ('SPELL_DAMAGE,Creature-0-1,"Mystic",0xa48,0x0,Player-1,"Rek",0x511,0x0,400001,"Tidal Bolt",8,%s'):format(ADV)), true)
eq(badfrac, nil, "a block with no suffix at all is refused, not scored")
local wrong, why = logline.normalize(1000, logline.split(dmg), false)
eq(wrong, nil, "with advanced logging wrongly assumed off, the line is refused")
has(why, "numeric", "and says why, rather than silently scoring 0 damage")

print("\n[parser] COMBATANT_INFO is anchored on the talent list, not on a stat count")
-- Two rows with DIFFERENT numbers of leading stats must both resolve, because
-- Blizzard adds stat columns between patches and a counted offset would drift.
local short = logline.combatantInfo(logline.split(
  'COMBATANT_INFO,Player-1,0,1,2,3,251,(91,96212,1)(92,55,1),(0,0),[],[],1,0,0,0'))
local long = logline.combatantInfo(logline.split(
  'COMBATANT_INFO,Player-1,0,1,2,3,4,5,6,7,8,9,251,(91,96212,1)(92,55,1),(0,0),[],[],1,0,0,0'))
eq(short.specID, 251, "spec id is the field before the talent group")
eq(long.specID, 251, "and still is when the stat block grows")
eq(#short.entries, 2, "both talent entries are extracted")
eq(short.entries[1], 96212, "the middle number of each triple is the node ENTRY id")

-- ===================================================== talents actually taken
print("\n[offline only] a log states which talent was taken, so the cooldown is a fact")
local ns = host.init(".")
local dk = ns.Kick:SetKnown("P-dk", 251, { 96212 }, "Grimm")      -- Frost DK + Coldthirst
eq(dk.spellID, 47528, "spec id resolves to that spec's interrupt")
eq(dk.spec, "Frost", "and to the spec name")
eq(dk.talent, "Coldthirst", "the cooldown-reduction talent is recognised by entry id")
eq(dk.connectMs, 12000, "a connect refunds 3s: 12s, matching the generated floor")
eq(dk.whiffMs, 15000, "a whiff does not: still 15s, because Coldthirst is conditional")
eq(dk.exact, true, "the cooldown is now exact, not inferred")

-- P-18: Honed Reflexes is only matched by a class-mask heuristic, and a real
-- Blinding Vale log disproved the asserted number -- an Arms warrior holding node
-- entry 118850 had a shortest observed Pummel interval of 14.88s across 22 presses,
-- not 13.5s. A heuristic talent therefore unlocks learning instead of asserting.
local war = ns.Kick:SetKnown("P-war", 73, { 116924 }, "Thrack")    -- Prot warrior + Honed Reflexes
eq(war.talent, "Honed Reflexes", "the talent is still recognised as taken")
eq(war.connectMs, nil, "but a heuristically-matched reduction is not asserted as a value")
eq(war.whiffMs, nil, "in either bucket, so the model keeps the 15s base")
eq(war.floorMs, 13500, "it lowers the learning floor to what the talent could achieve")
eq(war.eligible, true, "and marks the player eligible for a downward correction")
ok(war.exact ~= true, "learning stays switched on, or that floor is unreachable")

local rog = ns.Kick:SetKnown("P-rog", 261, {}, "Slink")
eq(rog.spellID, 1766, "Subtlety resolves to Kick")
eq(rog.connectMs, nil, "no reduction talent taken means no override")
eq(rog.exact, true, "an empty talent list is still an answer, so no learning is needed")

print("\n[offline only] an exact cooldown is never overwritten by a measured one")
ns.Kick:OnSpend("P-dk", 47528, 100)
ns.Kick:OnConnect("P-dk", 47528, 100.1)
ns.Kick:OnSpend("P-dk", 47528, 111)     -- an 11s gap: below the 12s floor, i.e. noise
eq(ns.Kick.players["P-dk"].connectMs, 12000, "the learning rule stands down when the truth is known")

print("\n[offline only] the spec is unknowable in game, so this is a real gain")
eq(ns.SPEC_INTERRUPT[255].spellID, 187707, "Survival hunter -> Muzzle")
eq(ns.SPEC_INTERRUPT[253].spellID, 147362, "Beast Mastery -> Counter Shot")
eq(ns.SPEC_INTERRUPT[102].spellID, 78675, "Balance druid -> Solar Beam")
eq(ns.SPEC_INTERRUPT[103].spellID, 106839, "Feral druid -> Skull Bash")

-- ======================================================== end to end on a log
print("\n[parser] a whole log: segmentation, attribution, and what it concludes")
local pulls = {}
local knowledge = Knowledge.load("/dev/null")
ns = host.init(".")
local session = Session.new(ns, {
  host = host, quietGap = 5, knowledge = knowledge,
  onPull = function(p) pulls[#pulls + 1] = p end,
})
for line in io.lines("tests/fixtures/sample-combatlog.txt") do session:line(line) end
session:flush()

eq(#pulls, 2, "two pulls reported: the trash pack and the boss")
eq(pulls[1].kind, "trash", "the pack has no markers, so it is segmented on the quiet gap")
eq(pulls[2].kind, "boss", "ENCOUNTER_START/END brackets the boss")
eq(pulls[2].name, "Tideburn Warlord", "and names it")
eq(pulls[2].outcome, "kill", "and records whether it died")
ok(session.segments > #pulls, "an empty segment is dropped rather than numbered")

local p1 = pulls[1]
eq(#p1.records, 2, "two casts got through the pack")
local killed = nil
for _, r in ipairs(p1.records) do
  for who in pairs(r.deaths) do killed = who end
end
eq(killed, "Rek-Illidan", "the cast that killed someone is attributed to the death")

print("\n[parser] the log proves interruptibility the client will no longer tell us")
eq(knowledge:get(400001), true, "a spell seen being interrupted is proven kickable")
eq(knowledge:get(400003), nil, "a spell never interrupted stays unknown, never assumed")
local firstHex
for _, r in ipairs(p1.records) do if r.spellID == 400002 then firstHex = r end end
eq(firstHex.interruptible, true, "a cast recorded BEFORE the proof arrives is back-filled")
eq(firstHex.interruptibleFrom, "learned", "and says where that came from")

print("\n[parser] the talent read changes the verdict, not just the display")
local boss = pulls[2].records[1]
eq(boss.spellID, 400001, "the boss cast that landed")
local up = {}
for _, k in ipairs(boss.kicks.ready) do up[k.name] = true end
ok(up["Frosty-Illidan"],
  "the DK reads READY 12.5s after his kick -- base 15s would have called him down, "
  .. "and Coldthirst is why")
eq(#boss.kicks.down, 0, "nobody's interrupt was actually on cooldown for that cast")

print("\n[parser] the same log without Coldthirst reaches the opposite conclusion")
-- The control for the claim above: strip the one talent entry out of the log and
-- the DK's kick is still on cooldown when that cast lands. If this ever passes at
-- the same time as the assertion above, the talent read is not doing anything.
local control = {}
local cns = host.init(".")
local cs = Session.new(cns, {
  host = host, quietGap = 5, knowledge = Knowledge.load("/dev/null"),
  onPull = function(p) control[#control + 1] = p end,
})
for line in io.lines("tests/fixtures/sample-combatlog.txt") do
  cs:line((line:gsub("%(90000,96212,1%)", "(90000,99999,1)")))
end
cs:flush()
local cboss = control[2].records[1]
local cdown = {}
for _, k in ipairs(cboss.kicks.down) do cdown[k.name] = true end
ok(cdown["Frosty-Illidan"], "without the talent the same cast reads the DK as DOWN")
eq(#cboss.kicks.down, 1, "and he is the only one")

print("\n[parser] cold start applies to the start of the LOG, not of every pull")
-- In game the addon only ever saw the pull it was in, so each pull reopened the
-- question. A log is continuous: by the boss, not having seen a spend is evidence.
local unknowns = {}
for _, k in ipairs(boss.kicks.unknown or {}) do unknowns[#unknowns + 1] = k.name end
eq(#unknowns, 0, "no party member is unknown by the boss pull")

print("\n[parser] --follow does not close a pull while replaying an old file")
-- The wall clock is irrelevant when the log is historical; only its own timestamps
-- can end a pull. Getting this wrong cuts replayed pulls in half.
local fresh = host.init(".")
local fs2 = Session.new(fresh, { host = host, quietGap = 5, knowledge = Knowledge.load("/dev/null"),
  onPull = function() end })
local n = 0
for line in io.lines("tests/fixtures/sample-combatlog.txt") do
  n = n + 1
  fs2:line(line)
  if n == 6 then break end            -- mid trash pull
end
local openPull = fs2.pull
fs2:idle(os.time() + 86400)           -- a wall clock a day ahead of the log
eq(fs2.pull, openPull, "an idle tick far ahead of the log leaves the pull open")
fs2:idle(fs2.now + 10)                -- caught up, and genuinely quiet
eq(fs2.pull, nil, "but a quiet gap at the log's own time does close it")

print("\n[parser] a line with no actor is not a party member")
-- Real logs carry environment ticks as sourceGUID 0000000000000000, name "nil", but
-- with the AFFILIATION flags of the player concerned. That passed the group test and
-- became a sixth, nameless member listed in every availability line.
do
  local ns2 = host.init(".")
  local s2 = Session.new(ns2, { host = host, quietGap = 5, knowledge = Knowledge.load("/dev/null") })
  s2:line('9/30/2026 18:57:57.162-7  SPELL_AURA_APPLIED,0000000000000000,nil,0x514,0x80000000,'
    .. 'Player-11-0E60432F,"Rawria-Tichondrius-US",0x514,0x80000000,1297338,"Deadly Venom",0x8,DEBUFF')
  local n, nullKeyed = 0, false
  for guid, pl in pairs(ns2.Kick.players) do
    n = n + 1
    if not pl.name or guid == "0000000000000000" then nullKeyed = true end
  end
  eq(n, 1, "only the real player on the receiving end joins the roster")
  eq(nullKeyed, false, "the null GUID is never added as a nameless member")
end

-- ====================================== P-10 / R-13: the overall run segment
print("\n[parser] overall totals and run segmentation")
do
  local t = Totals.new({ zone = "Tideburn Deep" })
  local proven, provenDmg, provenDeaths = 0, 0, 0
  for _, pull in ipairs(pulls) do
    t:add(pull, 0)
    for _, r in ipairs(pull.records) do
      if r.interruptible == true then
        proven = proven + 1
        provenDmg = provenDmg + (r.damage or 0)
        for _ in pairs(r.deaths or {}) do provenDeaths = provenDeaths + 1 end
      end
    end
  end
  eq(t.pulls, #pulls, "every reported pull lands in the overall")
  eq(t.unkicked, proven, "the overall cast count is the sum of the proven casts")
  eq(t.damage, provenDmg, "and the damage total is the sum of theirs, not a re-derivation")
  eq(t.deaths, provenDeaths, "a death is counted once in the overall, not once per pull")
  eq(t.bosses, 1, "the boss pull is counted as a boss")
  eq(t.kills, 1, "and its kill is recorded")

  -- Immune casts never reach the total, the same partition the per-pull view uses.
  local immune = Totals.new({})
  immune:add({ index = 1, kind = "trash", duration = 10, records = {
    { spellID = 1, spellName = "Immune Thing", srcName = "X", damage = 9999,
      interruptible = false, deaths = {}, kicks = {} },
  } }, 0)
  eq(immune.unkicked, 0, "a cast known to be immune is not a missed kick")
  eq(immune.unknown, 0, "nor is it an unproven one")

  -- The regression this section exists for: a death caused by a cast we cannot
  -- prove was kickable must not be silently dropped, or the overall prints
  -- "no deaths caused" for a run whose pull reports said KILLED.
  local u = Totals.new({})
  u:add({ index = 1, kind = "trash", duration = 10, records = {
    { spellID = 2, spellName = "Shadow Barrage", srcName = "Shadow of Zul", damage = 126000,
      interruptible = nil, deaths = { ["Aigirlf"] = 84000 }, kicks = {} },
  } }, 0)
  eq(u.unkicked, 0, "an unproven cast stays out of the unkicked total")
  eq(u.deaths, 0, "and out of the deaths-caused total")
  eq(u.unknownDeaths, 1, "but its death is counted as an unproven-cast death")
  local txt = report.overall(u, { color = false })
  ok(txt:find("no deaths caused", 1, true) == nil,
    "the overall never claims 'no deaths caused' when an unproven cast killed someone")
  has(txt, "1 death", "the unproven footer states the death")

  -- P-16: a melee killing blow belongs to nobody's missed kick, but the run total
  -- must still reconcile. The Blinding Vale log has six party deaths and only five
  -- a cast can be blamed for; the sixth was Meittik's melee swing.
  local mixed = Totals.new({})
  mixed:add({ index = 1, kind = "trash", duration = 10, partyDeaths = 3, records = {
    { spellID = 3, spellName = "Light Bolt Volley", srcName = "Radiant Spellsower",
      damage = 1800000, interruptible = true, deaths = { ["Tun"] = 900000 }, kicks = {} },
    { spellID = 4, spellName = "Warden's Wrath", srcName = "Lightwarden Ruia",
      damage = 10, interruptible = nil, deaths = { ["Tutte"] = 10 }, kicks = {} },
  } }, 0)
  eq(mixed.partyDeaths, 3, "every party death in the pull reaches the run total")
  eq(mixed.deaths + mixed.unknownDeaths, 2, "two of the three are attributable to a cast")
  local mtxt = report.overall(mixed, { color = false })
  has(mtxt, "1 further death from no tracked cast",
    "the overall states the death no cast can be blamed for")
  has(mtxt, "2 of 3 accounted for", "and reconciles against the full death count")

  local tidy = Totals.new({})
  tidy:add({ index = 1, kind = "trash", duration = 10, partyDeaths = 1, records = {
    { spellID = 5, spellName = "Bolt", srcName = "X", damage = 5, interruptible = true,
      deaths = { ["A"] = 5 }, kicks = {} },
  } }, 0)
  ok(report.overall(tidy, { color = false }):find("no tracked cast", 1, true) == nil,
    "and says nothing when every death is already accounted for")

  -- P-17: two spell ids can share one name (The Blinding Vale ships two "Light
  -- Bolt"s), and two identically labelled rows read as a duplicated-row bug.
  local twins = Totals.new({})
  twins:add({ index = 1, kind = "trash", duration = 10, records = {
    { spellID = 1235616, spellName = "Light Bolt", srcName = "A", damage = 900,
      interruptible = true, deaths = {}, kicks = {} },
    { spellID = 1238063, spellName = "Light Bolt", srcName = "B", damage = 100,
      interruptible = true, deaths = {}, kicks = {} },
    { spellID = 42, spellName = "Seed Shot", srcName = "C", damage = 50,
      interruptible = true, deaths = {}, kicks = {} },
  } }, 0)
  local ttxt = report.overall(twins, { color = false })
  has(ttxt, "Light Bolt (1235616)", "a name shared by two spell ids is labelled with the id")
  has(ttxt, "Light Bolt (1238063)", "for both of them, so the rows are distinguishable")
  ok(ttxt:find("Seed Shot (", 1, true) == nil,
    "a name that is unique is left alone rather than cluttered with an id")

  -- Sorted views: by damage, then stable by name.
  local ranked = Totals.new({})
  ranked:add({ index = 1, kind = "trash", duration = 10, records = {
    { spellID = 10, spellName = "Small", srcName = "A", damage = 10, interruptible = true, deaths = {}, kicks = {} },
    { spellID = 11, spellName = "Big", srcName = "B", damage = 1000, interruptible = true, deaths = {}, kicks = {} },
  } }, 0)
  eq(ranked:topSpells(1)[1].name, "Big", "spells rank by damage")
  eq(ranked:topSources(1)[1].name, "B", "so do casters")

  -- Chances, not blame (R-7): the per-player column counts availability.
  local who = Totals.new({})
  who:add({ index = 1, kind = "trash", duration = 10, records = {
    { spellID = 12, spellName = "Bolt", srcName = "C", damage = 5, interruptible = true, deaths = {},
      kicks = { ready = { { name = "Up" } }, down = { { name = "Down" } }, cc = {}, unknown = {} } },
  } }, 0)
  eq(who.players["Up"].chances, 1, "a player whose interrupt was up gets a chance counted")
  eq(who.players["Down"].down, 1, "and one on cooldown is counted as unavailable")
  has(report.overall(who, { color = false }), "chances, not blame",
    "the header refuses to read as a blame table")
end

do
  -- Runs are read from ZONE_CHANGE, not inferred. A zone walked through without
  -- a pull is not a run, and several ZONE_CHANGE lines for one instance are one.
  local runs = {}
  local ns3 = host.init(".")
  local s3 = Session.new(ns3, {
    host = host, quietGap = 5, knowledge = Knowledge.load("/dev/null"),
    onPull = function() end, onRun = function(r) runs[#runs + 1] = r end,
  })
  local function L(t, body) s3:line(("9/30/2026 %s-7  %s"):format(t, body)) end
  L("22:00:00.000", "COMBAT_LOG_VERSION,22,ADVANCED_LOG_ENABLED,1,BUILD_VERSION,12.1.0,PROJECT_ID,1")
  L("22:00:01.000", "ZONE_CHANGE,1762,\"Kings' Rest\",23")
  L("22:00:02.000", "ZONE_CHANGE,1762,\"Kings' Rest\",23")
  L("22:00:03.000", "ENCOUNTER_START,2139,\"The Golden Serpent\",23,5,1762")
  L("22:00:40.000", "ENCOUNTER_END,2139,\"The Golden Serpent\",23,5,1,37000")
  L("22:01:00.000", "ZONE_CHANGE,0,\"Silvermoon City\",0")
  L("22:02:00.000", "ZONE_CHANGE,2293,\"Atal'Dazar\",23")
  L("22:02:01.000", "ENCOUNTER_START,2082,\"Priestess Alun'za\",23,5,2293")
  L("22:02:30.000", "ENCOUNTER_END,2082,\"Priestess Alun'za\",23,5,0,29000")
  s3:flush()

  eq(#runs, 2, "two instances in one log produce two runs")
  eq(runs[1].zone, "Kings' Rest", "the run is named from ZONE_CHANGE")
  eq(runs[1].pulls, 1, "with the pulls that happened inside it")
  eq(runs[2].zone, "Atal'Dazar", "and the second is its own run")
  eq(s3.runs, 2, "the open-world zone between them is not counted as a run")
end

do
  -- A log can start mid-dungeon, with no ZONE_CHANGE to open a run. The pulls
  -- must still be totalled rather than dropped on the floor.
  local runs = {}
  local ns4 = host.init(".")
  local s4 = Session.new(ns4, {
    host = host, quietGap = 5, knowledge = Knowledge.load("/dev/null"),
    onPull = function() end, onRun = function(r) runs[#runs + 1] = r end,
  })
  for line in io.lines("tests/fixtures/sample-combatlog.txt") do s4:line(line) end
  s4:flush()
  eq(#runs, 1, "a log with no ZONE_CHANGE still produces one implicit run")
  eq(runs[1].pulls, 2, "carrying every pull in the file")
end

print("\n[parser] rendering")
local text = report.text(pulls[1], { color = false, model = true })
has(text, "KILLED Rek-Illidan", "the death is called out")
has(text, "down:", "and who was on cooldown at that moment")
local json = report.json(pulls[2], {})
has(json, '"spellID":400001', "json carries the spell id")
has(json, '"kicksUp":["Frosty-Illidan"', "and who had a kick up")
ok(loadstring("return " .. (json:gsub("[%[%]]", { ["["] = "{", ["]"] = "}" })
  :gsub('"(%w+)":', "[%q]="))) ~= nil, "the json is at least structurally balanced")
do
  local t = Totals.new({ index = 1, zone = "Kings' Rest", keystone = 10 })
  for _, pull in ipairs(pulls) do t:add(pull, 0) end
  local oj = report.overallJson(t)
  has(oj, '"overall":true', "the overall json is tagged so an overlay can route it")
  has(oj, '"keystone":10', "and carries the key level when the log stated one")
  has(oj, '"unprovenDeaths":', "and reports unproven-cast deaths rather than hiding them")
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
