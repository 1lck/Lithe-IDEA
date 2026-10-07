import { test, expect } from "bun:test";
import fixture from "../../../../../shared/fixtures/plugins/session-v1.json";
import { pluginCore } from "../packages/plugin-core";
import { useRealPluginCore } from "../testing/plugin-core-backend";
import type { PluginSessionSnapshot } from "./plugin-lifecycle";

test("Windows executes the shared session fixture against the native Core", async () => {
  const restore = useRealPluginCore();
  const ownerId = crypto.randomUUID();
  try {
    for (const step of fixture.steps) {
      const result = pluginCore.execute<PluginSessionSnapshot>("plugin.session", {
        ...step.request, ownerId, pluginId: fixture.pluginId,
      });
      if (step.error) { await expect(result).rejects.toThrow(); continue; }
      const snapshot = await result;
      if (step.state === undefined || step.resources === undefined || step.installed === undefined)
        throw new Error("A successful shared fixture step must declare the complete expected snapshot");
      expect(snapshot.lifecycle.state).toBe(step.state);
      expect(snapshot.lifecycle.resources).toEqual(step.resources);
      expect(snapshot.installed).toBe(step.installed);
    }
  } finally { restore(); }
});
