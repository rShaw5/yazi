import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const PROBE = new URL("../probe.mjs", import.meta.url).pathname;

function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), "treeroot-"));
  writeFileSync(join(root, "notes.md"), "# Hello\nsome body text\n");
  const home = mkdtempSync(join(tmpdir(), "treehome-"));
  return {
    root,
    cache: join(home, "desc-cache.tsv"),
    overrides: join(home, "overrides.tsv"),
  };
}

function run(fx) {
  return execFileSync("node", [PROBE], {
    env: {
      ...process.env,
      TREE_ROOT: fx.root,
      TREE_CACHE: fx.cache,
      TREE_OVERRIDES: fx.overrides,
    },
  }).toString();
}

function cacheOf(fx) {
  return readFileSync(fx.cache, "utf8");
}

test("probe honors TREE_ROOT/CACHE/OVERRIDES env", () => {
  const fx = makeFixture();
  writeFileSync(fx.overrides, "");
  run(fx);
  assert.match(cacheOf(fx), /^notes\.md\t/m);
});

test("verbatim rows keep exact text across probe runs", () => {
  const fx = makeFixture();
  writeFileSync(fx.overrides, "notes.md\tverbatim\tMy exact words here\n");
  run(fx);
  const first = cacheOf(fx);
  assert.match(first, /My exact words here/);
  const secondRun = run(fx);
  assert.equal(cacheOf(fx), first);
  assert.match(secondRun, /generated=0/);
});

test("edited verbatim text regenerates without touching the file", () => {
  const fx = makeFixture();
  writeFileSync(fx.overrides, "notes.md\tverbatim\tFirst words\n");
  run(fx);
  assert.match(cacheOf(fx), /First words/);
  writeFileSync(fx.overrides, "notes.md\tverbatim\tSecond words\n");
  const out = run(fx);
  assert.match(cacheOf(fx), /Second words/);
  assert.match(out, /generated=1/);
});

test("two-field legacy override rows still pin wording", () => {
  const fx = makeFixture();
  writeFileSync(fx.overrides, "notes.md\tLegacy pinned words\n");
  run(fx);
  assert.match(cacheOf(fx), /Legacy pinned words/);
});
