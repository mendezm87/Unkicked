#!/usr/bin/env node
// Block-balance check for the addon's Lua. This is NOT a parser -- it tokenizes
// past strings, long strings and comments and verifies that every block opener
// has a matching `end`, which catches the scaffolding mistakes. A real parse
// needs an actual Lua binary. The real suite is tests/run.lua (N-5).
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
