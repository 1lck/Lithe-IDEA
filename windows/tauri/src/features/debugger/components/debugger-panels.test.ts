import { expect, test } from "bun:test";
import { getDebugSessionDisplayStatus } from "./debugger-panels";

test("terminal reasons remain distinct from an idle debugger session", () => {
  expect(getDebugSessionDisplayStatus("idle", "exited")).toBe("exited");
  expect(getDebugSessionDisplayStatus("idle", "stopped")).toBe("stopped");
  expect(getDebugSessionDisplayStatus("idle", "failed")).toBe("failed");
  expect(getDebugSessionDisplayStatus("idle", "unknown")).toBe("idle");
  expect(getDebugSessionDisplayStatus("running", "failed")).toBe("running");
});
