#!/usr/bin/env node
// Rewrite one row's description via the agent, honoring a saved hint.
// Usage: node rewrite.mjs --root R --cache C --overrides O --rel REL --hint HINT
// Agent: TREE_AGENT_BIN (default "opencode") + TREE_AGENT_ARGS (default "run"),
// invoked as [bin, ...args, prompt]. Exit 0 on success, 2 when the agent fails
// (the previous description is restored). Writes a "… rewriting …" marker row
// first so the yazi linemode shows work in progress; the probe treats marker
// rows as stale (see probe.mjs Phase 3). Image files (png/gif/…) are attached
// to the agent message with opencode run's --file flag and described from
// what the image shows instead of a text excerpt.
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const MAX_CHARS = 160;
const MAX_HYPER_WORDS = 4;
const MAX_LONG_CHARS = 200;
const MARKER = "… rewriting description …";

function arg(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function clean(s) {
  return s.replace(/[\t\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}
// opencode run prints advisory lines like "⚠ OpenCode MCP server(s) …" on
// stdout before the answer; the description must come from the answer only.
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
const REL = arg("--rel");
const HINT = arg("--hint") || "";
if (!ROOT || !CACHE || !OVERRIDES || !REL) {
  console.error("rewrite: --root, --cache, --overrides and --rel are required");
  process.exit(2);
}

function changeKey(abs, isDir) {
  let own;
  try {
    own = String(Math.floor(statSync(abs).mtimeMs / 1000));
  } catch {
    return null;
  }
  if (!isDir) return own;
  let kids = [];
  try {
    kids = readdirSync(abs).sort().filter((n) => n !== "node_modules");
  } catch {
    kids = [];
  }
  const parts = [own];
  for (const k of kids) {
    try {
      parts.push(`${k}=${Math.floor(statSync(join(abs, k)).mtimeMs / 1000)}`);
    } catch {
      parts.push(`${k}=?`);
    }
  }
  return parts.join("|");
}

function loadCache() {
  const rows = [];
  if (existsSync(CACHE)) {
    for (const line of readFileSync(CACHE, "utf8").split("\n")) {
      if (!line) continue;
      const [rel, mtime, ...rest] = line.split("\t");
      if (rel) {
        // v2: rel, key, hyper, long. Legacy v1 rows (one desc column) keep
        // hyper = desc and empty long so readers fall back to hyper.
        rows.push([rel, mtime, rest[0] ?? "", rest[1] ?? rest[0] ?? ""]);
      }
    }
  }
  return rows;
}
function writeCache(rows) {
  rows.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  writeFileSync(CACHE, rows.map((r) => r.join("\t")).join("\n") + "\n");
}
function setRow(rows, rel, mtime, hyper, long) {
  const rest = rows.filter((r) => r[0] !== rel);
  rest.push([rel, mtime, hyper, long ?? hyper ?? ""]);
  return rest;
}

function excerpt(abs, isDir) {
  try {
    if (isDir) {
      const kids = readdirSync(abs).sort().filter((n) => n !== "node_modules").slice(0, 30);
      return "contains: " + (kids.join(", ") || "(empty)");
    }
    return readFileSync(abs, "utf8").slice(0, 2000) || "(empty file)";
  } catch {
    return "(unreadable)";
  }
}

// Absolute rels (desc-row outside-tree rows) are used verbatim.
const abs = REL.startsWith("/") ? REL : join(ROOT, REL);
let isDir = false;
try {
  isDir = statSync(abs).isDirectory();
} catch {
  console.error(`rewrite: ${REL} not found under root`);
  process.exit(2);
}
const key = changeKey(abs, isDir);
if (key === null) {
  console.error(`rewrite: cannot stat ${REL}`);
  process.exit(2);
}

let rows = loadCache();
const prev = rows.find((r) => r[0] === REL);
const prevHyper = prev ? prev[2] : null;
const prevLong = prev ? prev[3] : prevHyper;

// Pending marker first so the row shows work in progress.
writeCache(setRow(rows, REL, key, MARKER, ""));

// Binary images are described from the image itself, not a text excerpt:
// opencode run's --file flag attaches the file (verified against png and
// gif on this install). Text/binary-no-image files keep the excerpt path.
const IMAGE_EXTS = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "bmp", "avif",
  "ico", "icns", "tiff", "tif", "heic", "heif",
]);
const isImage = IMAGE_EXTS.has((abs.match(/\.([A-Za-z0-9]+)$/)?.[1] ?? "").toLowerCase());
const context = isImage
  ? "The file itself was attached to this message as an image; describe only what is visible in it."
  : excerpt(abs, isDir);

const prompt = `Describe "${REL}" for a file browser in exactly two lines.\nLine 1: hyper summary — 2-4 words, a phrase, not a sentence, capturing who/what/where/when/why/how.\nLine 2: one complete, plain high-school-level sentence with a little more detail.\nUser hint: ${HINT || "(none)"}. Context:\n${context}`;

const bin = process.env.TREE_AGENT_BIN || "opencode";
const args = (process.env.TREE_AGENT_ARGS ?? "run").split(/\s+/).filter(Boolean);
let raw;
try {
  const agentArgs = [...args, ...(isImage ? ["--file", abs] : []), prompt];
  raw = execFileSync(bin, agentArgs, { encoding: "utf8", timeout: 120000, stdio: ["ignore", "pipe", "pipe"] });
} catch (e) {
  // Failure: restore the previous description (or drop the marker row).
  rows = loadCache().filter((r) => r[0] !== REL);
  if (prevHyper) rows.push([REL, key, prevHyper, prevLong ?? prevHyper]);
  writeCache(rows);
  console.error(`rewrite: agent failed for ${REL}: ${e.message}`);
  process.exit(2);
}

// Two-tier parse: the agent may narrate before answering and may even
// answer more than once; the FINAL two clean lines are the answer (last
// wins), so opener chatter can't win and multiple answers take the agent's
// own last version.
const textLines = dropWarnings(raw).split("\n").map((l) => clean(l)).filter(Boolean);
const n = textLines.length;
const hyper = (n >= 2 ? clipWords(textLines[n - 2], MAX_HYPER_WORDS) : n === 1 ? clipWords(textLines[0], MAX_HYPER_WORDS) : "")
	.slice(0, MAX_CHARS);
const long = (n >= 2 ? textLines[n - 1] : "").slice(0, MAX_LONG_CHARS);
// No parsable pair counts as agent failure: restore the previous
// description (or drop the marker row) instead of leaving the marker
// stuck in the cache forever.
if (!hyper && !long) {
	rows = loadCache().filter((r) => r[0] !== REL);
	if ((prevHyper && prevHyper !== MARKER) || prevLong) {
		rows.push([REL, key, prevHyper || prevLong, prevLong || prevHyper || ""]);
	}
	writeCache(rows);
	console.error(`rewrite: agent gave no parsable answer for ${REL}; previous restored`);
	process.exit(2);
}
const desc = hyper || prevHyper || MARKER;
const showLong = long || (n >= 2 ? "" : hyper || prevLong || "");
writeCache(setRow(loadCache(), REL, key, desc, showLong));

// Save the hint so future rescans re-apply it (kind=hint rows) — but only
// when a hint was actually given; a generic pass must not pin the row.
if (clean(HINT)) {
  let ovr = [];
  if (existsSync(OVERRIDES)) {
    ovr = readFileSync(OVERRIDES, "utf8").split("\n").filter((l) => l && l.split("\t")[0] !== REL);
  }
  ovr.push(`${REL}\thint\t${clean(HINT)}`);
  ovr.sort();
  writeFileSync(OVERRIDES, ovr.join("\n") + "\n");
}
console.log(`rewrite: ${REL} <- ${desc} | ${showLong}`);
