-- Unkicked :: InterruptData.lua
-- GENERATED FILE -- do not edit by hand.
--   regenerate: node tools/gen-interrupt-data.mjs --report
-- source: wago.tools DB2 export, build 12.1.0.69933

local ADDON, ns = ...

ns.DATA_BUILD = "12.1.0.69933"

-- baseMs : cooldown as shipped, max(RecoveryTime, CategoryRecoveryTime)
-- floorMs: lowest cooldown any talent in that class tree can produce.
--          A measured interval below this is noise, not a talent (R-3).
-- talents: evidence rows. Non-empty means the spec is ELIGIBLE for a
--          downward correction; it does NOT mean the player took one.
ns.INTERRUPTS = {
  [57994] = {
    name = "Wind Shear",
    class = "SHAMAN",
    specs = { "Elemental", "Enhancement", "Restoration" },
    baseMs = 12000,
    floorMs = 12000,
    eligible = false,
    talents = {},
  },
  [1766] = {
    name = "Kick",
    class = "ROGUE",
    specs = { "Assassination", "Outlaw", "Subtlety" },
    baseMs = 15000,
    floorMs = 15000,
    eligible = false,
    talents = {},
  },
  [6552] = {
    name = "Pummel",
    class = "WARRIOR",
    specs = { "Arms", "Fury", "Protection" },
    baseMs = 15000,
    floorMs = 13500,
    eligible = true,
    talents = {
      { spellID = 391271, name = "Honed Reflexes", pctReduction = 10, match = "classmask" },
    },
  },
  [47528] = {
    name = "Mind Freeze",
    class = "DEATHKNIGHT",
    specs = { "Blood", "Frost", "Unholy" },
    baseMs = 15000,
    floorMs = 12000,
    eligible = true,
    talents = {
      { spellID = 378848, name = "Coldthirst", flatReductionMs = 3000, match = "category" },
    },
  },
  [106839] = {
    name = "Skull Bash",
    class = "DRUID",
    specs = { "Feral", "Guardian" },
    baseMs = 15000,
    floorMs = 15000,
    eligible = false,
    talents = {},
  },
  [96231] = {
    name = "Rebuke",
    class = "PALADIN",
    specs = { "Holy", "Protection", "Retribution" },
    baseMs = 15000,
    floorMs = 15000,
    eligible = false,
    talents = {},
  },
  [116705] = {
    name = "Spear Hand Strike",
    class = "MONK",
    specs = { "Brewmaster", "Mistweaver", "Windwalker" },
    baseMs = 15000,
    floorMs = 15000,
    eligible = false,
    talents = {},
  },
  [183752] = {
    name = "Disrupt",
    class = "DEMONHUNTER",
    specs = { "Havoc", "Vengeance" },
    baseMs = 15000,
    floorMs = 15000,
    eligible = false,
    talents = {},
  },
  [187707] = {
    name = "Muzzle",
    class = "HUNTER",
    specs = { "Survival" },
    baseMs = 15000,
    floorMs = 15000,
    eligible = false,
    talents = {},
  },
  [147362] = {
    name = "Counter Shot",
    class = "HUNTER",
    specs = { "Beast Mastery", "Marksmanship" },
    baseMs = 24000,
    floorMs = 24000,
    eligible = false,
    talents = {},
  },
  [19647] = {
    name = "Spell Lock",
    class = "WARLOCK",
    specs = { "Affliction", "Demonology", "Destruction" },
    pet = true,
    baseMs = 24000,
    floorMs = 24000,
    eligible = false,
    talents = {},
  },
  [2139] = {
    name = "Counterspell",
    class = "MAGE",
    specs = { "Arcane", "Fire", "Frost" },
    baseMs = 25000,
    floorMs = 25000,
    eligible = false,
    talents = {},
  },
  [351338] = {
    name = "Quell",
    class = "EVOKER",
    specs = { "Devastation", "Preservation", "Augmentation" },
    baseMs = 20000,
    floorMs = 20000,
    eligible = false,
    talents = {},
  },
  [15487] = {
    name = "Silence",
    class = "PRIEST",
    specs = { "Shadow" },
    baseMs = 30000,
    floorMs = 30000,
    eligible = false,
    talents = {},
  },
  [78675] = {
    name = "Solar Beam",
    class = "DRUID",
    specs = { "Balance" },
    baseMs = 60000,
    floorMs = 60000,
    eligible = false,
    talents = {},
  },
}

-- Reverse index: spellID lookup is the hot path in the combat-log handler.
ns.IS_INTERRUPT = {}
for id in pairs(ns.INTERRUPTS) do ns.IS_INTERRUPT[id] = true end
