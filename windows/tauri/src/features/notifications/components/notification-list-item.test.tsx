import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { NotificationListItem } from "./notification-list-item";
import type { NotificationEntry } from "@/features/notifications/types/notifications.types";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;

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

function notification(count: number): NotificationEntry {
  return {
    id: "toast-1",
    message: "构建失败",
    type: "error",
    createdAt: 0,
    updatedAt: 0,
    read: false,
    count,
    sources: [["toast-1", count]],
  };
}

const render = async (count: number) =>
  act(async () => {
    root.render(
      <LocaleProvider language="zh-CN">
        <NotificationListItem
          notification={notification(count)}
          actions={[]}
          onContextMenu={() => {}}
        />
      </LocaleProvider>,
    );
  });

test("a repeated notification shows its accumulated count", async () => {
  await render(1);
  expect(container.textContent).toContain("构建失败");
  expect(container.textContent).not.toContain("（1）");

  await render(2);
  expect(container.textContent).toContain("构建失败（2）");

  await render(3);
  expect(container.textContent).toContain("构建失败（3）");
  expect(container.textContent).not.toContain("构建失败（2）");
});
