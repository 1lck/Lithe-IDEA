import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import test from "node:test";

function fixture(t) {
  const root = mkdtempSync(resolve(tmpdir(), "lithe-bundle-check-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const script = "scripts/desktop/verify/verify-runtime-bundle-immutability.sh";
  mkdirSync(resolve(root, "scripts/desktop/verify"), { recursive: true });
  cpSync(resolve(import.meta.dirname, "verify-runtime-bundle-immutability.sh"), resolve(root, script));
  for (const dir of ["desktop/internal", "desktop/cmd"]) mkdirSync(resolve(root, dir), { recursive: true });
  writeFileSync(resolve(root, "desktop/cmd/main.go"), "package main\n");
  mkdirSync(resolve(root, "desktop/internal/installedpackage"), { recursive: true });
  writeFileSync(
    resolve(root, "desktop/internal/installedpackage/installedpackage.go"),
    "package installedpackage\nfunc Executable() (string, error) { return os.Executable() }\n",
  );
  const write = (name, content) => {
    const file = resolve(root, name);
    mkdirSync(resolve(file, ".."), { recursive: true });
    writeFileSync(file, content);
  };
  const run = () => spawnSync("zsh", [resolve(root, script)], { cwd: root, encoding: "utf8", timeout: 5000 });
  return { root, write, run };
}

test("checks both desktop platforms and fails closed on executable-derived paths", { timeout: 15000 }, (t) => {
  const f = fixture(t);
  assert.equal(f.run().status, 0);
  f.write("desktop/internal/resource_windows.go", "package sample\nvar path = os.Executable()\n");
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Desktop runtime must locate its installed package only through/);
});

test("keeps the installed package locator read-only and required", { timeout: 15000 }, (t) => {
  const f = fixture(t);
  f.write("desktop/internal/installedpackage/write.go", "package installedpackage\nvar _ = os.WriteFile(\"x\", nil, 0)\n");
  const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must stay read-only/);
  rmSync(resolve(f.root, "desktop/internal/installedpackage"), { recursive: true });
  assert.notEqual(f.run().status, 0);
});

test("ignores test-only executable lookups but rejects missing desktop sources", { timeout: 15000 }, (t) => {
  const f = fixture(t);
  f.write("desktop/internal/resource_test.go", "package sample\nvar path = os.Executable()\n");
  assert.equal(f.run().status, 0);
  rmSync(resolve(f.root, "desktop/cmd"), { recursive: true });
  assert.notEqual(f.run().status, 0);
});

test("retains legacy macOS and Windows write checks when those sources exist", { timeout: 15000 }, (t) => {
  const f = fixture(t);
  f.write("macos/Sources/bad.swift", "Bundle.main.resourceURL.write(data)\n");
  assert.notEqual(f.run().status, 0);
  f.write("macos/Sources/bad.swift", "Bundle.main.resourceURL\n");
  f.write("windows/tauri/src-tauri/src/bad.rs", "resource_dir().write(data);\n");
  assert.notEqual(f.run().status, 0);
});
