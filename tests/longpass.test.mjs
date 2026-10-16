import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const LONGPASS = new URL("../longpass.mjs", import.meta.url).pathname;

function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), "lproot-"));
  writeFileSync(join(root, "notes.md"), "# Hello\nsome body text\n");
  writeFileSync(join(root, "data.tsv"), "a\tb\n1\t2\n");
  writeFileSync(join(root, "frozen.md"), "# Frozen\nwords\n");
  const home = mkdtempSync(join(tmpdir(), "lphome-"));
  const fx = {
    root,
    cache: join(home, "desc-cache.tsv"),
    overrides: join(home, "overrides.tsv"),
    agent: join(home, "mock-agent.sh"),
  };
  // v2 rows; notes.md and data.tsv have hyper-only longs (legacy fallback),
  // frozen.md is verbatim-pinned in legacy fallback shape (long == hyper, the
  // exact shape longpass exists to fill) and must never be touched.
  writeFileSync(
    fx.cache,
    [
      "frozen.md\t1\tdo not touch\tdo not touch",
      "notes.md\t1\tgreeting notes\tgreeting notes",
      "data.tsv\t1\tsized data\tsized data",
    ].join("\n") + "\n",
  );
  writeFileSync(fx.overrides, "frozen.md\tverbatim\texact words only\n");
  return fx;
}

function mockAgent(fx, body) {
  writeFileSync(fx.agent, `#!/bin/sh\n${body}\n`);
  chmodSync(fx.agent, 0o755);
}

function run(fx, extraEnv = {}) {
  return execFileSync("node", [LONGPASS, "--root", fx.root, "--cache", fx.cache, "--overrides", fx.overrides], {
    env: { ...process.env, TREE_AGENT_BIN: fx.agent, TREE_AGENT_ARGS: "", ...extraEnv },
  }).toString();
}

function rows(fx) {
  const m = new Map();
  for (const l of readFileSync(fx.cache, "utf8").split("\n")) {
    if (l) {
      const [rel, key, hyper, long] = l.split("\t");
      m.set(rel, { key, hyper, long });
    }
  }
  return m;
}

test("batch pass fills hyper and sentence for legacy rows", () => {
  const fx = makeFixture();
  mockAgent(fx, `printf '1\\tgreeting notes\\tA short markdown note greets readers.\\n2\\tsized data\\tA small two-column data table.'`);
  const out = run(fx);
  const r = rows(fx);
  assert.equal(r.get("notes.md").hyper, "greeting notes");
  assert.equal(r.get("notes.md").long, "A short markdown note greets readers.");
  assert.equal(r.get("data.tsv").hyper, "sized data");
  assert.equal(r.get("data.tsv").long, "A small two-column data table.");
  assert.match(out, /updated=2/);
});

test("verbatim rows are never touched by the batch pass", () => {
  const fx = makeFixture();
  mockAgent(fx, `printf '1\\tgreeting notes\\tA short markdown note greets readers.\\n2\\tsized data\\tA small two-column data table.\\n3\\tEVILOUTPUT\\tEVIL SENTENCE'`);
  run(fx);
  const r = rows(fx);
  assert.equal(r.get("frozen.md").hyper, "do not touch");
  assert.doesNotMatch(readFileSync(fx.cache, "utf8"), /EVIL/);
});

test("agent output rows that fail to parse leave rows untouched", () => {
  const fx = makeFixture();
  mockAgent(fx, `printf 'nonsense without tabs\\nanother garbage line'`);
  const out = run(fx);
  const r = rows(fx);
  assert.equal(r.get("notes.md").long, "greeting notes", "untouched legacy long stays");
  assert.match(out, /updated=0/);
});
