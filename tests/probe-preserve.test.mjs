import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const PROBE = new URL("../probe.mjs", import.meta.url).pathname;

test("probe preserves rows outside its tree instead of wiping them", () => {
  const root = mkdtempSync(join(tmpdir(), "prroot-"));
  writeFileSync(join(root, "inside.md"), "# Inside doc\nbody\n");
  const home = mkdtempSync(join(tmpdir(), "prhome-"));
  const cache = join(home, "desc-cache.tsv");
  const overrides = join(home, "overrides.tsv");
  // "outside/thing.md" is not under TREE_ROOT; the probe must keep it.
  writeFileSync(
    cache,
    ["inside.md\t1\tinside doc\tThe inside doc.\noutside/thing.md\t1\tparked thing\tA parked thing."].join("\n") + "\n",
  );
  writeFileSync(overrides, "");
  // probe.mjs reads TREE_ROOT/TREE_CACHE/TREE_OVERRIDES from the env —
  // it has no --root/--cache/--overrides args.
  execFileSync("node", [PROBE], {
    env: {
      ...process.env,
      TREE_ROOT: root,
      TREE_CACHE: cache,
      TREE_OVERRIDES: overrides,
    },
  });
  const text = readFileSync(cache, "utf8");
  assert.match(text, /outside\/thing\.md/, "outside-tree row must survive a probe run");
  assert.match(text, /parked thing/, "outside-tree description must survive");
});
