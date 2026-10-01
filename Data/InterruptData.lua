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

-- specID -> the interrupt that spec has. Unusable in game (you cannot read
-- another player's spec on 12.x) but exact offline: COMBATANT_INFO states it.
ns.SPEC_INTERRUPT = {
  [62] = { class = "MAGE", spec = "Arcane", spellID = 2139 },
  [63] = { class = "MAGE", spec = "Fire", spellID = 2139 },
  [64] = { class = "MAGE", spec = "Frost", spellID = 2139 },
  [65] = { class = "PALADIN", spec = "Holy", spellID = 96231 },
  [66] = { class = "PALADIN", spec = "Protection", spellID = 96231 },
  [70] = { class = "PALADIN", spec = "Retribution", spellID = 96231 },
  [71] = { class = "WARRIOR", spec = "Arms", spellID = 6552 },
  [72] = { class = "WARRIOR", spec = "Fury", spellID = 6552 },
  [73] = { class = "WARRIOR", spec = "Protection", spellID = 6552 },
  [102] = { class = "DRUID", spec = "Balance", spellID = 78675 },
  [103] = { class = "DRUID", spec = "Feral", spellID = 106839 },
  [104] = { class = "DRUID", spec = "Guardian", spellID = 106839 },
  [250] = { class = "DEATHKNIGHT", spec = "Blood", spellID = 47528 },
  [251] = { class = "DEATHKNIGHT", spec = "Frost", spellID = 47528 },
  [252] = { class = "DEATHKNIGHT", spec = "Unholy", spellID = 47528 },
  [253] = { class = "HUNTER", spec = "Beast Mastery", spellID = 147362 },
  [254] = { class = "HUNTER", spec = "Marksmanship", spellID = 147362 },
  [255] = { class = "HUNTER", spec = "Survival", spellID = 187707 },
  [258] = { class = "PRIEST", spec = "Shadow", spellID = 15487 },
  [259] = { class = "ROGUE", spec = "Assassination", spellID = 1766 },
  [260] = { class = "ROGUE", spec = "Outlaw", spellID = 1766 },
  [261] = { class = "ROGUE", spec = "Subtlety", spellID = 1766 },
  [262] = { class = "SHAMAN", spec = "Elemental", spellID = 57994 },
  [263] = { class = "SHAMAN", spec = "Enhancement", spellID = 57994 },
  [264] = { class = "SHAMAN", spec = "Restoration", spellID = 57994 },
  [265] = { class = "WARLOCK", spec = "Affliction", spellID = 19647 },
  [266] = { class = "WARLOCK", spec = "Demonology", spellID = 19647 },
  [267] = { class = "WARLOCK", spec = "Destruction", spellID = 19647 },
  [268] = { class = "MONK", spec = "Brewmaster", spellID = 116705 },
  [269] = { class = "MONK", spec = "Windwalker", spellID = 116705 },
  [270] = { class = "MONK", spec = "Mistweaver", spellID = 116705 },
  [577] = { class = "DEMONHUNTER", spec = "Havoc", spellID = 183752 },
  [581] = { class = "DEMONHUNTER", spec = "Vengeance", spellID = 183752 },
  [1467] = { class = "EVOKER", spec = "Devastation", spellID = 351338 },
  [1468] = { class = "EVOKER", spec = "Preservation", spellID = 351338 },
  [1473] = { class = "EVOKER", spec = "Augmentation", spellID = 351338 },
}

-- traitNodeEntryID -> the interrupt cooldown reduction that entry grants.
-- COMBATANT_INFO lists the entry ids a player actually selected, so offline
-- this turns the talent GATE (R-3) into a talent FACT: no learning needed.
-- conditional = the reduction came from a proc-triggered spell, so it only
--   applies on a successful interrupt (Coldthirst). false = always applies.
ns.TRAIT_CD = {
  [116924] = { spellID = 6552, talentID = 391271, name = "Honed Reflexes", pctReduction = 10, conditional = false },
  [118850] = { spellID = 6552, talentID = 391271, name = "Honed Reflexes", pctReduction = 10, conditional = false },
  [96212] = { spellID = 47528, talentID = 378848, name = "Coldthirst", flatReductionMs = 3000, conditional = true },
}
