import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { GitLogDateCell } from "./git-log-date-cell";

// The commit is authored in the machine's own zone so relative labels apply.
const commitTime = new Date(2026, 8, 10, 15, 0);
const localOffset = -commitTime.getTimezoneOffset();

let restoreDom: () => void;
let container: HTMLElement;
let root: Root;
const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let previousTauriFlag: PropertyDescriptor | undefined;
const pendingFormats: Array<{
  command: string;
  resolve: (value: { date: string; time: string }) => void;
}> = [];

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousTauriFlag = Object.getOwnPropertyDescriptor(globalThis, "isTauri");
  previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
  setSystemTime(new Date(2026, 8, 10, 15, 5));
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <div data-git-commit-index={0} data-testid="row">
          <GitLogDateCell date="2026/09/10 15:00" utcOffsetMinutes={localOffset} />
        </div>
      </LocaleProvider>,
    );
  });
});

afterEach(async () => {
  await act(async () => {
    root.unmount();
    for (const pending of pendingFormats.splice(0)) pending.resolve({ date: "", time: "" });
  });
  if (previousTauriFlag) Object.defineProperty(globalThis, "isTauri", previousTauriFlag);
  else Reflect.deleteProperty(globalThis, "isTauri");
  setSystemTime();
  actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

test("relative date refreshes when the pointer enters the row, not on its own", async () => {
  const row = container.querySelector<HTMLElement>('[data-testid="row"]') as HTMLElement;
  expect(row.textContent).toBe("5 minutes ago");

  setSystemTime(new Date(2026, 8, 10, 15, 20));
  expect(row.textContent).toBe("5 minutes ago");

  await act(async () => {
    row.dispatchEvent(new Event("mouseenter"));
  });
  expect(row.textContent).toBe("20 minutes ago");
});

test("native system formats survive row recycling and ignore late results", async () => {
  Object.defineProperty(globalThis, "isTauri", { configurable: true, value: true });
  Object.defineProperty(window, "__TAURI_INTERNALS__", {
    configurable: true,
    value: {
      invoke: (command: string) =>
        new Promise<{ date: string; time: string }>((resolve) => {
          pendingFormats.push({ command, resolve });
        }),
    },
  });
  const renderDate = async (date: string) => {
    await act(async () => {
      root.render(
        <LocaleProvider language="en-US">
          <div data-git-commit-index={0}>
            <GitLogDateCell date={date} utcOffsetMinutes={localOffset} />
          </div>
        </LocaleProvider>,
      );
    });
  };
  await renderDate("2026/09/08 09:07");
  await renderDate("2026/09/07 09:07");
  expect(pendingFormats.map(({ command }) => command)).toEqual([
    "format_system_date_time",
    "format_system_date_time",
  ]);
  await act(async () => {
    pendingFormats[1]!.resolve({ date: "2026-09-07", time: "09:07" });
  });
  expect(container.textContent).toBe("2026-09-07 09:07");
  await act(async () => {
    pendingFormats[0]!.resolve({ date: "2026-09-08", time: "9:07 AM" });
  });
  expect(container.textContent).toBe("2026-09-07 09:07");
});
