import { expect, test } from "bun:test";
import { runTitleBarDrag } from "./title-bar-drag";

type TitleBarMouseDownEvent = Parameters<typeof runTitleBarDrag>[0];

function createMouseDownEvent({
  contained,
  interactive = false,
}: {
  contained: boolean;
  interactive?: boolean;
}): TitleBarMouseDownEvent {
  const target = {
    closest: () => (interactive ? {} : null),
  };

  return {
    button: 0,
    target,
    currentTarget: {
      contains: () => contained,
    },
  } as unknown as TitleBarMouseDownEvent;
}

test("title bar drag ignores mouse events from portaled content", () => {
  let dragCount = 0;

  const didStart = runTitleBarDrag(createMouseDownEvent({ contained: false }), () => {
    dragCount += 1;
  });

  expect(didStart).toBe(false);
  expect(dragCount).toBe(0);
});

test("title bar drag starts for contained non-interactive content", () => {
  let dragCount = 0;

  const didStart = runTitleBarDrag(createMouseDownEvent({ contained: true }), () => {
    dragCount += 1;
  });

  expect(didStart).toBe(true);
  expect(dragCount).toBe(1);
});

test("title bar drag ignores contained interactive controls", () => {
  let dragCount = 0;

  const didStart = runTitleBarDrag(
    createMouseDownEvent({ contained: true, interactive: true }),
    () => {
      dragCount += 1;
    },
  );

  expect(didStart).toBe(false);
  expect(dragCount).toBe(0);
});
