import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import type { BuildModelReview } from "@/features/build-systems/build-systems-types";

const restoreDom = installHappyDom();
const { createWebBuildApproval } = await import("./plugin-web-build-approval");
const cleanups: Array<() => void | Promise<void>> = [];
const t = createTranslator("en-US");
afterAll(restoreDom);
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await act(cleanup);
});
const review: BuildModelReview = {
  operationId: "fixture-native-operation",
  pluginId: "fixture.web.plugin",
  buildSystemId: "fixture-build",
  workspaceRoot: "C:/fixture/web-approval",
  root: "nested",
  generation: 7,
  executesProjectCode: true,
  mayUseNetwork: true,
};
const programs = [
  { kind: "projectFile", path: "fixture-wrapper", arguments: ["literal argument"] },
];

async function fixture(selectedReview: BuildModelReview = review) {
  const previous = useSettingsStore.getState().settings;
  useSettingsStore.setState({ settings: { ...previous, displayLanguage: "en-US" } });
  cleanups.push(() => {
    useSettingsStore.setState({ settings: previous });
  });
  const approval = createWebBuildApproval();
  cleanups.push(() => approval.close());
  const controller = new AbortController();
  let result!: Promise<boolean>;
  await act(async () => {
    result = approval.approve(selectedReview, programs, controller.signal);
  });
  cleanups.push(async () => {
    controller.abort();
    await result;
  });
  return { approval, controller, result };
}
function button(label: string) {
  const match = [...document.querySelectorAll("button")].find(
    (element) => element.textContent === label,
  );
  if (!match) throw new Error(`Missing approval button: ${label}`);
  return match;
}

test("web approval shows native identity, full program declarations and risks before consent", async () => {
  const f = await fixture();
  for (const value of [
    review.pluginId,
    review.buildSystemId,
    review.workspaceRoot,
    review.root,
    review.operationId,
    "fixture-wrapper",
    "literal argument",
    t("buildSystems.model.projectCode"),
    t("buildSystems.model.network"),
  ]) {
    expect(document.body.textContent).toContain(value);
  }
  await act(async () => button(t("buildSystems.run.approve")).click());
  expect(await f.result).toBe(true);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
});

test("decline and page revocation settle approval without granting consent", async () => {
  const first = await fixture();
  await act(async () => button(t("buildSystems.model.decline")).click());
  expect(await first.result).toBe(false);
  const second = await fixture();
  await act(async () => second.controller.abort());
  expect(await second.result).toBe(false);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
});

test("Provider approval includes the exact resolved native program and shared source", async () => {
  const f = await fixture({
    ...review,
    provider: {
      token: 9,
      context: {
        window: "main",
        workspaceRoot: review.workspaceRoot,
        generation: review.generation,
        pluginId: review.pluginId,
        packageIdentity: "approved-package",
        buildSystem: review.buildSystemId,
        instanceRoot: review.root,
        instanceDirectory: `${review.workspaceRoot}/nested`,
      },
      executesProjectCode: true,
      mayUseNetwork: true,
      program: {
        pluginId: review.pluginId,
        languageId: "fixture-language",
        serverPath: "C:/fixture/runtime/provider.exe",
        serverArgs: ["--workspace", "literal provider argument"],
        environment: { PROVIDER_MODE: "reviewed" },
        initializationOptions: { feature: "provider-init" },
        workspaceConfiguration: { feature: "provider-config" },
      },
      launchPlan: {
        buildProvider: { languageServer: "fixture-language" },
        runtimeRequirements: [{ id: "fixture-runtime" }],
        validationArguments: ["--provider-version"],
      },
      invocationPlan: { executables: [{ kind: "setting", settingID: "fixture-tool" }] },
    },
  });
  for (const value of [
    "C:/fixture/runtime/provider.exe",
    "literal provider argument",
    "PROVIDER_MODE",
    "reviewed",
    "fixture-language",
    "provider-init",
    "provider-config",
    "fixture-runtime",
    "--provider-version",
    "fixture-tool",
  ]) {
    expect(document.body.textContent).toContain(value);
  }
  await act(async () => button(t("buildSystems.run.approve")).click());
  expect(await f.result).toBe(true);
});

test("closing the presenter settles pending approval and removes its root", async () => {
  const f = await fixture();
  await act(async () => f.approval.close());
  expect(await f.result).toBe(false);
  expect(document.body.textContent).not.toContain(review.operationId);
});

test("cleanup failure stays visible and retries the same cleanup until it succeeds", async () => {
  const f = await fixture();
  await act(async () => f.controller.abort());
  let attempts = 0;
  await act(async () =>
    f.approval.failed("first cleanup failure", async () => {
      if (++attempts === 1) throw new Error("second cleanup failure");
    }),
  );
  await act(async () => button(t("buildSystems.model.retryCancel")).click());
  expect(document.querySelector('[role="alert"]')?.textContent).toContain("second cleanup failure");
  await act(async () => button(t("buildSystems.model.retryCancel")).click());
  expect(attempts).toBe(2);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
});
