import { expect, test } from "bun:test";
import type { executeCore, CoreRequest } from "@/core/lithe-core-client";
import { createBuildCore } from "./build-core-api";

test("Build Core uses one bounded operation identity and preserves raw domain fields", async () => {
  let sent: CoreRequest | undefined;
  const core = createBuildCore((async request => {
    sent = request;
    return { id: request.id, ok: true, data: { status: "ok", model: { properties: { utf16Column: "owned" } } } };
  }) as typeof executeCore);
  expect(await core("build.decodeModel", { id: "dev.example.build" }, "example", { root: "." }, "C:/work"))
    .toMatchObject({ model: { properties: { utf16Column: "owned" } } });
  expect(sent).toMatchObject({ command: "build.decodeModel", operationId: sent!.id, timeoutMilliseconds: 30_000,
    payload: { manifest: { id: "dev.example.build" }, buildSystemID: "example", workspaceRoot: "C:/work", request: { root: "." } } });
}, 5000);

test("Build Core preserves a transport failure's stable code and details", async () => {
  const core = createBuildCore((async () => ({ id: "failed", ok: false,
    error: { code: "cancelled", message: "operation cancelled", details: "owned request" } })) as typeof executeCore);
  await expect(core("build.modelPlan", {}, "example", {})).rejects.toMatchObject({ code: "cancelled", details: "owned request" });
}, 5000);

test("Build Core keeps domain rejection distinct from a successful transport envelope", async () => {
  const core = createBuildCore((async () => ({ id: "failed", ok: true,
    data: { status: "rejected", error: { code: "plugin.build.invalidSelection", message: "project missing", field: "request.project" } } })) as typeof executeCore);
  await expect(core("build.taskPlan", {}, "example", {})).rejects.toMatchObject({ code: "plugin.build.invalidSelection", message: "project missing", field: "request.project" });
}, 5000);

test("Build Core rejects an incomplete domain envelope", async () => {
  for (const data of [{}, null, undefined]) {
    const core = createBuildCore((async () => ({ id: "failed", ok: true, data })) as typeof executeCore);
    await expect(core("build.taskPlan", {}, "example", {})).rejects.toMatchObject({ code: "invalid_response" });
  }
}, 5000);
