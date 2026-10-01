#!/usr/bin/env node
// Syntax check for the addon's Lua, in TOC load order.
//
// When a Lua binary is available it compiles each file for real, which is the only
// trustworthy answer. Otherwise it falls back to a block-balance tokenizer -- useful
// for catching scaffolding mistakes, but it reports false positives on code the
// real compiler accepts (it mis-reads `function` as a block opener in expression
// position, among others), so the fallback is advisory only.
//
// The behavioural suite is tests/run.lua (N-5).
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const ROOT = path.join(path.dirname(url.fileURLToPath(import.meta.url)), "..");
const files = fs.readFileSync(path.join(ROOT, "Unkicked.toc"), "utf8")
  .split("\n").map((l) => l.trim())
  .filter((l) => l.endsWith(".lua"))
  .map((l) => l.replace(/\\/g, "/"));

const OPEN = /^(function|if|for|while|do)$/;
let bad = 0;

// Prefer a real compile. luajit first: WoW runs Lua 5.1.
function findLua() {
  for (const bin of ["luajit", "lua5.1", "lua"]) {
    try {
      execFileSync(bin, ["-v"], { stdio: "ignore" });
      return bin;
    } catch {}
  }
  return null;
}
const lua = findLua();
if (lua) {
  for (const rel of files) {
    const file = path.join(ROOT, rel);
    if (!fs.existsSync(file)) { console.error(`MISSING ${rel}`); bad++; continue; }
    try {
      execFileSync(lua, ["-e", `assert(loadfile(${JSON.stringify(file)}))`], { stdio: "pipe" });
      console.log(`ok  ${rel}`);
    } catch (e) {
      console.error(`${rel}: ${String(e.stderr || e.message).trim()}`);
      bad++;
    }
  }
  console.log(bad === 0
    ? `\n${files.length} files compile under ${lua}`
    : `\n${bad} file(s) failed to compile`);
  process.exit(bad === 0 ? 0 : 1);
}

console.error("no lua binary found -- falling back to the advisory block check\n");

for (const rel of files) {
  const file = path.join(ROOT, rel);
  if (!fs.existsSync(file)) { console.error(`MISSING ${rel}`); bad++; continue; }
  const src = fs.readFileSync(file, "utf8");

  // strip long comments/strings, line comments, then quoted strings
  let s = src.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, " ")
             .replace(/\[(=*)\[[\s\S]*?\]\1\]/g, '""')
             .replace(/--[^\n]*/g, " ")
             .replace(/"(\\.|[^"\\])*"/g, '""')
             .replace(/'(\\.|[^'\\])*'/g, "''");

  const stack = [];
  const lines = s.split("\n");
  lines.forEach((line, i) => {
    // `a = b` style: `repeat`..`until` is the only block not closed by `end`
    for (const m of line.matchAll(/\b([A-Za-z_]+)\b/g)) {
      const w = m[1];
      if (w === "then" || w === "elseif") continue;
      if (w === "repeat") { stack.push({ w, line: i + 1, until: true }); continue; }
      if (w === "until") {
        const top = stack.pop();
        if (!top || !top.until) { console.error(`${rel}:${i + 1} stray 'until'`); bad++; }
        continue;
      }
      if (OPEN.test(w)) {
        // `for ... do` / `while ... do` would double-count; the `do` of a numeric
        // for is on the same logical construct, so swallow it.
        if (w === "do" && stack.length && /^(for|while)$/.test(stack[stack.length - 1].w)
            && stack[stack.length - 1].line === i + 1) continue;
        stack.push({ w, line: i + 1 });
      } else if (w === "end") {
        const top = stack.pop();
        if (!top) { console.error(`${rel}:${i + 1} 'end' with nothing open`); bad++; }
      }
    }
  });

  if (stack.length) {
    bad++;
    console.error(`${rel}: ${stack.length} unclosed block(s): ` +
      stack.map((f) => `${f.w}@${f.line}`).join(", "));
  } else {
    console.log(`ok  ${rel}`);
  }
}

// cross-file: every ns.* the addon reads should be defined somewhere
process.exit(bad ? 1 : 0);
