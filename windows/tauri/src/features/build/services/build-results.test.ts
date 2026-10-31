import { expect, test } from "bun:test";
import { BuildResultStore } from "./build-results";

test("canonical reports and discovery retain only four independent snapshots", () => {
  const store = new BuildResultStore();
  const value = { diagnostics: [{ path: "src/A.java", line: 1, severity: "error" as const, message: "upstream diagnostic" }] };
  for (let index = 0; index < 6; index++) {
    store.remember(`run-${index}`, `owner-${index}`, value);
    store.rememberDiscovery(`owner-${index}`, { revision: `revision-${index}`, tests: [{ id: "same", suite: "A", case: "method" }] });
  }
  value.diagnostics.length = 0;
  expect(store.result("run-1")).toBeUndefined(); expect(store.discovery("owner-1")).toBeUndefined();
  const copy = store.result("run-5")!; copy.diagnostics.length = 0;
  expect(store.result("run-5")?.diagnostics).toHaveLength(1);
  const discovery = store.discovery("owner-5")!; discovery.tests.length = 0;
  expect(store.discovery("owner-5")?.tests).toHaveLength(1);
  store.forgetDiscovery("owner-5");
  expect(store.discovery("owner-5")).toBeUndefined(); expect(store.result("run-5")).toBeDefined();
  store.forget("owner-5"); expect(store.result("run-5")).toBeUndefined();
  store.clear(); expect(store.result("run-4")).toBeUndefined(); expect(store.discovery("owner-4")).toBeUndefined();
}, 5000);
