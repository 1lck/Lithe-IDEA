import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const scripts = path.dirname(fileURLToPath(import.meta.url));
const cases = [
  ["English comments and localized strings", '/* static */\n/*\n entry\n */\nconst TEXT: &str = "中文";\nconst URL: &str = "https://示例";', false],
  ["Chinese line comment", 'const X: u8 = 1; // 中文说明', true],
  ["Chinese multiline block", '/* English\n 中文说明\n */', true],
  ["supplementary Han block", '/* 𠀀 */', true],
];

for (const locale of ["C", "en_US.UTF-8"]) {
  for (const [name, source, rejected] of cases) {
    test(`${locale}: ${name}`, { timeout: 15_000 }, () => {
      // A Unicode checkout path must not make English comment text fail.
      const root = mkdtempSync(path.join(os.tmpdir(), "lithe-注释-"));
      try {
        const bin = path.join(root, "bin");
        mkdirSync(bin);
        mkdirSync(path.join(root, "scripts"));
        mkdirSync(path.join(root, "rust/lithe-core/src"), { recursive: true });
        copyFileSync(path.join(scripts, "verify-rust-core-comments.sh"), path.join(root, "scripts/verify-rust-core-comments.sh"));
        writeFileSync(path.join(root, "rust/lithe-core/src/lib.rs"), `//! Fixture module.\n${source}\n`);
        // Exercise the no-ripgrep path as well as the system awk used by CI.
        for (const tool of ["dirname", "find", "awk", "ruby", "sed", "sort"]) {
          const located = spawnSync("/bin/sh", ["-c", `command -v ${tool}`], { encoding: "utf8", timeout: 2_000 });
          assert.equal(located.status, 0, `Required checker tool: ${tool}`);
          symlinkSync(located.stdout.trim(), path.join(bin, tool));
        }
        const cargo = path.join(bin, "cargo");
        writeFileSync(cargo, "#!/bin/sh\nexit 0\n");
        chmodSync(cargo, 0o755);
        const result = spawnSync("/bin/bash", [path.join(root, "scripts/verify-rust-core-comments.sh")], {
          env: { ...process.env, PATH: bin, LC_ALL: locale, LANG: locale },
          encoding: "utf8", timeout: 10_000,
        });
        assert.ifError(result.error);
        assert.equal(result.status, rejected ? 1 : 0, result.stdout + result.stderr);
        if (rejected) assert.match(result.stderr, /Rust Core comments must be written in English/);
        else assert.match(result.stdout, /Rust Core comment verification passed/);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    });
  }
}
