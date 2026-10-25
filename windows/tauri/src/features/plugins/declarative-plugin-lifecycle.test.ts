import { expect, test } from "bun:test";
import {
  assertPluginActive,
  pluginPlanGuard,
  setPluginActive,
} from "./declarative-plugin-lifecycle";

test("revocation rejects old plans and new launches until the plugin resumes", () => {
  const id = "test.plugin";
  const oldPlan = pluginPlanGuard();
  setPluginActive(id, false);
  try {
    expect(() => assertPluginActive(id)).toThrow("inactive");
    expect(() => oldPlan(id)).toThrow();
    setPluginActive(id, true);
    expect(() => oldPlan(id)).toThrow("superseded");
    expect(() => pluginPlanGuard()(id)).not.toThrow();
  } finally {
    setPluginActive(id, true);
  }
});
