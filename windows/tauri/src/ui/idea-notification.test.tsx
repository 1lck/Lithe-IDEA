import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { IdeaNotificationCard } from "./idea-notification";

const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    container.remove();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

const renderCard = async (props: Parameters<typeof IdeaNotificationCard>[0]) =>
  act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <IdeaNotificationCard {...props} />
      </LocaleProvider>,
    ),
  );
const buttons = () => Array.from(container.querySelectorAll<HTMLButtonElement>("button"));

test("shows a bold lead-in with the details and the actions as links", async () => {
  await renderCard({
    title: "Deleted Branch:",
    message: "feature/old",
    actions: [{ label: "Restore", onClick: () => {} }],
    onDismiss: () => {},
  });
  expect(container.querySelector("p")?.textContent).toBe("Deleted Branch: feature/old");
  expect(container.querySelector("p span")?.className).toContain("font-semibold");
  expect(buttons().map((button) => button.textContent)).toEqual(["Restore", ""]);
  expect(buttons()[0]!.className).toContain("text-primary");
});

test("an action dismisses the notification and then runs", async () => {
  const calls: string[] = [];
  await renderCard({
    title: "Deleted Branch:",
    message: "feature/old",
    actions: [{ label: "Restore", onClick: () => calls.push("restore") }],
    onDismiss: () => calls.push("dismiss"),
  });
  await act(async () => buttons()[0]!.click());
  expect(calls).toEqual(["dismiss", "restore"]);
});

test("the close button only dismisses", async () => {
  const onDismiss = mock(() => {});
  const onClick = mock(() => {});
  await renderCard({
    title: "Deleted Branch:",
    message: "feature/old",
    actions: [{ label: "Restore", onClick }],
    onDismiss,
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[aria-label]")!.click());
  expect(onDismiss).toHaveBeenCalledTimes(1);
  expect(onClick).not.toHaveBeenCalled();
});

test("without actions only the close button is rendered", async () => {
  await renderCard({ title: "Deleted Branch:", message: "feature/old", onDismiss: () => {} });
  expect(buttons()).toHaveLength(1);
  expect(buttons()[0]!.getAttribute("aria-label")).not.toBeNull();
});
