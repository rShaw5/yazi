import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync, spawn } from "node:child_process";

const REWRITE = new URL("../rewrite.mjs", import.meta.url).pathname;

function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), "rwroot-"));
  writeFileSync(join(root, "notes.md"), "# Hello\nsome body text\n");
  const home = mkdtempSync(join(tmpdir(), "rwhome-"));
  const fx = {
    root,
    home,
    cache: join(home, "desc-cache.tsv"),
    overrides: join(home, "overrides.tsv"),
    agent: join(home, "mock-agent.sh"),
    args: join(home, "agent-args.txt"),
  };
  // Cache format v2: rel \t key \t hyper \t long.
  writeFileSync(fx.cache, "notes.md\t1\tOld hyper here\tAn older full sentence.\n");
  writeFileSync(fx.overrides, "");
  return fx;
}

function mockAgent(fx, body) {
  writeFileSync(fx.agent, `#!/bin/sh\n${body}\n`);
  chmodSync(fx.agent, 0o755);
}

function run(fx, extraArgs = [], extraEnv = {}) {
  return execFileSync(
    "node",
    [REWRITE, "--root", fx.root, "--cache", fx.cache, "--overrides", fx.overrides,
     "--rel", "notes.md", "--hint", "mention the greeting", ...extraArgs],
    { env: { ...process.env, TREE_AGENT_BIN: fx.agent, TREE_AGENT_ARGS: "", ...extraEnv } }
  ).toString();
}

function cacheRow(fx) {
  return readFileSync(fx.cache, "utf8").split("\n").find((l) => l.startsWith("notes.md"));
}

test("hint rewrite stores hyper and long in cache and hint in overrides", () => {
  const fx = makeFixture();
  mockAgent(fx, `printf 'greeting notes\\nA short markdown note that greets readers.'`);
  run(fx);
  const cols = cacheRow(fx).split("\t");
  assert.equal(cols[2], "greeting notes", "hyper summary (short phrase) in column 3");
  assert.equal(cols[3], "A short markdown note that greets readers.", "one full sentence in column 4");
  const ovr = readFileSync(fx.overrides, "utf8");
  assert.match(ovr, /^notes\.md\thint\tmention the greeting$/m);
});

test("agent answer without a second line falls back to hyper only", () => {
  const fx = makeFixture();
  mockAgent(fx, `printf 'just a phrase'`);
  run(fx);
  const cols = cacheRow(fx).split("\t");
  assert.equal(cols[2], "just a phrase");
  assert.equal(cols[3], "just a phrase", "long falls back to hyper when the agent gives one line");
});

test("failed agent run keeps the old description", () => {
  const fx = makeFixture();
  mockAgent(fx, `echo boom >&2; exit 3`);
  assert.throws(() => run(fx));
  assert.match(readFileSync(fx.cache, "utf8"), /Old hyper here/);
  assert.match(readFileSync(fx.cache, "utf8"), /An older full sentence/);
});

test("empty hint saves no hint row (unpinned stays unpinned)", () => {
  const fx = makeFixture();
  mockAgent(fx, `printf 'generic fresh words\\nA generic sentence about the file.'`);
  execFileSync("node",
    [REWRITE, "--root", fx.root, "--cache", fx.cache, "--overrides", fx.overrides,
     "--rel", "notes.md", "--hint", ""],
    { env: { ...process.env, TREE_AGENT_BIN: fx.agent, TREE_AGENT_ARGS: "" } });
  assert.match(readFileSync(fx.cache, "utf8"), /generic fresh words/);
  assert.equal(readFileSync(fx.overrides, "utf8"), "");
});

test("pending marker is visible while the agent runs", async () => {
  const fx = makeFixture();
  mockAgent(fx, `sleep 3; printf 'slow fresh words'`);
  const child = spawn("node",
    [REWRITE, "--root", fx.root, "--cache", fx.cache, "--overrides", fx.overrides,
     "--rel", "notes.md", "--hint", "mention the greeting"],
    { env: { ...process.env, TREE_AGENT_BIN: fx.agent, TREE_AGENT_ARGS: "" } });
  let sawMarker = false;
  for (let i = 0; i < 40 && !sawMarker; i++) {
    await new Promise((r) => setTimeout(r, 100));
    try {
      if (/rewriting/.test(readFileSync(fx.cache, "utf8"))) sawMarker = true;
    } catch {}
  }
  await new Promise((resolve, reject) => child.on("close", (c) => (c === 0 ? resolve() : reject(new Error("exit " + c)))));
  assert.ok(sawMarker, "cache should show a rewriting marker mid-run");
  assert.match(readFileSync(fx.cache, "utf8"), /slow fresh words/);
});

test("agent stdout warning lines are dropped from descriptions", () => {
  const fx = makeFixture();
  mockAgent(fx, `printf '⚠ OpenCode MCP server(s) tandem still use Code Mode, which selon\\n\\nfresh clean words\\nA sentence after the warning line.'`);
  const out = run(fx);
  const cols = cacheRow(fx).split("\t");
  assert.match(cols[2], /fresh clean words/, "real hyper should be stored");
  assert.match(cols[3], /sentence after the warning/, "long sentence should be stored");
  assert.doesNotMatch(readFileSync(fx.cache, "utf8"), /OpenCode MCP/, "warning text must not become the description");
});

// --- image attachment feature ---
function mockAgentRecording(fx, output) {
  // Records the argv it was called with so tests can assert flags like --file.
  writeFileSync(fx.agent,
    `#!/bin/sh\n{ for a in "$@"; do printf '%s\\t' "$a"; done; printf '\\n'; } > ${JSON.stringify(fx.args)}\n${output}\n`);
  chmodSync(fx.agent, 0o755);
}

function makeImageFixture(ext) {
  const fx = makeFixture();
  const name = `shot.${ext}`;
  writeFileSync(join(fx.root, name), Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  return { fx, name };
}

test("image rows attach the file to the agent call", (t) => {
  for (const ext of ["png", "gif"]) {
    const { fx, name } = makeImageFixture(ext);
    mockAgentRecording(fx, `printf 'bright picture\\nA mostly white screenshot of a demo.'`);
    const out = execFileSync("node",
      [REWRITE, "--root", fx.root, "--cache", fx.cache, "--overrides", fx.overrides,
       "--rel", name, "--hint", ""],
      { env: { ...process.env, TREE_AGENT_BIN: fx.agent, TREE_AGENT_ARGS: "" } }).toString();
    const argv = readFileSync(fx.args, "utf8");
    const message = `${ext}: ${argv}`;
    const fields = argv.trimEnd().split("\t");
    assert.match(
      fields[fields.length - 1],
      /^Describe "/,
      `${ext}: the prompt must be the final agent argument (opencode run takes flags before the message)`,
    );
    assert.ok(
      fields.indexOf("--file") !== -1 && fields.indexOf("--file") < fields.length - 1,
      `${ext}: --file must come before the message`,
    );
    assert.equal(fields[fields.indexOf("--file") + 1], join(fx.root, name), `${ext}: the image path itself is passed`);
    assert.match(argv, /attached|image/i, "prompt should say the image is attached");
    const cols = readFileSync(fx.cache, "utf8").split("\n").find((l) => l.startsWith(name)).split("\t");
    assert.equal(cols[2], "bright picture", `${ext}: hyper stored`);
  }
});

test("text rows never send --file", () => {
  const fx = makeFixture();
  mockAgentRecording(fx, `printf 'fresh words\\nA fresh sentence.'`);
  run(fx);
  assert.doesNotMatch(readFileSync(fx.args, "utf8"), /--file/, "text files must not pass --file");
});
