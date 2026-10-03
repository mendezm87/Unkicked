#!/usr/bin/env node
// Generates Data/DungeonInterruptible.lua -- which enemy casts in the current
// Mythic+ pool can be interrupted, for every dungeon, before we have ever seen
// one of them in a log.
//
//   node tools/gen-dungeon-interruptible.mjs            # pin spell names to live build
//   node tools/gen-dungeon-interruptible.mjs --report   # print the per-dungeon table
//   node tools/gen-dungeon-interruptible.mjs --check    # compare against what logs proved
//
// WHY THIS EXISTS (REQUIREMENTS.md R-35)
// The learned list in parser/learned-interruptible.lua is proof -- a
// SPELL_INTERRUPT was seen stopping the spell -- but it only ever knows the
// dungeons you have already run. Ruby Life Pools shared ZERO spell ids with the
// three dungeons parsed before it, so its first run reported nothing kickable.
// A bootstrap list fixes the cold start; the learned list still overrides it.
//
// WHY NOT DB2 (measured, 2026-10-03, build 12.1.0.69933)
// SpellInterrupts.InterruptFlags looks like the answer and is not.
// ON_INTERRUPT_CAST (0x04) or ON_INTERRUPT_ALL (0x20) is set on 53,444 of the
// 122,119 spells in the table -- including the player's own Fireball, and
// including 31 of the 34 distinct NPC casts in the Ruby Life Pools log when only
// 9 of them were ever actually stopped. The flags describe what KIND of
// interruption applies to a cast template; whether a given creature's cast is
// immune is set by the encounter script and is not in any DB2 we can read. So
// the flag is a necessary condition, not a sufficient one, and using it would
// have inflated the kickable column with boss mechanics nobody can stop.
//
// SOURCE AND LICENSE -- READ BEFORE SHIPPING
// The data comes from Mythic Dungeon Tools, which curates it per dungeon:
//   https://github.com/Nnoggie/MythicDungeonTools  (Midnight/<Dungeon>.lua)
// MDT is GPL-2.0. Unkicked is MIT. This generator does not copy MDT code -- it
// reads a table of spell ids, which are game facts -- but the output file names
// MDT as its source and carries that notice, and the licence question is the
// user's call to make, not this script's. See REQUIREMENTS.md R-35.

import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { Db2, liveBuild, num } from "./lib/db2.mjs";

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, "..");

const MDT_REPO = "Nnoggie/MythicDungeonTools";
const MDT_REF = "master";
const MDT_DIR = "Midnight";   // the current expansion's dungeon pool

const args = process.argv.slice(2);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };

// ----------------------------------------------------------------- fetching
async function dungeonFiles() {
  const url = `https://api.github.com/repos/${MDT_REPO}/contents/${MDT_DIR}?ref=${MDT_REF}`;
  const res = await fetch(url, { headers: { "User-Agent": "unkicked-gen" } });
  if (!res.ok) throw new Error(`MDT listing: HTTP ${res.status} (${url})`);
  return (await res.json())
    .filter((e) => e.type === "file" && e.name.endsWith(".lua") && !e.name.startsWith("load_"))
    .map((e) => e.name.replace(/\.lua$/, ""));
}

async function dungeonSource(name) {
  const url = `https://raw.githubusercontent.com/${MDT_REPO}/${MDT_REF}/${MDT_DIR}/${name}.lua`;
  const res = await fetch(url, { headers: { "User-Agent": "unkicked-gen" } });
  if (!res.ok) throw new Error(`${name}: HTTP ${res.status}`);
  return res.text();
}

// ------------------------------------------------------------------ parsing
// MDT's shape, per enemy:
//   ["name"] = "Flashfrost Chillweaver",
//   ["spells"] = { [371984] = { ["interruptible"] = true, }, [372743] = {}, }
// Only the entries that CARRY the flag are interruptible. An empty body means
// MDT has not said -- which is not the same as "no", so those are skipped
// rather than recorded as immune.
function extract(src) {
  const out = new Map();           // spellID -> Set of caster names
  const enemy = /\["name"\]\s*=\s*"((?:[^"\\]|\\.)*)"/g;
  // Walk enemies in order so a spell block can be attributed to the enemy above it.
  const marks = [];
  for (let m; (m = enemy.exec(src)); ) marks.push({ at: m.index, name: m[1] });

  const spell = /\[(\d{3,8})\]\s*=\s*\{([^{}]*)\}/g;
  for (let m; (m = spell.exec(src)); ) {
    if (!/\["interruptible"\]\s*=\s*true/.test(m[2])) continue;
    const id = Number(m[1]);
    // nearest preceding enemy name
    let who = null;
    for (const k of marks) { if (k.at < m.index) who = k.name; else break; }
    if (!out.has(id)) out.set(id, new Set());
    if (who) out.get(id).add(who);
  }
  return out;
}

