#!/usr/bin/env node
// Phase 3 MVP probe: deterministic stub descriptions for top 2 levels of planning-system.
// Zero dependencies. No network. Writes desc-cache.tsv: `relpath \t mtime(sec) \t description`.
// Second run skips unchanged entries (mtime match) and prints generated/skipped counts.
import { readdirSync, readFileSync, statSync, writeFileSync, existsSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = process.env.TREE_ROOT || "/Users/robinshaw/Code/planning-system";
const CACHE = process.env.TREE_CACHE || join(HERE, "desc-cache.tsv");
const SKIP_TOP = new Set([".git"]);
const SKIP_ANY = new Set(["node_modules"]);
const OVERRIDES = process.env.TREE_OVERRIDES || join(HERE, "overrides.tsv");
const MAX_CHARS = 160;
const MAX_WORDS = 10;
const MAX_HYPER_WORDS = 4;
const ROW_NOTE = "voice: /tree skill — short purpose phrases, never inventories";
// Must match rewrite.mjs: rows carrying the marker are always stale.
const MARKER = "… rewriting description …";

function humanSize(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}
function extLabel(rel) {
  const m = rel.match(/\.([A-Za-z0-9]{1,5})$/);
  return m ? m[1].toUpperCase() : "file";
}

const t0 = Date.now();

function clean(s) {
  return s.replace(/[\t\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}
// One plain sentence: the stub text capped with a period if it lacks one.
function asSentence(s) {
  s = clean(s);
  return /[.!?]$/.test(s) ? s : s + ".";
}
function clipWords(s, n) {
  const w = s.split(/\s+/).filter(Boolean);
  return w.length > n ? w.slice(0, n).join(" ") : w.join(" ");
}
function stubForFile(abs, rel) {
  let raw = "";
  try {
    raw = readFileSync(abs, "utf8").slice(0, 65536);
  } catch {
    return `file: ${rel} (unreadable)`;
  }
  if (!raw.trim()) return "empty file";
  // Treat as text only if mostly printable; otherwise type + size, like /tree.
  const sample = raw.slice(0, 2000);
  const nonPrint = (sample.match(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g) || []).length;
  if (nonPrint > sample.length * 0.05) {
    let size = 0;
    try { size = statSync(abs).size; } catch {}
    return `${extLabel(rel)}, ${humanSize(size)}`;
  }
  const lines = raw.split(/\r?\n/);
  const isMd = /\.md$/i.test(rel);
  if (isMd) {
    for (const ln of lines) {
      const m = ln.match(/^#{1,6}\s+(.*\S)\s*$/);
      if (m) return clipWords(clean(m[1]), MAX_WORDS).slice(0, MAX_CHARS) || "notes file";
    }
  }
  const typeLabel = { json: "JSON data", sh: "shell script", mjs: "JavaScript file", js: "JavaScript file", tsv: "data file", csv: "data file", html: "HTML page" };
  const ext = (rel.match(/\.([A-Za-z0-9]{1,5})$/) || [])[1] || "";
  const fallback = typeLabel[ext.toLowerCase()] || `${extLabel(rel)} file`;
  for (const ln of lines) {
    // Prefer human comment lines (//, #) with the marker stripped — but never a shebang.
    const c = clean(ln).match(/^(?:\/\/|#(?!!))\s?(.*\S)\s*$/);
    if (c) return clipWords(c[1], MAX_WORDS).slice(0, MAX_CHARS);
  }
  for (const ln of lines) {
    const t = clean(ln);
    // Skip code-shaped lines (braces, brackets, quotes, shebangs, tags) — never recite code.
    if (t && !/^[{}\[\]<"#!]/.test(t)) return clipWords(t, MAX_WORDS).slice(0, MAX_CHARS);
  }
  return fallback;
}
function firstHeading(abs) {
  let raw = "";
  try {
    raw = readFileSync(abs, "utf8").slice(0, 32768);
  } catch {
    return null;
  }
  for (const ln of raw.split(/\r?\n/)) {
    const m = ln.match(/^#{1,6}\s+(.*\S)\s*$/);
    if (m) return clipWords(clean(m[1]), MAX_WORDS);
  }
  return null;
}
function stubForDir(abs, rel) {
  let names;
  try {
    names = readdirSync(abs).sort();
  } catch {
    return "unreadable folder";
  }
  // Prefer a human purpose line: README / index / first doc inside, like /tree.
  const docFirst = ["README.md", "README", "index.md"].map((n) => join(abs, n));
  for (const d of docFirst) {
    const h = firstHeading(d);
    if (h) return h.slice(0, MAX_CHARS);
  }
  for (const n of names) {
    if (/\.md$/i.test(n)) {
      const h = firstHeading(join(abs, n));
      if (h) return h.slice(0, MAX_CHARS);
    }
  }
  if (names.length === 0) return "empty folder";
  return "folder, no overview yet";
}

// Collect top-2-level entries (depth 1 + depth 2), sorted; skip .git and node_modules anywhere.
const top1 = readdirSync(ROOT).sort().filter((n) => !SKIP_TOP.has(n) && !SKIP_ANY.has(n));
const entries = [];
for (const name of top1) {
  const abs = join(ROOT, name);
  let st;
  try { st = statSync(abs); } catch { continue; }
  entries.push({ rel: name, abs, isDir: st.isDirectory() });
    if (st.isDirectory()) {
      let kids = [];
      try { kids = readdirSync(abs).sort().filter((n) => !SKIP_ANY.has(n)); } catch { kids = []; }
    for (const k of kids) {
      const kabs = join(abs, k);
      let kst;
      try { kst = statSync(kabs); } catch { continue; }
      // Depth 2: record files and dirs, do not recurse further.
      entries.push({ rel: `${name}/${k}`, abs: kabs, isDir: kst.isDirectory() });
    }
  }
}

// Curated overrides: `rel \t kind \t text` where kind is verbatim or hint.
// Legacy two-field rows (`rel \t text`) count as verbatim — frozen wording.
// verbatim: text is the description, stored whole (no word clip), never rewritten.
// hint: text is the agent prompt; the description itself is agent-managed
// (Phase 2); the probe keeps a fresh cache entry and stubs only when missing.
const overrides = new Map();
if (existsSync(OVERRIDES)) {
  for (const line of readFileSync(OVERRIDES, "utf8").split("\n")) {
    if (!line) continue;
    const parts = line.split("\t");
    if (parts.length >= 3) overrides.set(parts[0], { kind: parts[1], text: parts.slice(2).join("\t") });
    else if (parts.length === 2) overrides.set(parts[0], { kind: "verbatim", text: parts[1] });
  }
}

// Change key: files use their mtime; dirs use own mtime plus every child's,
// so a folder recomputes whenever its contents change.
function changeKey(e) {
  let own;
  try { own = String(Math.floor(statSync(e.abs).mtimeMs / 1000)); }
  catch { return null; }
  if (!e.isDir) return own;
  let kids = [];
  try { kids = readdirSync(e.abs).sort().filter((n) => !SKIP_ANY.has(n)); } catch { kids = []; }
  const parts = [own];
  for (const k of kids) {
    try { parts.push(`${k}=${Math.floor(statSync(join(e.abs, k)).mtimeMs / 1000)}`); }
    catch { parts.push(`${k}=?`); }
  }
  return parts.join("|");
}
const old = new Map();
if (existsSync(CACHE)) {
  for (const line of readFileSync(CACHE, "utf8").split("\n")) {
    if (!line) continue;
    // v2: rel, key, hyper, long; legacy v1 rows fall back hyper = desc.
    const [rel, mtime, ...rest] = line.split("\t");
    if (rel) old.set(rel, { mtime, hyper: rest[0] ?? "", long: rest[1] ?? rest[0] ?? "" });
  }
}

let generated = 0, skipped = 0;
const rows = [];
const staleHints = [];
for (const e of entries) {
  const key = changeKey(e);
  if (key === null) continue;
  const prev = old.get(e.rel);
  const ov = overrides.get(e.rel);
  const verbatimText = ov && ov.kind === "verbatim" ? clean(ov.text) : null;
  // A fresh entry is reusable only when no verbatim text disagrees with it —
  // an edited override must regenerate even when the file itself is untouched.
  // Marker rows (interrupted agent runs) are never fresh.
  if (
    prev && prev.mtime === key && prev.hyper &&
    !prev.hyper.startsWith(MARKER) &&
    prev.hyper === (verbatimText ?? prev.hyper)
  ) {
    skipped++;
    rows.push([e.rel, key, prev.hyper, prev.long]);
    continue;
  }
  generated++;
  if (verbatimText !== null) {
    rows.push([e.rel, key, verbatimText, ""]);
    continue;
  }
  if (ov && ov.kind === "hint" && clean(ov.text)) {
    // Stale hint row: queue an agent rewrite below; stub meanwhile so a
    // failed agent still leaves a usable description, never a crash.
    staleHints.push({ rel: e.rel, hint: clean(ov.text) });
  }
  const desc = clean(e.isDir ? stubForDir(e.abs, e.rel) : stubForFile(e.abs, e.rel)).slice(0, MAX_CHARS);
  rows.push([e.rel, key, clipWords(desc, MAX_HYPER_WORDS), asSentence(desc)]);
}
// Phase 3: re-prompt the agent for stale hint rows. rewrite.mjs updates the
// cache file directly; re-read its rows back into this run's table.
for (const h of staleHints) {
  try {
    execFileSync("node", [
      join(HERE, "rewrite.mjs"),
      "--root", ROOT, "--cache", CACHE, "--overrides", OVERRIDES,
      "--rel", h.rel, "--hint", h.hint,
    ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch {
    // Agent failed — rewrite.mjs already restored the old text or dropped
    // its marker; the stub above stands in.
  }
}
if (staleHints.length > 0 && existsSync(CACHE)) {
  const written = new Map();
  for (const line of readFileSync(CACHE, "utf8").split("\n")) {
    if (!line) continue;
    const [rel, mtime, ...rest] = line.split("\t");
    if (rel) written.set(rel, [rel, mtime, rest[0] ?? "", rest[1] ?? rest[0] ?? ""]);
  }
  const wanted = new Set(staleHints.map((h) => h.rel));
  for (let i = 0; i < rows.length; i++) {
    if (wanted.has(rows[i][0])) {
      const w = written.get(rows[i][0]);
      if (w && !w[2].startsWith(MARKER)) rows[i] = w;
    }
  }
}
// Preserve rows the probe does not cover (outside-tree rows managed by
// desc-row): the probe merges, it never wipes them.
const covered = new Set(rows.map((r) => r[0]));
for (const [rel, ent] of old) {
  if (!covered.has(rel) && rel !== "." && !ent.hyper.startsWith(MARKER)) {
    rows.push([rel, ent.mtime, ent.hyper, ent.long]);
  }
}
rows.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
writeFileSync(CACHE, rows.map((r) => r.join("\t")).join("\n") + "\n");
const ms = Date.now() - t0;
console.log(`probe: total=${rows.length} generated=${generated} skipped=${skipped} time=${ms}ms cache=${relative(HERE, CACHE)}`);
