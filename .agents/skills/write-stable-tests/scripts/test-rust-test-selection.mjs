import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { parseArguments, run } from "./run-rust-tests-with-timing.mjs";

test("Rust prefix selection preserves default coverage and rejects zero matches", { timeout: 5000 }, async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "lithe-rust-selection-"));
  try {
    for (const prefixes of [[], ["real_jdt::"], ["missing::"]]) {
      const report = path.join(root, "report.json");
      const options = parseArguments(["--manifest", path.join(root, "Cargo.toml"), "--report", report,
        ...prefixes.flatMap((prefix) => ["--test-prefix", prefix])]);
      const executed = [];
      const execute = async ({ command, args, onStdoutLine }) => {
        if (command === "cargo") onStdoutLine(JSON.stringify({ reason: "compiler-artifact", profile: { test: true },
          executable: path.join(root, "fixture"), manifest_path: options.manifest, target: { name: "fixture" } }));
        else if (args[0] === "--list") return { code: 0, durationMs: 1, stderr: "", stdout: "ordinary::case: test\nreal_jdt::case: test\n" };
        else executed.push(args[1]);
        return { code: 0, durationMs: 1, stdout: "test fixture ... ok\n", stderr: "" };
      };
      const result = run(options, { runProcessImpl: execute });
      if (prefixes[0] === "missing::") await assert.rejects(result, /No Rust tests matched/);
      else await result;
      assert.deepEqual(executed, prefixes.length === 0 ? ["ordinary::case", "real_jdt::case"] : prefixes[0] === "missing::" ? [] : ["real_jdt::case"]);
      const saved = JSON.parse(readFileSync(report, "utf8"));
      assert.deepEqual(saved.testPrefixes, prefixes);
      assert.equal(saved.discoveredTests, 2);
      assert.equal(saved.selectedTests, executed.length);
    }
    assert.throws(() => parseArguments(["--manifest", "Cargo.toml", "--test-prefix", ""]), /nonempty/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
