import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useState, useRef } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useCompactMenuBarDismissal } from "./use-compact-menu-bar-dismissal";

function CompactMenuHarness() {
  const [isOpen, setIsOpen] = useState(true);
  const containerRef = useRef<HTMLDivElement>(null);
  const focusTargetRef = useRef<HTMLButtonElement>(null);
  useCompactMenuBarDismissal(isOpen, containerRef, () => setIsOpen(false), focusTargetRef);

  return (
    <>
      <div data-testid="menu-bar" data-open={isOpen}>
        {isOpen ? (
          <div ref={containerRef}>
            <button type="button">File menu</button>
          </div>
        ) : (
          <button ref={focusTargetRef} type="button" data-testid="menu-toggle">
            Menu toggle
          </button>
        )}
        {isOpen ? (
          <div data-slot="menubar-content">
            <button type="button">Menu action</button>
          </div>
        ) : null}
      </div>
      <button type="button" data-testid="outside">
        Workbench
      </button>
    </>
  );
}

async function renderHarness(container: HTMLElement): Promise<Root> {
  const root = createRoot(container);
  await act(async () => {
    root.render(<CompactMenuHarness />);
  });
  return root;
}

test("compact menu stays open for its triggers and portaled menu items, then dismisses outside", async () => {
  const restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  let root: Root | undefined;

  try {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = await renderHarness(container);

    const menuBar = container.querySelector<HTMLElement>('[data-testid="menu-bar"]');
    const menuToggle = menuBar?.querySelector("button");
    const menuPopup = container.querySelector<HTMLElement>('[data-slot="menubar-content"]');
    const menuAction = menuPopup?.querySelector("button");
    const outside = container.querySelector<HTMLElement>('[data-testid="outside"]');

    expect(menuBar?.dataset.open).toBe("true");
    expect(menuToggle).not.toBeNull();
    expect(menuAction).not.toBeNull();
    expect(outside).not.toBeNull();

    await act(async () => {
      menuToggle?.dispatchEvent(new Event("pointerdown", { bubbles: true }));
      menuAction?.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    });
    expect(menuBar?.dataset.open).toBe("true");

    await act(async () => {
      outside?.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    });
    expect(menuBar?.dataset.open).toBe("false");
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      if (previousActEnvironment === undefined) {
        delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
      } else {
        actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
      }
      restoreDom();
    }
  }
});

test("Escape dismisses the expanded compact menu", async () => {
  const restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  let root: Root | undefined;

  try {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = await renderHarness(container);

    const menuBar = container.querySelector<HTMLElement>('[data-testid="menu-bar"]');
    expect(menuBar?.dataset.open).toBe("true");
    const fileMenuTrigger = menuBar?.querySelector("button") ?? null;
    fileMenuTrigger?.focus();
    expect(document.activeElement).toBe(fileMenuTrigger);
    const escapeEvent = new KeyboardEvent("keydown", {
      key: "Escape",
      bubbles: true,
      cancelable: true,
    });

    await act(async () => {
      document.dispatchEvent(escapeEvent);
    });

    expect(menuBar?.dataset.open).toBe("false");
    expect(escapeEvent.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(container.querySelector('[data-testid="menu-toggle"]'));
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      if (previousActEnvironment === undefined) {
        delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
      } else {
        actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
      }
      restoreDom();
    }
  }
});
