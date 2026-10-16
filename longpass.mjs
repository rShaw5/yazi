#!/usr/bin/env node
// Batch "long pass": fill real hyper + one-sentence longs for cache rows
// that still carry the legacy hyper-only fallback (long == hyper or empty).
// One agent call per batch of rows. NEVER run by the agent on the real
// tree — the user launches it herself.
// Usage: node longpass.mjs --root R --cache C --overrides O [--batch 8]
// Agent: TREE_AGENT_BIN (default "opencode") + TREE_AGENT_ARGS (default "run").
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const MAX_HYPER_WORDS = 4;
const MAX_CHARS = 160;
const MAX_LONG_CHARS = 200;
const SKIP_ANY = new Set([".git", "node_modules", ".DS_Store"]);

function arg(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function clean(s) {
  return s.replace(/[\t\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}
function dropWarnings(s) {
  return s.split("\n").filter((l) => !/^\s*⚠/.test(l) && !/OpenCode MCP/.test(l)).join("\n");
}
function clipWords(s, n) {
  const w = s.split(/\s+/).filter(Boolean);
  return w.length > n ? w.slice(0, n).join(" ") : w.join(" ");
}

const ROOT = arg("--root");
const CACHE = arg("--cache");
const OVERRIDES = arg("--overrides");
const BATCH = Math.max(1, parseInt(arg("--batch") || "8", 10) || 8);
if (!ROOT || !CACHE || !OVERRIDES) {
  console.error("longpass: --root, --cache and --overrides are required");
  process.exit(2);
}

// Verbatim rows are frozen; skip them always.
const verbatim = new Set();
if (existsSync(OVERRIDES)) {
  for (const line of readFileSync(OVERRIDES, "utf8").split("\n")) {
    if (!line) continue;
    const parts = line.split("\t");
    if (parts[1] === "verbatim") verbatim.add(parts[0]);
    else if (parts.length === 2) verbatim.add(parts[0]);
  }
}

const rows = [];
if (existsSync(CACHE)) {
  for (const line of readFileSync(CACHE, "utf8").split("\n")) {
    if (!line) continue;
    const [rel, key, hyper, long] = line.split("\t");
    rows.push({ rel, key, hyper: hyper ?? "", long: long === undefined ? hyper ?? "" : long });
  }
}

// Candidates: inside the tree, not frozen, no real long yet.
const candidates = rows.filter(
  (r) => r.hyper && r.long === r.hyper && !verbatim.has(r.rel) && !SKIP_ANY.has(r.rel),
);

function excerpt(abs) {
  try {
    const st = statSync(abs);
    if (st.isDirectory()) {
      const kids = readdirSync(abs).sort().filter((n) => !SKIP_ANY.has(n)).slice(0, 30);
      return "contains: " + (kids.join(", ") || "(empty)");
    }
    return readFileSync(abs, "utf8").slice(0, 2000) || "(empty file)";
  } catch {
    return "(unreadable)";
  }
}

let updated = 0;
for (let start = 0; start < candidates.length; start += BATCH) {
  const batch = candidates.slice(start, start + BATCH);
  const listing = batch
    .map((r, i) => {
      const abs = join(ROOT, r.rel);
      let isDir = false;
      try { isDir = statSync(abs).isDirectory(); } catch {}
      return `${i + 1}. ${r.rel} (${isDir ? "folder" : "file"}): ${excerpt(abs)}`;
    })
    .join("\n");
  const prompt = `For each numbered file below, write a file-browser description in exactly three tab-separated fields: number, hyper summary, full sentence.\nHyper: 2-4 words, a phrase, not a sentence, capturing who/what/where/when/why/how.\nSentence: one complete, plain high-school-level sentence with a little more detail.\nKeep the numbering, one line per file, no other text.\n\n${listing}`;

  const bin = process.env.TREE_AGENT_BIN || "opencode";
  const args = (process.env.TREE_AGENT_ARGS ?? "run").split(/\s+/).filter(Boolean);
  let raw = "";
  try {
    raw = execFileSync(bin, [...args, prompt], { encoding: "utf8", timeout: 180000, stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    console.error(`longpass: agent failed on batch ${start / BATCH + 1}: ${e.message}`);
    continue;
  }
  const parsed = new Map();
  for (const line of dropWarnings(raw).split("\n")) {
    const m = line.match(/^\s*(\d+)\s*\t(.*)$/);
    if (!m) continue;
    const idx = parseInt(m[1], 10);
    if (idx < 1 || idx > batch.length) continue;
    const [hyper, long] = m[2].split("\t");
    if (clean(hyper) && clean(long)) parsed.set(idx, { hyper: clipWords(clean(hyper), MAX_HYPER_WORDS).slice(0, MAX_CHARS), long: clean(long).slice(0, MAX_LONG_CHARS) });
  }
  if (parsed.size === 0) continue;
  const byIndex = new Map(batch.map((r, i) => [i + 1, r]));
  for (const [idx, val] of parsed) {
    const row = byIndex.get(idx);
    if (!row) continue;
    row.hyper = val.hyper;
    row.long = val.long;
    row.touched = true;
    updated++;
  }
  writeFileSync(CACHE, rows.map((r) => [r.rel, r.key, r.hyper, r.long].join("\t")).join("\n") + "\n");
}

console.log(`longpass: ${candidates.length} candidates, updated=${updated}`);
