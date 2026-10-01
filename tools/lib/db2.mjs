// Minimal wago.tools DB2 CSV client with on-disk caching, pinned to a build.
import fs from "node:fs";
import path from "node:path";

const BASE = "https://wago.tools";

export async function liveBuild(product = "wow") {
  const res = await fetch(`${BASE}/api/builds`);
  if (!res.ok) throw new Error(`builds: HTTP ${res.status}`);
  const json = await res.json();
  const list = json[product];
  if (!list || !list.length) throw new Error(`no builds for product ${product}`);
  return list[0].version;
}

export function parseCsv(text) {
  const rows = [];
  let row = [], cur = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { cur += '"'; i++; } else q = false; }
      else cur += c;
    } else if (c === '"') q = true;
    else if (c === ",") { row.push(cur); cur = ""; }
    else if (c === "\n") { row.push(cur); cur = ""; rows.push(row); row = []; }
    else if (c !== "\r") cur += c;
  }
  if (cur !== "" || row.length) { row.push(cur); rows.push(row); }
  const head = rows.shift();
  return rows
    .filter((r) => r.length >= head.length - 1)
    .map((r) => { const o = {}; head.forEach((k, j) => (o[k] = r[j])); return o; });
}

export class Db2 {
  constructor(build, cacheDir) {
    this.build = build;
    this.cacheDir = path.join(cacheDir, build);
    fs.mkdirSync(this.cacheDir, { recursive: true });
    this.loaded = new Map();
  }

  async raw(table) {
    const file = path.join(this.cacheDir, `${table}.csv`);
    if (!fs.existsSync(file)) {
      const url = `${BASE}/db2/${table}/csv?build=${this.build}`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(`${table}: HTTP ${res.status} (${url})`);
      fs.writeFileSync(file, await res.text());
    }
    return fs.readFileSync(file, "utf8");
  }

  async table(name) {
    if (!this.loaded.has(name)) this.loaded.set(name, parseCsv(await this.raw(name)));
    return this.loaded.get(name);
  }
}

export const num = (v) => (v === undefined || v === "" ? 0 : Number(v));
