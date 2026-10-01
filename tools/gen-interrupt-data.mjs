#!/usr/bin/env node
// Generates Data/InterruptData.lua from wago.tools DB2 exports, pinned to a build.
//
//   node tools/gen-interrupt-data.mjs                 # pin to current live retail build
//   node tools/gen-interrupt-data.mjs --build 12.1.0.69933
//   node tools/gen-interrupt-data.mjs --report         # also print the talent evidence table
//
// What it produces:
//   * base cooldown per interrupt spell, read as max(RecoveryTime, CategoryRecoveryTime)
//     because Blizzard stores it in one field or the other and never consistently.
//   * per-class talent gate: does a node in that class's trait tree reduce the
//     interrupt's cooldown, by how much, and therefore what the floor is.
//
// The talent gate is a CANDIDATE finder, not an oracle. Everything it emits carries
// its evidence (talent spellID, effect, match path) so a human can confirm it. See
// REQUIREMENTS.md R-4.

import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { Db2, liveBuild, num } from "./lib/db2.mjs";

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, "..");

// ---------------------------------------------------------------- seed table
// The interrupts themselves. Hand-maintained because there is no DB2 flag that
// means "this spell is an interrupt" (label 16 is generic -- 16k spells carry it).
// New interrupts arrive roughly once per expansion; the generator validates every
// entry against spell data and fails loudly if an ID stops resolving.
const INTERRUPTS = [
  { id: 57994,  name: "Wind Shear",         class: "SHAMAN",      specs: ["Elemental", "Enhancement", "Restoration"] },
  { id: 1766,   name: "Kick",               class: "ROGUE",       specs: ["Assassination", "Outlaw", "Subtlety"] },
  { id: 6552,   name: "Pummel",             class: "WARRIOR",     specs: ["Arms", "Fury", "Protection"] },
  { id: 47528,  name: "Mind Freeze",        class: "DEATHKNIGHT", specs: ["Blood", "Frost", "Unholy"] },
  { id: 106839, name: "Skull Bash",         class: "DRUID",       specs: ["Feral", "Guardian"] },
  { id: 96231,  name: "Rebuke",             class: "PALADIN",     specs: ["Holy", "Protection", "Retribution"] },
  { id: 116705, name: "Spear Hand Strike",  class: "MONK",        specs: ["Brewmaster", "Mistweaver", "Windwalker"] },
  { id: 183752, name: "Disrupt",            class: "DEMONHUNTER", specs: ["Havoc", "Vengeance"] },
  { id: 187707, name: "Muzzle",             class: "HUNTER",      specs: ["Survival"] },
  { id: 147362, name: "Counter Shot",       class: "HUNTER",      specs: ["Beast Mastery", "Marksmanship"] },
  { id: 19647,  name: "Spell Lock",         class: "WARLOCK",     specs: ["Affliction", "Demonology", "Destruction"], pet: true },
  { id: 2139,   name: "Counterspell",       class: "MAGE",        specs: ["Arcane", "Fire", "Frost"] },
  { id: 351338, name: "Quell",              class: "EVOKER",      specs: ["Devastation", "Preservation", "Augmentation"] },
  { id: 15487,  name: "Silence",            class: "PRIEST",      specs: ["Shadow"] },
  { id: 78675,  name: "Solar Beam",         class: "DRUID",       specs: ["Balance"] },
];

const CLASS_SKILL_LINE = {
  DEATHKNIGHT: "Death Knight", DEMONHUNTER: "Demon Hunter", DRUID: "Druid",
  EVOKER: "Evoker", HUNTER: "Hunter", MAGE: "Mage", MONK: "Monk",
  PALADIN: "Paladin", PRIEST: "Priest", ROGUE: "Rogue", SHAMAN: "Shaman",
  WARLOCK: "Warlock", WARRIOR: "Warrior",
};

// Effect / aura ids that move a cooldown. Verified against live 12.1 data:
//   292 modifies a cooldown by SpellCategory (this is how Coldthirst 378849 works)
// The modifier auras are matched by spell-family mask or by spell label.
const EFFECT_MODIFY_COOLDOWN_BY_CATEGORY = 292;
const COOLDOWN_MOD_AURAS = new Set([
  107, // ADD_FLAT_MODIFIER        (misc0 = SpellModOp, matched by class mask)
  108, // ADD_PCT_MODIFIER
  453, // ADD_FLAT_MODIFIER_BY_SPELL_LABEL  (misc1 = label)
  454, // ADD_PCT_MODIFIER_BY_SPELL_LABEL
]);
const SPELLMOD_COOLDOWN = new Set([11, 34]); // Cooldown, CooldownRecoveryRate-ish

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };

