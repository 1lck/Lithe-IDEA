import { expect, test } from "bun:test";
import { validBuildProviderReview, type BuildModelReview } from "./build-systems-types";
import { ensureBuildProviderLanguage } from "./build-provider-language";

function review(): BuildModelReview {
  return {
    operationId: "native-operation",
    pluginId: "fixture.plugin",
    buildSystemId: "fixture-system",
    workspaceRoot: "C:/fixture",
    root: "module",
    generation: 4,
    executesProjectCode: true,
    mayUseNetwork: true,
    provider: {
      token: 1,
      context: {
        window: "main",
        workspaceRoot: "\\\\?\\C:\\fixture",
        generation: 4,
        pluginId: "fixture.plugin",
        buildSystem: "fixture-system",
        packageIdentity: "package:digest",
        instanceRoot: "module",
        instanceDirectory: "C:/fixture/module",
      },
      executesProjectCode: true,
      mayUseNetwork: true,
      launchPlan: { launch: { kind: "packaged" } },
      program: {
        pluginId: "fixture.plugin",
        languageId: "fixture-system",
        serverPath: "C:/plugin/provider.exe",
        serverArgs: ["--stdio"],
        environment: {},
      },
    },
  };
}
test("native Provider review retains program, instance and conservative risk approval", () => {
  const value = review();
  expect(validBuildProviderReview(value)).toBe(true);
  expect(value.provider?.program.serverArgs).toEqual(["--stdio"]);
  expect(validBuildProviderReview({ ...value, executesProjectCode: false })).toBe(false);
  expect(validBuildProviderReview({ ...value, mayUseNetwork: false })).toBe(false);
}, 1000);
test("foreign window-independent identity fields cannot borrow a build approval", () => {
  for (const field of [
    "pluginId",
    "buildSystem",
    "workspaceRoot",
    "generation",
    "instanceRoot",
    "packageIdentity",
  ] as const) {
    const value = review();
    const context = value.provider!.context as unknown as Record<string, unknown>;
    context[field] = field === "generation" ? 999 : field === "packageIdentity" ? "" : "foreign";
    expect(validBuildProviderReview(value)).toBe(false);
  }
}, 1000);
test("incomplete Provider program review is refused while command reviews remain compatible", () => {
  for (const field of ["program", "context", "launchPlan", "token"]) {
    const value = review();
    (value.provider as unknown as Record<string, unknown>)[field] = null;
    expect(validBuildProviderReview(value)).toBe(false);
  }
  const value = review();
  delete value.provider;
  expect(validBuildProviderReview(value)).toBe(true);
}, 1000);

test("native UNC canonical identity preserves the original workspace approval", () => {
  const value = review();
  value.workspaceRoot = "//server/share/project";
  value.provider!.context.workspaceRoot = "\\\\?\\UNC\\server\\share\\project";
  expect(validBuildProviderReview(value)).toBe(true);
}, 1000);

test("shared Provider uses the existing language owner with the exact approved program", async () => {
  const value = review();
  value.provider!.launchPlan.buildProvider = { languageServer: "fixture-language" };
  const calls: Record<string, unknown>[] = [];
  await ensureBuildProviderLanguage(value, undefined, async (args) => {
    calls.push(args);
  });
  expect(calls).toHaveLength(1);
  expect(calls[0]).toMatchObject({
    providerId: value.pluginId,
    pluginId: value.pluginId,
    languageId: "fixture-language",
    workspacePath: value.workspaceRoot,
    serverPath: value.provider!.program.serverPath,
    serverArgs: ["--stdio"],
  });
}, 1000);

test("declined or already cancelled shared preparation starts no language process", async () => {
  const value = review();
  value.provider!.launchPlan.buildProvider = { languageServer: "fixture-language" };
  const controller = new AbortController();
  controller.abort();
  let calls = 0;
  await expect(
    ensureBuildProviderLanguage(value, controller.signal, async () => {
      calls++;
    }),
  ).rejects.toThrow("plugin.build.cancelled");
  expect(calls).toBe(0);
  await ensureBuildProviderLanguage(review(), undefined, async () => {
    calls++;
  });
  expect(calls).toBe(0); // Dedicated Provider initialization stays native.
}, 1000);

test("cancellation during shared initialization cannot dispatch the later build request", async () => {
  const value = review();
  value.provider!.launchPlan.buildProvider = { languageServer: "fixture-language" };
  const controller = new AbortController();
  await expect(
    ensureBuildProviderLanguage(value, controller.signal, async () => {
      controller.abort();
    }),
  ).rejects.toThrow("plugin.build.cancelled");
}, 1000);
