-- Unkicked :: Data/Interruptible.lua -- GENERATED, do not hand-edit.
-- Mirror of parser/learned-interruptible.lua, written on every parse.
-- Each id is a spell a SPELL_INTERRUPT was observed stopping, so it is
-- proof and not a guess. The live panel uses it to tell how much of the
-- damage the party ate came from casts that COULD have been stopped.
local ADDON, ns = ...
ns.KNOWN_INTERRUPTIBLE = {
  [29722] = true,
  [51505] = true,
  [267273] = true,
  [267763] = true,
  [269972] = true,
  [270492] = true,
  [270901] = true,
  [270920] = true,
  [356995] = true,
  [400001] = true,  -- Tidal Bolt
  [400002] = true,  -- Hex Bolt
  [1228176] = true,
  [1233398] = true,
  [1235616] = true,
  [1238063] = true,
  [1238232] = true,
  [1238294] = true,
  [1239821] = true,
  [1247669] = true,
  [1249621] = true,
  [1294815] = true,
  [1294972] = true,
  [1295125] = true,
  [1298899] = true,
  [1299938] = true,
  [1301834] = true,
  [1310324] = true,
}