async function main() {
  const build = opt("--build") || (await liveBuild("wow"));
  const db = new Db2(build, path.join(HERE, ".cache"));
  console.error(`[unkicked] build ${build}`);

  const [cooldowns, categories, classOptions, labels, effects, spellNames,
         skillLine, slxTree, nodes, nodeXEntry, nodeEntries, definitions,
         specs, classes] =
    await Promise.all([
      db.table("SpellCooldowns"), db.table("SpellCategories"),
      db.table("SpellClassOptions"), db.table("SpellLabel"),
      db.table("SpellEffect"), db.table("SpellName"),
      db.table("SkillLine"), db.table("SkillLineXTraitTree"),
      db.table("TraitNode"), db.table("TraitNodeXTraitNodeEntry"),
      db.table("TraitNodeEntry"), db.table("TraitDefinition"),
      db.table("ChrSpecialization"), db.table("ChrClasses"),
    ]);

  const nameOf = new Map(spellNames.map((r) => [num(r.ID), r.Name_lang]));

  // --- base cooldowns -------------------------------------------------------
  const cdBySpell = new Map();
  for (const r of cooldowns) {
    if (num(r.DifficultyID) !== 0) continue;
    const cd = Math.max(num(r.RecoveryTime), num(r.CategoryRecoveryTime));
    if (cd > 0) cdBySpell.set(num(r.SpellID), cd);
  }

  const categoryOf = new Map();
  for (const r of categories) {
    if (num(r.DifficultyID) !== 0) continue;
    categoryOf.set(num(r.SpellID), num(r.Category));
  }

  const classOptOf = new Map();
  for (const r of classOptions) {
    classOptOf.set(num(r.SpellID), {
      set: num(r.SpellClassSet),
      mask: [0, 1, 2, 3].map((i) => num(r[`SpellClassMask_${i}`])),
    });
  }

  const labelsOf = new Map();
  for (const r of labels) {
    const s = num(r.SpellID);
    if (!labelsOf.has(s)) labelsOf.set(s, new Set());
    labelsOf.get(s).add(num(r.LabelID));
  }

  const effectsOf = new Map();
  for (const r of effects) {
    if (num(r.DifficultyID) !== 0) continue;
    const s = num(r.SpellID);
    if (!effectsOf.has(s)) effectsOf.set(s, []);
    effectsOf.get(s).push(r);
  }

  // --- class trait trees ----------------------------------------------------
  const treeForClass = {};
  const skillIdByName = new Map(skillLine.map((r) => [r.DisplayName_lang, num(r.ID)]));
  for (const [cls, display] of Object.entries(CLASS_SKILL_LINE)) {
    const sid = skillIdByName.get(display);
    const row = slxTree.find((r) => num(r.SkillLineID) === sid);
    if (!row) throw new Error(`no trait tree for ${cls} (skill line ${display})`);
    treeForClass[cls] = num(row.TraitTreeID);
  }

  const entryById = new Map(nodeEntries.map((r) => [num(r.ID), r]));
  const defById = new Map(definitions.map((r) => [num(r.ID), r]));
  const entriesByNode = new Map();
  for (const r of nodeXEntry) {
    const n = num(r.TraitNodeID);
    if (!entriesByNode.has(n)) entriesByNode.set(n, []);
    entriesByNode.get(n).push(num(r.TraitNodeEntryID));
  }

  // talent spells per tree, and the node ENTRY ids each talent spell sits behind.
  // The entry id is what a combat log's COMBATANT_INFO reports, so it is the only
  // thing that can answer "did this player actually take that talent" offline.
  const spellsByTree = new Map();
  const entriesBySpell = new Map();
  for (const n of nodes) {
    const tree = num(n.TraitTreeID);
    if (!spellsByTree.has(tree)) spellsByTree.set(tree, new Set());
    for (const eid of entriesByNode.get(num(n.ID)) || []) {
      const e = entryById.get(eid);
      if (!e) continue;
      const d = defById.get(num(e.TraitDefinitionID));
      if (!d) continue;
      const sp = num(d.SpellID);
      if (!sp) continue;
      spellsByTree.get(tree).add(sp);
      if (!entriesBySpell.has(sp)) entriesBySpell.set(sp, new Set());
      entriesBySpell.get(sp).add(eid);
    }
  }

  // --- the join -------------------------------------------------------------
  // Expand a talent spell into itself plus everything it triggers, two hops deep,
  // because refund-style talents (Coldthirst) put the cooldown effect in a
  // proc-triggered spell rather than in the talent itself.
  function expand(spellId, depth = 2, seen = new Set()) {
    if (seen.has(spellId) || depth < 0) return seen;
    seen.add(spellId);
    for (const e of effectsOf.get(spellId) || []) {
      const t = num(e.EffectTriggerSpell);
      if (t) expand(t, depth - 1, seen);
    }
    return seen;
  }

  function matchesInterrupt(effect, target) {
    const aura = num(effect.EffectAura);
    const eff = num(effect.Effect);
    const misc0 = num(effect.EffectMiscValue_0);
    const misc1 = num(effect.EffectMiscValue_1);

    if (eff === EFFECT_MODIFY_COOLDOWN_BY_CATEGORY) {
      if (target.category && misc0 === target.category) return "category";
      return null;
    }
    if (!COOLDOWN_MOD_AURAS.has(aura)) return null;

    if (aura === 453 || aura === 454) {
      if (!SPELLMOD_COOLDOWN.has(misc0)) return null;
      return target.labels.has(misc1) ? "label" : null;
    }
    if (!SPELLMOD_COOLDOWN.has(misc0)) return null;
    const mask = [0, 1, 2, 3].map((i) => num(effect[`EffectSpellClassMask_${i}`]));
    const hit = mask.some((m, i) => m & target.mask[i]);
    return hit ? "classmask" : null;
  }

  const results = [];
  const evidence = [];

  for (const ix of INTERRUPTS) {
    const baseMs = cdBySpell.get(ix.id);
    if (!baseMs) throw new Error(`${ix.name} (${ix.id}): no cooldown row in SpellCooldowns`);
    const live = nameOf.get(ix.id);
    if (!live) throw new Error(`${ix.name} (${ix.id}): spell id does not resolve on ${build}`);

    const co = classOptOf.get(ix.id) || { set: 0, mask: [0, 0, 0, 0] };
    const target = {
      category: categoryOf.get(ix.id) || 0,
      labels: labelsOf.get(ix.id) || new Set(),
      mask: co.mask,
      set: co.set,
    };

    const tree = treeForClass[ix.class];
    const reductions = [];
    for (const talent of spellsByTree.get(tree) || []) {
      for (const sp of expand(talent)) {
        for (const e of effectsOf.get(sp) || []) {
          const how = matchesInterrupt(e, target);
          if (!how) continue;
          const pts = num(e.EffectBasePointsF);
          const aura = num(e.EffectAura);
          const pct = aura === 108 || aura === 454;
          if (pts >= 0) continue; // downward-only: a talent that lengthens a CD is not a thing we model
          reductions.push({
            talent, talentName: nameOf.get(talent) || `spell:${talent}`,
            entryIDs: [...(entriesBySpell.get(talent) || [])].sort((a, b) => a - b),
            via: sp === talent ? null : sp,
            how, pct, amount: Math.abs(pts), effect: num(e.Effect), aura,
          });
        }
      }
    }

    // One floor per interrupt: the deepest reduction any single talent can apply.
    let floorMs = baseMs;
    for (const r of reductions) {
      const after = r.pct ? baseMs * (1 - r.amount / 100) : baseMs - r.amount;
      if (after < floorMs) floorMs = after;
    }

    const uniq = [...new Map(reductions.map((r) => [`${r.talent}:${r.amount}:${r.how}`, r])).values()];
    results.push({ ...ix, liveName: live, baseMs, floorMs: Math.max(0, Math.round(floorMs)), reductions: uniq });
    uniq.forEach((r) => evidence.push({ interrupt: ix.name, ...r }));
  }

  // --- spec -> interrupt ----------------------------------------------------
  // In game we cannot tell a Survival hunter from a Marksmanship one without
  // inspecting, so an ambiguous class stays unbound. A combat log's
  // COMBATANT_INFO states the spec id outright, which resolves every one of them.
  const classFileById = new Map(classes.map((r) => [num(r.ID), r.Filename]));
  const specRows = specs
    .filter((r) => num(r.ClassID) > 0)
    .map((r) => ({ id: num(r.ID), name: r.Name_lang, cls: classFileById.get(num(r.ClassID)) }));

  const specInterrupt = [];
  for (const r of results) {
    for (const specName of r.specs) {
      const hit = specRows.find((s) => s.cls === r.class && s.name === specName);
      if (!hit) throw new Error(`${r.class} spec "${specName}" not found in ChrSpecialization`);
      specInterrupt.push({ specID: hit.id, class: r.class, spec: specName, spellID: r.id });
    }
  }
  specInterrupt.sort((a, b) => a.specID - b.specID);

  // --- emit -----------------------------------------------------------------
  const lua = renderLua(build, results, specInterrupt);
  const out = path.join(ROOT, "Data", "InterruptData.lua");
  fs.writeFileSync(out, lua);
  console.error(`[unkicked] wrote ${path.relative(ROOT, out)} (${results.length} interrupts, ${evidence.length} talent matches)`);

  if (flag("--report")) {
    console.log(`\nbuild ${build} -- talent cooldown-reduction evidence\n`);
    for (const r of results) {
      const cd = (r.baseMs / 1000).toFixed(0);
      const fl = (r.floorMs / 1000).toFixed(1);
      console.log(`${r.name} (${r.id})  base ${cd}s  floor ${fl}s  [${r.class}]`);
      if (!r.reductions.length) console.log("    no cooldown-reduction talent found");
      for (const d of r.reductions) {
        const amt = d.pct ? `${d.amount}%` : `${(d.amount / 1000).toFixed(1)}s`;
        const via = d.via ? ` via ${d.via}` : "";
        console.log(`    -${amt}  ${d.talentName} (${d.talent})${via}  match=${d.how} effect=${d.effect} aura=${d.aura}`);
      }
    }
  }
}

