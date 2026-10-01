#!/usr/bin/env node
// Generates Data/CCData.lua -- the set of auras that stop a player from pressing
// their interrupt. Without this, "kick was up and they didn't use it" fires at
// people who were stunned, and the panel becomes a liar (REQUIREMENTS.md R-6).
//
//   node tools/gen-cc-data.mjs [--build 12.1.0.69933] [--report]
//
// Source of truth is SpellCategories.Mechanic, the same field the client uses.

import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { Db2, liveBuild, num } from "./lib/db2.mjs";

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, "..");

// Mechanics that mean "cannot cast an interrupt right now".
// Verified against live 12.1 data: Silence (15487) carries Mechanic 9.
const BLOCKING = {
  1:  "CHARMED",
  2:  "DISORIENTED",
  5:  "FLEEING",
  8:  "PACIFIED",
  9:  "SILENCED",
  10: "ASLEEP",
  12: "STUNNED",
  13: "FROZEN",
  14: "INCAPACITATED",
  17: "POLYMORPHED",
  24: "HORRIFIED",
};
// Deliberately excluded: 3 DISARMED (melee swings only, kicks still work),
// 7 ROOTED and 11 ENSNARED (a root does not stop a cast -- it is a range
// problem, which is a separate column), 18 BANISHED, 21 MOUNTED.

const args = process.argv.slice(2);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };

async function main() {
  const build = opt("--build") || (await liveBuild("wow"));
  const db = new Db2(build, path.join(HERE, ".cache"));
  console.error(`[unkicked] build ${build}`);

  const [categories, names] = await Promise.all([
    db.table("SpellCategories"), db.table("SpellName"),
  ]);
  const nameOf = new Map(names.map((r) => [num(r.ID), r.Name_lang]));

  const byMechanic = new Map(Object.keys(BLOCKING).map((k) => [Number(k), []]));
  for (const r of categories) {
    if (num(r.DifficultyID) !== 0) continue;
    const m = num(r.Mechanic);
    if (!BLOCKING[m]) continue;
    const sp = num(r.SpellID);
    if (!sp || !nameOf.has(sp)) continue;
    byMechanic.get(m).push(sp);
  }

  const total = [...byMechanic.values()].reduce((a, b) => a + b.length, 0);
  const L = [];
  L.push("-- Unkicked :: CCData.lua");
  L.push("-- GENERATED FILE -- do not edit by hand.");
  L.push("--   regenerate: node tools/gen-cc-data.mjs");
  L.push(`-- source: wago.tools DB2 SpellCategories.Mechanic, build ${build}`);
  L.push(`-- ${total} auras across ${byMechanic.size} blocking mechanics`);
  L.push("");
  L.push("local ADDON, ns = ...");
  L.push("");
  L.push(`ns.CC_BUILD = "${build}"`);
  L.push("");
  L.push("-- spellID -> mechanic name. Presence means: a party member carrying this");
  L.push("-- aura could not have pressed their interrupt, so do not count the cast");
  L.push("-- against them. Report it as a separate reason instead.");
  L.push("ns.CC_AURAS = {");
  for (const [m, ids] of [...byMechanic].sort((a, b) => a[0] - b[0])) {
    if (!ids.length) continue;
    L.push(`  -- ${BLOCKING[m]} (mechanic ${m}) -- ${ids.length}`);
    ids.sort((a, b) => a - b);
    for (let i = 0; i < ids.length; i += 10) {
      const chunk = ids.slice(i, i + 10).map((id) => `[${id}]="${BLOCKING[m]}"`);
      L.push(`  ${chunk.join(", ")},`);
    }
  }
  L.push("}");
  L.push("");

  const out = path.join(ROOT, "Data", "CCData.lua");
  fs.writeFileSync(out, L.join("\n"));
  console.error(`[unkicked] wrote ${path.relative(ROOT, out)} (${total} auras)`);

  if (args.includes("--report")) {
    for (const [m, ids] of [...byMechanic].sort((a, b) => a[0] - b[0]))
      console.log(`${String(m).padStart(3)} ${BLOCKING[m].padEnd(15)} ${ids.length}`);
  }
}

main().catch((e) => { console.error(`[unkicked] ${e.message}`); process.exit(1); });
