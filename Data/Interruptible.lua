-- Unkicked :: Data/Interruptible.lua -- GENERATED, do not hand-edit.
-- Mirror of parser/learned-interruptible.lua, written on every parse.
-- Each id is a spell a SPELL_INTERRUPT was observed stopping, so it is
-- proof and not a guess. The live panel uses it to tell how much of the
-- damage the party ate came from casts that COULD have been stopped.
local ADDON, ns = ...
ns.KNOWN_INTERRUPTIBLE = {
  [267027] = true,  -- Poison Spit
  [267273] = true,
  [267763] = true,
  [268013] = true,  -- Flame Shock
  [269369] = true,
  [269972] = true,
  [270492] = true,
  [270901] = true,
  [270920] = true,
  [371984] = true,
  [372743] = true,
  [372808] = true,
  [373017] = true,
  [384194] = true,
  [385310] = true,
  [392576] = true,
  [400001] = true,
  [400002] = true,
  [1201554] = true,  -- Seduction
  [1214922] = true,  -- Fel Rage
  [1214980] = true,  -- Health Funnel
  [1216571] = true,  -- Fel Missiles
  [1223204] = true,  -- Felfire Burst
  [1228176] = true,
  [1233398] = true,
  [1235616] = true,
  [1238063] = true,
  [1238232] = true,
  [1238294] = true,
  [1239394] = true,  -- Scavenge
  [1239821] = true,
  [1241214] = true,  -- Earth Bolt
  [1247669] = true,
  [1249621] = true,
  [1257877] = true,  -- Scathing Review
  [1258420] = true,  -- Doom Bolt
  [1258431] = true,
  [1264106] = true,  -- Felstorm
  [1289416] = true,
  [1290147] = true,  -- Poison Bolt
  [1290198] = true,  -- Toxin Infusion
  [1291262] = true,  -- Lightning Bolt
  [1293307] = true,  -- Addle Mind
  [1294557] = true,
  [1294815] = true,
  [1294972] = true,
  [1295125] = true,
  [1297696] = true,  -- Healing Breeze
  [1298899] = true,
  [1299938] = true,
  [1301834] = true,
  [1302158] = true,  -- Flame Shock
  [1303375] = true,  -- Spew Venom
  [1305955] = true,
  [1307567] = true,
  [1310324] = true,
  [1310358] = true,
  [1310666] = true,
  [1310683] = true,  -- Venom Bolt
}
