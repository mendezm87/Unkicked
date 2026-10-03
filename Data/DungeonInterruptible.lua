-- Unkicked :: DungeonInterruptible.lua
-- GENERATED FILE -- do not edit by hand.
--   regenerate: node tools/gen-dungeon-interruptible.mjs
-- source: Mythic Dungeon Tools (Nnoggie/MythicDungeonTools, Midnight/, ref master),
--         which curates interruptibility per dungeon enemy. MDT is GPL-2.0;
--         this file reproduces spell ids only, and names MDT as the source.
-- spell names resolved from wago.tools DB2 SpellName, build 12.1.0.69933
-- 126 interruptible casts across 16 dungeons

-- This is a BOOTSTRAP, not proof. Unkicked's own learned list
-- (Data/Interruptible.lua, grown from observed SPELL_INTERRUPTs) always
-- wins over it -- including a hand-written [id] = false, which is how you
-- say "MDT is wrong about this one".

local ADDON, ns = ...

ns.DUNGEON_INTERRUPTIBLE_SOURCE = "MDT Midnight @ master"
ns.DUNGEON_INTERRUPTIBLE = {
  -- Algethar Academy (3)
  [388392] = true,  -- Monotonous Lecture -- Unruly Textbook
  [388862] = true,  -- Surge -- Corrupted Manafiend
  [1279627] = true,  -- Arcane Bolt -- Spectral Invoker
  -- Altar of Fangs (4)
  [1289416] = true,  -- Envenom -- High Evolutionist, Ula'tek's Chosen
  [1294557] = true,  -- Piercing Hiss -- Primal Serpent
  [1307567] = true,  -- Mass Envenom -- High Evolutionist, Ula'tek's Chosen
  [1310666] = true,  -- Toxic Atrophy -- Uncoiled Writhe
  -- Den of Nalorakk (9)
  [1235829] = true,  -- Winter's Shroud -- Fractured Shivercore
  [1239394] = true,  -- Scavenge -- Keen-Eyed Striker
  [1241214] = true,  -- Earth Bolt -- Earthwhisper Tender
  [1246687] = true,  -- Lightning Bolt -- Stormbound Mystic
  [1246847] = true,  -- Shoot -- Bonded Beasttamer
  [1290205] = true,  -- Lightning Bolt -- Loa Speaker Nanea
  [1297696] = true,  -- Healing Breeze -- Earthwhisper Tender
  [1297778] = true,  -- Arc Lightning -- Stormbound Mystic
  [1309919] = true,  -- Frigid Roar -- Frigid Mauler
  -- Kings Rest (10)
  [267273] = true,  -- Poison Nova -- Zanazal the Wise
  [267763] = true,  -- Wretched Discharge -- Half-Finished Mummy
  [269369] = true,  -- Deathly Roar -- Reban
  [269972] = true,  -- Hex Volley -- Risen Hexer
  [270492] = true,  -- Hex -- Phantom Hex Priest
  [270901] = true,  -- Unholy Mending -- Seneschal M'bara
  [270920] = true,  -- Bind Soul -- Queen Wasi
  [1294815] = true,  -- Shadowfrost Bolt -- Risen Hexer
  [1294972] = true,  -- Soul Bolt -- Queen Wasi
  [1295125] = true,  -- Spectral Bolt -- Phantom Hex Priest
  -- Magisters Terrace (6)
  [468962] = true,  -- Arcane Bolt -- Arcane Magister
  [468966] = true,  -- Polymorph -- Arcane Magister
  [1248327] = true,  -- Shadow Bolt -- Dreadful Voidwalker
  [1254294] = true,  -- Pyroblast -- Blazing Pyromancer
  [1255187] = true,  -- Holy Fire -- Lightward Healer
  [1264693] = true,  -- Terror Wave -- Void Terror
  -- Maisara Caverns (10)
  [1250708] = true,  -- Necrotic Convergence -- Vordaza
  [1255964] = true,  -- Throw Spear -- Keen Headhunter
  [1256008] = true,  -- Hex -- Ritual Hexxer
  [1256015] = true,  -- Shadow Bolt -- Ritual Hexxer
  [1257716] = true,  -- Reanimation -- Reanimated Warrior
  [1259182] = true,  -- Piercing Screech -- Gloomwing Bat
  [1259255] = true,  -- Spirit Rend -- Tormented Shade
  [1263292] = true,  -- Shrink -- Umbral Shadowbinder
  [1264327] = true,  -- Shadowfrost Blast -- Hollow Soulrender
  [1266381] = true,  -- Hooked Snare -- Keen Headhunter
  -- Murder Row (13)
  [474375] = true,  -- Chaos Bolt -- Lithiel Cinderfury
  [734276] = true,  -- Murder in a Row -- Zaen Bladesorrow
  [1201554] = true,  -- Seduction -- Seductive Sayaad
  [1213658] = true,  -- Unsatisfied Customer -- Rowdy Patron
  [1214922] = true,  -- Fel Rage -- Wrathguard Flayer
  [1214980] = true,  -- Health Funnel -- Fel Invoker
  [1216571] = true,  -- Fel Missiles -- Felonious Mage
  [1216945] = true,  -- Searing Fel Flame -- Lithiel Cinderfury
  [1217099] = true,  -- Fel-Infused Freight -- Forbidden Freight
  [1223204] = true,  -- Felfire Burst -- Unleashed Imp, Wild Imp
  [1257877] = true,  -- Scathing Review -- Influentual Reviewer
  [1264106] = true,  -- Felstorm -- Kystia Manaheart
  [1264110] = true,  -- Felstorm -- Kystia Manaheart
  -- Nexus Point Xenas (13)
  [1249818] = true,  -- Arcane Zap -- Corewright Arcanist
  [1250553] = true,  -- Arcane Zap -- Kasreth
  [1252429] = true,  -- Nullwark Blast -- Null Sentinel
  [1257268] = true,  -- Forfeit Essence -- Smudge
  [1257601] = true,  -- Divine Guile -- Fractured Image
  [1258681] = true,  -- Nullify -- Grand Nullifier
  [1263892] = true,  -- Holy Bolt -- Lightwrought
  [1264295] = true,  -- Nullblast -- Grand Nullifier
  [1269283] = true,  -- Suppression Field -- Flux Engineer
  [1271094] = true,  -- Umbra Bolt -- Nexus Adept
  [1278882] = true,  -- Arcane Zap -- Corewright Arcanist
  [1282722] = true,  -- Nullify -- Grand Nullifier
  [1285445] = true,  -- Arcane Explosion -- Corewright Arcanist
  -- Pit of Saron (8)
  [1258431] = true,  -- Shadow Bolt -- Gloombound Shadebringer
  [1258436] = true,  -- Ice Bolt -- Rimebone Coldwraith
  [1258997] = true,  -- Plungegrip -- Plungetalon Gargoyle
  [1262941] = true,  -- Plague Bolt -- Scourge Plaguespreader
  [1264186] = true,  -- Shadowbind -- Shade of Krick
  [1271074] = true,  -- Icy Blast -- Dreadpulse Lich
  [1271479] = true,  -- Netherburst -- Arcanist Cadaver
  [1278893] = true,  -- Death Bolt -- Krick
  -- Ruby Life Pools (9)
  [371984] = true,  -- Frostbolt -- Flashfrost Chillweaver
  [372743] = true,  -- Ice Shield -- Flashfrost Chillweaver
  [372808] = true,  -- Frigid Shard -- Melidrussa Chillworn
  [373017] = true,  -- Blaze Volley -- Blazebound Firestorm
  [384194] = true,  -- Cinderbolt -- Primalist Cinderweaver
  [384933] = true,  -- Ice Shield -- Earthbound Guardian, Flashfrost Chillweaver
  [385310] = true,  -- Storm Bolt -- Ruinous Stormbringer
  [392576] = true,  -- Thunder Blast -- Tempest Channeler
  [1305955] = true,  -- Fiery Blast -- Blazebound Destroyer
  -- Seat of the Triumvirate (6)
  [244750] = true,  -- Mind Blast -- Viceroy Nezhar
  [248831] = true,  -- Dread Screech -- Shadewing
  [1262510] = true,  -- Umbral Bolt -- Dark Conjurer
  [1262523] = true,  -- Summon Voidcaller -- Dark Conjurer
  [1262526] = true,  -- Abyssal Enhancement -- Dire Voidbender
  [1277340] = true,  -- Shadowmend -- Ruthless Riftstalker
  -- Skyreach (4)
  [152953] = true,  -- Blinding Light -- Blinding Sun Priestess
  [154396] = true,  -- Solar Blast -- High Sage Viryx
  [1254669] = true,  -- Solar Bolt -- Initiate of the Rising Sun
  [1255377] = true,  -- Repel -- Driving Gale-Caller
  -- Temple of Sethraliss (9)
  [267027] = true,  -- Poison Spit -- Toxic Viper
  [268013] = true,  -- Flame Shock -- Twisted Hexxer
  [1291262] = true,  -- Lightning Bolt -- Storm Adept, Imbued Stormcaller
  [1293307] = true,  -- Addle Mind -- Faithless Subjugator
  [1302158] = true,  -- Flame Shock -- Twisted Hexxer
  [1308100] = true,  -- Poisoned Cheap Shot -- Shrouded Fang
  [1308148] = true,  -- Cytotoxin -- Poisonous Viper
  [1310683] = true,  -- Venom Bolt -- Brood Tender
  [1314082] = true,  -- Addle Mind -- Faithless Subjugator
  -- the Blinding Vale (9)
  [1235616] = true,  -- Light Bolt -- Kezkitt
  [1238063] = true,  -- Light Bolt -- Radiant Spellsower
  [1238158] = true,  -- Lightbloom Pollination -- Lightgorged Lasher
  [1238200] = true,  -- Frantic Blooming -- Radiant Spellsower
  [1238232] = true,  -- Seed Shot -- Leafy Grovecrawler
  [1238294] = true,  -- Disorienting Screech -- Lightfeather Petalwing
  [1239821] = true,  -- Warden's Wrath -- Lightwarden Ruia
  [1247669] = true,  -- Lightspore Shot -- Lightspawn Lasher
  [1301834] = true,  -- Light Bolt Volley -- Radiant Spellsower
  -- Voidscar Arena (6)
  [1228176] = true,  -- Lava Bolt -- Enthralled Shaman
  [1233398] = true,  -- Mad Shriek -- Kilivore Screamer
  [1249621] = true,  -- Violent Sand -- Angry Krolusk
  [1298899] = true,  -- Demoralizing Shout -- Dominated Brawler
  [1299938] = true,  -- Shadowbolt Volley -- Voidtouched Magi
  [1310324] = true,  -- Mending Void -- Devouring Brutalizer, Voidminder
  -- Windrunner Spire (7)
  [472724] = true,  -- Shadow Bolt -- Kalis
  [473657] = true,  -- Shadow Bolt -- Devoted Woebringer
  [473663] = true,  -- Pulsing Shriek -- Devoted Woebringer
  [473794] = true,  -- Poison Blades -- Ardent Cutthroat
  [1216135] = true,  -- Spirit Bolt -- Restless Steward
  [1216592] = true,  -- Chain Lightning -- Phantasmal Mystic
  [1216819] = true,  -- Fungal Bolt -- Bloated Lasher
}
