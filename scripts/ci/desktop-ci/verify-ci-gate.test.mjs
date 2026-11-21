import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { verifyCIGate } from "./verify-ci-gate.mjs";

const lanes = ["pins", "linux", "linux-test", "remote-server", "macos", "windows"];
const passed = () => Object.fromEntries(lanes.map((lane) => [lane, { result: "success" }]));

test("ready PRs and main pushes require every lane to pass", { timeout: 1000 }, () => {
  assert.doesNotThrow(() => verifyCIGate(passed(), false));
  for (const lane of lanes) {
    for (const result of ["failure", "cancelled", "skipped", undefined]) {
      const needs = passed();
      needs[lane].result = result;
      assert.throws(() => verifyCIGate(needs, false), new RegExp(lane));
    }
  }
});

test("drafts defer only native lanes and still require all Linux lanes", { timeout: 1000 }, () => {
  const needs = passed();
  needs.macos.result = "skipped";
  needs.windows.result = "skipped";
  assert.doesNotThrow(() => verifyCIGate(needs, true));
  for (const lane of lanes) {
    const broken = structuredClone(needs);
    broken[lane].result = "failure";
    assert.throws(() => verifyCIGate(broken, true), new RegExp(lane));
    delete broken[lane];
    assert.throws(() => verifyCIGate(broken, true), /missing/);
  }
  for (const lane of ["pins", "linux", "linux-test", "remote-server"]) {
    const broken = structuredClone(needs);
    broken[lane].result = "skipped";
    assert.throws(() => verifyCIGate(broken, true), new RegExp(lane));
  }
});

test("the gate job depends on exactly the lanes it requires", { timeout: 1000 }, () => {
  const workflow = readFileSync(new URL("../../../.github/workflows/desktop-ci.yml", import.meta.url), "utf8");
  const gate = workflow.slice(workflow.indexOf("\n  gate:\n"));
  const needs = /\n    needs: \[([^\]]*)\]\n/.exec(gate);
  assert.ok(needs, "the gate job lists its dependencies on one line");
  assert.deepEqual(needs[1].split(",").map((lane) => lane.trim()), lanes);
});

test("workflow entry point fails closed for missing or malformed inputs", { timeout: 15000 }, () => {
  const script = fileURLToPath(new URL("./verify-ci-gate.mjs", import.meta.url));
  for (const [draft, needs, success] of [
    ["false", JSON.stringify(passed()), true],
    ["false", "{}", false],
    ["true", "null", false],
    ["false", "invalid json", false],
    ["", JSON.stringify(passed()), false],
  ]) {
    const result = spawnSync(process.execPath, [script], {
      env: { ...process.env, CI_DRAFT: draft, CI_NEEDS: needs },
      encoding: "utf8", timeout: 2000,
    });
    assert.ifError(result.error);
    assert.equal(result.status === 0, success, result.stderr);
  }
});