function pretty(name) {
  return name.replace(/ofthe/g, "OfThe")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/\bOf\b/g, "of").replace(/\bThe\b/g, "the");
}

// -------------------------------------------------------------------- main
async function main() {
  const build = opt("--build") || await liveBuild();
  const names = await dungeonFiles();
  if (!names.length) throw new Error("MDT listing returned no dungeon files");

  const perDungeon = [];
  for (const n of names) {
    const ids = extract(await dungeonSource(n));
    perDungeon.push({ file: n, label: pretty(n), ids });
  }

  // Spell names, so the generated file is readable and a dead id is visible.
  const db = new Db2(build, path.join(HERE, ".cache"));
  const spellName = new Map();
  for (const r of await db.table("SpellName")) spellName.set(num(r.ID), r.Name_lang);

  const union = new Map();   // id -> { dungeons:Set, casters:Set }
  for (const d of perDungeon) {
    for (const [id, casters] of d.ids) {
      if (!union.has(id)) union.set(id, { dungeons: new Set(), casters: new Set() });
      union.get(id).dungeons.add(d.label);
      for (const c of casters) union.get(id).casters.add(c);
    }
  }

  const unresolved = [...union.keys()].filter((id) => !spellName.get(id));

  const L = [];
  L.push("-- Unkicked :: DungeonInterruptible.lua");
  L.push("-- GENERATED FILE -- do not edit by hand.");
  L.push("--   regenerate: node tools/gen-dungeon-interruptible.mjs");
  L.push(`-- source: Mythic Dungeon Tools (${MDT_REPO}, ${MDT_DIR}/, ref ${MDT_REF}),`);
  L.push("--         which curates interruptibility per dungeon enemy. MDT is GPL-2.0;");
  L.push("--         this file reproduces spell ids only, and names MDT as the source.");
  L.push(`-- spell names resolved from wago.tools DB2 SpellName, build ${build}`);
  L.push(`-- ${union.size} interruptible casts across ${perDungeon.length} dungeons`);
  L.push("");
  L.push("-- This is a BOOTSTRAP, not proof. Unkicked's own learned list");
  L.push("-- (Data/Interruptible.lua, grown from observed SPELL_INTERRUPTs) always");
  L.push("-- wins over it -- including a hand-written [id] = false, which is how you");
  L.push("-- say \"MDT is wrong about this one\".");
  L.push("");
  L.push("local ADDON, ns = ...");
  L.push("");
  L.push(`ns.DUNGEON_INTERRUPTIBLE_SOURCE = "MDT ${MDT_DIR} @ ${MDT_REF}"`);
  L.push("ns.DUNGEON_INTERRUPTIBLE = {");
  for (const d of perDungeon) {
    if (!d.ids.size) { L.push(`  -- ${d.label}: MDT lists none`); continue; }
    L.push(`  -- ${d.label} (${d.ids.size})`);
    for (const id of [...d.ids.keys()].sort((a, b) => a - b)) {
      const nm = spellName.get(id) || "?";
      const who = [...d.ids.get(id)].slice(0, 2).join(", ");
      L.push(`  [${id}] = true,  -- ${nm}${who ? " -- " + who : ""}`);
    }
  }
  L.push("}");
  L.push("");

  const out = path.join(ROOT, "Data", "DungeonInterruptible.lua");
  fs.writeFileSync(out, L.join("\n"));
  console.error(`[unkicked] wrote ${path.relative(ROOT, out)} `
    + `(${union.size} casts, ${perDungeon.length} dungeons)`);
  if (unresolved.length)
    console.error(`[unkicked] WARNING ${unresolved.length} id(s) have no name in build ${build}: `
      + unresolved.join(", "));

  if (args.includes("--report")) {
    for (const d of perDungeon)
      console.log(`${d.label.padEnd(28)} ${String(d.ids.size).padStart(3)}`);
  }

  // Cross-check the bootstrap against what the logs actually proved. Agreement
  // is evidence for both lists; a proven id MDT lacks is worth looking at.
  if (args.includes("--check")) {
    const learned = path.join(ROOT, "parser", "learned-interruptible.lua");
    const txt = fs.existsSync(learned) ? fs.readFileSync(learned, "utf8") : "";
    const proven = [...txt.matchAll(/\[(\d+)\]\s*=\s*true/g)].map((m) => Number(m[1]));
    const inMdt = proven.filter((id) => union.has(id));
    console.log(`\nproven by our logs: ${proven.length}`);
    console.log(`  also in MDT:      ${inMdt.length}`);
    for (const id of proven.filter((id) => !union.has(id)))
      console.log(`  NOT in MDT:       ${id} ${spellName.get(id) || "?"}`);
  }
}

main().catch((e) => { console.error(`[unkicked] ${e.message}`); process.exit(1); });
