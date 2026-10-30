import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { BuildTestResults } from "../build-output-types";

const restoreDom = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { default: BuildOutputTestsSummary } = await import("./build-output-tests");
afterAll(restoreDom);

const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function results(
  summary: Partial<BuildTestResults["summary"]>,
  success: boolean,
): BuildTestResults {
  return {
    tests: [],
    summary: {
      total: 0,
      passed: 0,
      failed: 0,
      errors: 0,
      skipped: 0,
      ...summary,
    },
    success,
  };
}

async function mount(props: {
  results: BuildTestResults;
  language?: "en-US" | "zh-CN";
  dropped?: number;
}) {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root: Root = createRoot(host);
  cleanups.push(async () => {
    try {
      await act(async () => root.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  });
  await act(async () =>
    root.render(
      <LocaleProvider language={props.language ?? "en-US"}>
        <BuildOutputTestsSummary results={props.results} dropped={props.dropped} />
      </LocaleProvider>,
    ),
  );
  return { host };
}

test("a fully passing run shows the passed verdict and count only", async () => {
  const { host } = await mount({ results: results({ passed: 12, total: 12 }, true) });
  const text = host.textContent ?? "";
  expect(text).toContain("Tests passed");
  expect(text).toContain("12 passed");
  expect(text).not.toContain("failed");
  expect(text).not.toContain("skipped");
});

test("a failing run folds failures and errors into one failed count", async () => {
  const { host } = await mount({
    results: results({ total: 7, passed: 4, failed: 2, errors: 1, skipped: 0 }, false),
  });
  const text = host.textContent ?? "";
  expect(text).toContain("Tests failed");
  expect(text).toContain("4 passed");
  expect(text).toContain("3 failed");
});

test("skipped cases are counted when present", async () => {
  const { host } = await mount({
    results: results({ total: 5, passed: 4, skipped: 1 }, true),
  });
  const text = host.textContent ?? "";
  expect(text).toContain("1 skipped");
});

test("the verdict localizes to Chinese", async () => {
  const { host } = await mount({
    results: results({ total: 2, passed: 1, failed: 1 }, false),
    language: "zh-CN",
  });
  const text = host.textContent ?? "";
  expect(text).toContain("测试失败");
  expect(text).toContain("1 个通过");
  expect(text).toContain("1 个失败");
});

test("test detail truncation is visible and keeps the complete summary counts", async () => {
  const { host } = await mount({
    results: results({ total: 5000, passed: 4998, failed: 1, skipped: 1 }, false),
    dropped: 3000,
  });
  expect(host.textContent).toContain("3000 test details omitted");
  expect(host.textContent).toContain("4998 passed");
  expect(host.textContent).toContain("1 failed");
  expect(host.textContent).toContain("1 skipped");
});
