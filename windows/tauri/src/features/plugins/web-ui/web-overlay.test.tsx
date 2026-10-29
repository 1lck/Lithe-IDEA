import { afterAll, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { webPanelLayout } from "./web-panel-viewport";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { default: Tooltip, TooltipProvider } = await import("@/ui/tooltip");
const { HoverCard, HoverCardContent, HoverCardTrigger } = await import("@/ui/hover-card");

async function checkOverlay(content: ReactNode, focus: boolean) {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previous = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div"),
    body = document.createElement("div");
  document.body.append(host, body);
  const root = createRoot(host);
  const width = Object.getOwnPropertyDescriptor(document.documentElement, "clientWidth");
  const height = Object.getOwnPropertyDescriptor(document.documentElement, "clientHeight");
  Object.defineProperty(document.documentElement, "clientWidth", {
    configurable: true,
    value: 200,
  });
  Object.defineProperty(document.documentElement, "clientHeight", {
    configurable: true,
    value: 200,
  });
  body.getBoundingClientRect = () => new DOMRect(0, 0, 100, 100);
  try {
    await act(async () => root.render(content));
    if (focus) await act(async () => host.querySelector("button")!.focus());
    const popup = document.querySelector<HTMLElement>("[data-native-web-overlay]");
    expect(popup).not.toBeNull();
    popup!.getBoundingClientRect = () => new DOMRect(20, 20, 40, 40);
    popup!.getClientRects = () => [popup!.getBoundingClientRect()] as unknown as DOMRectList;
    expect(webPanelLayout(body).visible).toBe(false);
    popup!.getBoundingClientRect = () => new DOMRect(120, 120, 40, 40);
    expect(webPanelLayout(body).visible).toBe(true);
  } finally {
    await act(async () => root.unmount());
    host.remove();
    body.remove();
    if (width) Object.defineProperty(document.documentElement, "clientWidth", width);
    else Reflect.deleteProperty(document.documentElement, "clientWidth");
    if (height) Object.defineProperty(document.documentElement, "clientHeight", height);
    else Reflect.deleteProperty(document.documentElement, "clientHeight");
    environment.IS_REACT_ACT_ENVIRONMENT = previous;
  }
  expect(document.querySelector("[data-native-web-overlay]")).toBeNull();
}

test("the production keyboard Tooltip yields native web airspace only where it overlaps", () =>
  checkOverlay(
    <TooltipProvider>
      <Tooltip content="Help">
        <button>Help</button>
      </Tooltip>
    </TooltipProvider>,
    true,
  ));

test("the production HoverCard marker yields native web airspace and disappears on unmount", () =>
  checkOverlay(
    <HoverCard open>
      <HoverCardTrigger render={<button>Preview</button>} />
      <HoverCardContent>Preview</HoverCardContent>
    </HoverCard>,
    false,
  ));
