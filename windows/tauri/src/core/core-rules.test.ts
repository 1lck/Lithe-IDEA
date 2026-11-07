import { describe, expect, test } from "bun:test";
import { loadCoreRulesForTests } from "@/test-utils/core-rules";

// Each test loads its own copy of the loader (distinct query string), so one file's
// initialization cannot leak into another and the order of tests never matters.
let copies = 0;
function freshLoader(): Promise<typeof import("./core-rules")> {
  copies += 1;
  return import(`./core-rules.ts?copy=${copies}`);
}

describe("core rules loader", () => {
  test("synchronous calls fail loudly instead of falling back to TypeScript", async () => {
    const loader = await freshLoader();
    expect(loader.isCoreRulesReady()).toBe(false);
    expect(() => loader.executeCoreRuleSync("keymap.modifierGestureStep", { event: { kind: "keyDown" } })).toThrow(
      loader.CoreRuleError,
    );
  });

  test("a module without the expected exports is rejected and can be retried", async () => {
    const loader = await freshLoader();
    // Smallest valid wasm module: magic number and version only.
    const empty = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
    await expect(loader.initializeCoreRules(empty)).rejects.toThrow("expected C ABI");
    expect(loader.isCoreRulesReady()).toBe(false);
  });

  test("the real module initializes once and then answers synchronously", async () => {
    await loadCoreRulesForTests();
    const { isCoreRulesReady, executeCoreRuleSync } = await import("./core-rules");
    expect(isCoreRulesReady()).toBe(true);
    const step = executeCoreRuleSync<{ triggered: boolean }>("keymap.modifierGestureStep", {
      event: { kind: "keyDown" },
      timestamp: 0,
    });
    expect(step.triggered).toBe(false);
  });
});
