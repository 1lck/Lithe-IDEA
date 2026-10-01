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

beforeEach(async () => {
  restoreDom = installHappyDom();
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
  });
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