function renderLua(build, results, specInterrupt) {
  const L = [];
  L.push("-- Unkicked :: InterruptData.lua");
  L.push("-- GENERATED FILE -- do not edit by hand.");
  L.push("--   regenerate: node tools/gen-interrupt-data.mjs --report");
  L.push(`-- source: wago.tools DB2 export, build ${build}`);
  L.push("");
  L.push("local ADDON, ns = ...");
  L.push("");
  L.push(`ns.DATA_BUILD = "${build}"`);
  L.push("");
  L.push("-- baseMs : cooldown as shipped, max(RecoveryTime, CategoryRecoveryTime)");
  L.push("-- floorMs: lowest cooldown any talent in that class tree can produce.");
  L.push("--          A measured interval below this is noise, not a talent (R-3).");
  L.push("-- talents: evidence rows. Non-empty means the spec is ELIGIBLE for a");
  L.push("--          downward correction; it does NOT mean the player took one.");
  L.push("ns.INTERRUPTS = {");
  for (const r of results) {
    L.push(`  [${r.id}] = {`);
    L.push(`    name = ${JSON.stringify(r.liveName)},`);
    L.push(`    class = "${r.class}",`);
    L.push(`    specs = { ${r.specs.map((s) => JSON.stringify(s)).join(", ")} },`);
    if (r.pet) L.push("    pet = true,");
    L.push(`    baseMs = ${r.baseMs},`);
    L.push(`    floorMs = ${r.floorMs},`);
    L.push(`    eligible = ${r.reductions.length > 0 ? "true" : "false"},`);
    if (r.reductions.length) {
      L.push("    talents = {");
      for (const d of r.reductions) {
        const amt = d.pct ? `pctReduction = ${d.amount}` : `flatReductionMs = ${d.amount}`;
        L.push(`      { spellID = ${d.talent}, name = ${JSON.stringify(d.talentName)}, ${amt}, match = "${d.how}" },`);
      }
      L.push("    },");
    } else {
      L.push("    talents = {},");
    }
    L.push("  },");
  }
  L.push("}");
  L.push("");
  L.push("-- Reverse index: spellID lookup is the hot path in the combat-log handler.");
  L.push("ns.IS_INTERRUPT = {}");
  L.push("for id in pairs(ns.INTERRUPTS) do ns.IS_INTERRUPT[id] = true end");
  L.push("");
  L.push("-- specID -> the interrupt that spec has. Unusable in game (you cannot read");
  L.push("-- another player's spec on 12.x) but exact offline: COMBATANT_INFO states it.");
  L.push("ns.SPEC_INTERRUPT = {");
  for (const s of specInterrupt) {
    L.push(`  [${s.specID}] = { class = "${s.class}", spec = ${JSON.stringify(s.spec)}, spellID = ${s.spellID} },`);
  }
  L.push("}");
  L.push("");
  L.push("-- traitNodeEntryID -> the interrupt cooldown reduction that entry grants.");
  L.push("-- COMBATANT_INFO lists the entry ids a player actually selected, so offline");
  L.push("-- this turns the talent GATE (R-3) into a talent FACT: no learning needed.");
  L.push("-- conditional = the reduction came from a proc-triggered spell, so it only");
  L.push("--   applies on a successful interrupt (Coldthirst). false = always applies.");
  L.push("ns.TRAIT_CD = {");
  for (const r of results) {
    for (const d of r.reductions) {
      const amt = d.pct ? `pctReduction = ${d.amount}` : `flatReductionMs = ${d.amount}`;
      for (const eid of d.entryIDs || []) {
        L.push(`  [${eid}] = { spellID = ${r.id}, talentID = ${d.talent}, name = ${JSON.stringify(d.talentName)}, ${amt}, conditional = ${d.via ? "true" : "false"} },`);
      }
    }
  }
  L.push("}");
  L.push("");
  return L.join("\n");
}

main().catch((e) => { console.error(`[unkicked] ${e.message}`); process.exit(1); });
