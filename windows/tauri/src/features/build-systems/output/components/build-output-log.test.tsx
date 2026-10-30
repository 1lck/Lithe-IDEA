import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { MAX_LOG_ROWS } from "./build-output-log";
import type { BuildOutputLine } from "../build-output-store";

const restoreDom = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { default: BuildOutputLog } = await import("./build-output-log");
afterAll(restoreDom);

const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function lines(entries: Array<[BuildOutputLine["stream"], string]>): BuildOutputLine[] {
  return entries.map(([stream, text], seq) => ({ seq, stream, text, clipped: false }));
}

async function mount() {
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
  const render = (props: { lines: BuildOutputLine[]; droppedLines: number }) =>
    root.render(
      <LocaleProvider language="en-US">
        <BuildOutputLog {...props} />
      </LocaleProvider>,
    );
  return { host, render };
}

test("renders interleaved streams in order with stderr visually distinct", async () => {
  const { host, render } = await mount();
  await act(async () =>
    render({
      lines: lines([
        ["stdout", "Compiling app v0.1.0"],
        ["stderr", "warning: unused import"],
        ["stdout", "Done"],
      ]),
      droppedLines: 0,
    }),
  );

  const rendered = [...host.querySelectorAll("[role='log'] p")];
  expect(rendered.map((line) => line.textContent)).toEqual([
    "stdout: Compiling app v0.1.0",
    "stderr: warning: unused import",
    "stdout: Done",
  ]);
  expect(rendered[1]!.className).toContain("text-destructive");
  expect(rendered[0]!.className).not.toContain("text-destructive");
});

test("shows the truncation notice for evicted lines and clips oversized lines", async () => {
  const { host, render } = await mount();
  const oversized: BuildOutputLine = {
    seq: 0,
    stream: "stdout",
    text: "x".repeat(50),
    clipped: true,
  };
  await act(async () =>
    render({
      lines: [oversized, ...lines([["stdout", "tail"]])].map((line, index) => ({
        ...line,
        seq: index,
      })),
      droppedLines: 321,
    }),
  );

  expect(host.querySelector('[data-slot="log-truncated"]')?.textContent).toContain("321");
  const rendered = [...host.querySelectorAll("[role='log'] p")];
  expect(rendered[1]!.textContent).toBe("stdout: " + "x".repeat(50) + "…");
});

test("renders only the newest rows beyond the display cap and counts the hidden ones", async () => {
  const { host, render } = await mount();
  const many: BuildOutputLine[] = Array.from({ length: MAX_LOG_ROWS + 5 }, (_, seq) => ({
    seq,
    stream: "stdout" as const,
    text: `line ${seq}`,
    clipped: false,
  }));
  await act(async () => render({ lines: many, droppedLines: 0 }));

  const rendered = [...host.querySelectorAll("[role='log'] p")];
  expect(rendered).toHaveLength(MAX_LOG_ROWS + 1); // notice row + newest MAX_LOG_ROWS
  expect(rendered[0]!.textContent).toContain("5");
  expect(rendered[1]!.textContent).toBe("stdout: line 5");
  expect(rendered[rendered.length - 1]!.textContent).toBe(`stdout: line ${MAX_LOG_ROWS + 4}`);
});

test("new output follows the bottom only while the user stays near it", async () => {
  const { host, render } = await mount();
  await act(async () => render({ lines: lines([["stdout", "first"]]), droppedLines: 0 }));
  const log = host.querySelector<HTMLElement>('[role="log"]')!;
  Object.defineProperty(log, "scrollHeight", { configurable: true, value: 1000 });
  Object.defineProperty(log, "clientHeight", { configurable: true, value: 200 });
  log.scrollTop = 100;
  await act(async () => log.dispatchEvent(new Event("scroll")));
  await act(async () =>
    render({
      lines: lines([
        ["stdout", "first"],
        ["stderr", "second"],
      ]),
      droppedLines: 0,
    }),
  );
  expect(log.scrollTop).toBe(100);
  log.scrollTop = 790;
  await act(async () => log.dispatchEvent(new Event("scroll")));
  await act(async () => render({ lines: lines([["stdout", "third"]]), droppedLines: 0 }));
  expect(log.scrollTop).toBe(1000);
  expect(log.tabIndex).toBe(0);
});
