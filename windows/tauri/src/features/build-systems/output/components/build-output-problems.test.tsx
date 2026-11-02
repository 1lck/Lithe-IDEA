import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { BuildDiagnostic, BuildTestCase } from "../build-output-types";

const restoreDom = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { default: BuildOutputProblems, MAX_PROBLEM_ROWS } = await import("./build-output-problems");
afterAll(restoreDom);

const WORKSPACE = "C:/work/output-problems-fixture";
const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function diagnostic(overrides: Partial<BuildDiagnostic> = {}): BuildDiagnostic {
  return {
    path: "src/main.rs",
    line: 4,
    column: 9,
    severity: "error",
    message: "cannot find value `x` in this scope",
    ...overrides,
  };
}

function failedTest(overrides: Partial<BuildTestCase> = {}): BuildTestCase {
  return {
    suite: "com.example.OrderTest",
    case: "refunds",
    status: "failed",
    message: "expected 200 but was 500",
    invocations: 1,
    ...overrides,
  };
}

async function mount(props: {
  diagnostics?: BuildDiagnostic[];
  failedTests?: BuildTestCase[];
  diagnosticsDropped?: number;
  onReveal?: (path: string, line: number, column?: number) => void;
}) {
  const reveals: Array<{ path: string; line: number; column?: number }> = [];
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
      <LocaleProvider language="en-US">
        <BuildOutputProblems
          diagnostics={props.diagnostics ?? []}
          failedTests={props.failedTests ?? []}
          diagnosticsDropped={props.diagnosticsDropped ?? 0}
          workspaceRoot={WORKSPACE}
          onReveal={
            props.onReveal ?? ((path, line, column) => reveals.push({ path, line, column }))
          }
        />
      </LocaleProvider>,
    ),
  );
  return { host, reveals };
}

test("a workspace diagnostic navigates with its one-based line and column", async () => {
  const { host, reveals } = await mount({ diagnostics: [diagnostic()] });

  const button = host.querySelector<HTMLButtonElement>(
    '[data-slot="build-output-problems"] button',
  );
  expect(button).not.toBeNull();
  expect(button!.textContent).toContain("src/main.rs:4:9");
  expect(button!.textContent).toContain("cannot find value `x` in this scope");
  await act(async () => button!.click());

  expect(reveals).toEqual([
    {
      path: expect.stringMatching(
        /C:[\\/]work[\\/]output-problems-fixture[\\/]src[\\/]main\.rs/,
      ) as string,
      line: 4,
      column: 9,
    },
  ]);
});

test("illegal locations render as plain text and never navigate", async () => {
  const { host, reveals } = await mount({
    diagnostics: [
      diagnostic({ path: "remote://host/share/File.java", line: 1 }),
      diagnostic({ path: "C:/outside/App.java", line: 2 }),
      diagnostic({ path: "../escape.rs", line: 3 }),
    ],
    failedTests: [failedTest({ path: undefined, line: undefined })],
  });

  expect(host.querySelectorAll('[data-slot="build-output-problems"] button')).toHaveLength(0);
  expect(host.querySelectorAll('[data-slot="build-output-problems"] div')).toHaveLength(4);
  // The failed test without a report location stays visible but inert.
  expect(host.textContent).toContain("com.example.OrderTest › refunds");
  await act(async () => {
    for (const row of host.querySelectorAll('[data-slot="build-output-problems"] > *'))
      (row as HTMLElement).click?.();
  });
  expect(reveals).toEqual([]);
});

test("a failed test with a report location navigates to its line", async () => {
  const { host, reveals } = await mount({
    failedTests: [failedTest({ path: "app/src/test/OrderTest.java", line: 17 })],
  });

  const button = host.querySelector<HTMLButtonElement>(
    '[data-slot="build-output-problems"] button',
  );
  expect(button).not.toBeNull();
  await act(async () => button!.click());

  expect(reveals).toHaveLength(1);
  expect(reveals[0]!.line).toBe(17);
  expect(reveals[0]!.column).toBeUndefined();
});

test("rows beyond the cap collapse into a notice that keeps the diagnostics drop count", async () => {
  const many = Array.from({ length: MAX_PROBLEM_ROWS + 3 }, (_, index) =>
    diagnostic({ path: `src/File${index}.rs`, line: index + 1 }),
  );
  const { host } = await mount({ diagnostics: many, diagnosticsDropped: 11 });

  expect(host.querySelectorAll('[data-slot="build-output-problems"] button')).toHaveLength(
    MAX_PROBLEM_ROWS,
  );
  const notice = host.querySelector('[data-slot="problems-truncated"]');
  expect(notice?.textContent).toContain("3");
  expect(notice?.textContent).toContain("11");
});

test("invalid one-based coordinates stay inert for diagnostics and failed tests", async () => {
  const { host, reveals } = await mount({
    diagnostics: [
      ...[0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1].map((line) =>
        diagnostic({ line }),
      ),
      ...[0, -2, 1.5, Infinity].map((column) => diagnostic({ column })),
    ],
    failedTests: [0, -1, 1.5, undefined].map((line) =>
      failedTest({ path: "tests/Order.java", line }),
    ),
  });
  expect(host.querySelectorAll("button")).toHaveLength(0);
  expect(reveals).toEqual([]);
});

test("source links are keyboard-focusable buttons and errored cases keep their message", async () => {
  const { host, reveals } = await mount({
    diagnostics: [diagnostic({ column: undefined })],
    failedTests: [failedTest({ status: "error", path: "tests/Order.java", line: 1 })],
  });
  const buttons = [...host.querySelectorAll<HTMLButtonElement>("button")];
  expect(buttons).toHaveLength(2);
  buttons[0]!.focus();
  expect(document.activeElement).toBe(buttons[0]);
  expect(buttons[1]!.textContent).toContain("expected 200 but was 500");
  await act(async () => buttons[1]!.click());
  expect(reveals[0]!.line).toBe(1);
});
