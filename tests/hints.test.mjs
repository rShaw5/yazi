import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const PROBE = new URL("../probe.mjs", import.meta.url).pathname;

function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), "hintroot-"));
  writeFileSync(join(root, "notes.md"), "# Hello\nsome body text\n");
  writeFileSync(join(root, "plain.md"), "# Plain\njust a file\n");
  const home = mkdtempSync(join(tmpdir(), "hinthome-"));
  const fx = {
    root,
    cache: join(home, "desc-cache.tsv"),
    overrides: join(home, "overrides.tsv"),
    agent: join(home, "mock-agent.sh"),
  };
  writeFileSync(fx.agent, `#!/bin/sh\nprintf 'hint based fresh words'\n`);
  chmodSync(fx.agent, 0o755);
  return fx;
}

function env(fx, extra = {}) {
  return {
    ...process.env,
    TREE_ROOT: fx.root,
    TREE_CACHE: fx.cache,
    TREE_OVERRIDES: fx.overrides,
    TREE_AGENT_BIN: fx.agent,
    TREE_AGENT_ARGS: "",
    ...extra,
  };
}

test("stale hint rows are rewritten by the agent on rescan", () => {
  const fx = makeFixture();
  writeFileSync(fx.overrides, "notes.md\thint\tmention the greeting\n");
  execFileSync("node", [PROBE], { env: env(fx) });
  const cache = readFileSync(fx.cache, "utf8");
  assert.match(cache, /^notes\.md\t.*hint based fresh words$/m);
});

test("rescan leaves verbatim rows alone and skips fresh hint rows", () => {
  const fx = makeFixture();
  writeFileSync(fx.overrides, "notes.md\tverbatim\tFrozen words\nplain.md\thint\tmention plain\n");
  execFileSync("node", [PROBE], { env: env(fx) });
  const first = readFileSync(fx.cache, "utf8");
  assert.match(first, /Frozen words/);
  const out = execFileSync("node", [PROBE], { env: env(fx) }).toString();
  assert.equal(readFileSync(fx.cache, "utf8"), first);
  assert.match(out, /generated=0/);
});

test("agent failure on rescan falls back to a stub, not a crash", () => {
  const fx = makeFixture();
  writeFileSync(fx.overrides, "notes.md\thint\tmention the greeting\n");
  const out = execFileSync("node", [PROBE], { env: env(fx, { TREE_AGENT_BIN: "false" }) }).toString();
  assert.match(out, /probe: total=/);
  const cache = readFileSync(fx.cache, "utf8");
  assert.match(cache, /^notes\.md\t/m);
  assert.doesNotMatch(cache, /rewriting/);
});
