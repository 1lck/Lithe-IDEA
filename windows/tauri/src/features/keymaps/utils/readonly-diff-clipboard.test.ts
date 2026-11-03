import { describe, expect, test } from "bun:test";
import { shouldDeferClipboardToReadOnlyDiff } from "./readonly-diff-clipboard";

function nodeInsideReadOnlyDiff(inside: boolean) {
  return {
    closest: (selector: string) =>
      inside && selector === "[data-readonly-diff]" ? { selector } : null,
  } as unknown as EventTarget;
}

function keyEvent(overrides: Record<string, unknown> = {}) {
  return {
    altKey: false,
    shiftKey: false,
    ctrlKey: false,
    metaKey: false,
    key: "c",
    ...overrides,
  } as unknown as KeyboardEvent;
}

describe("read-only diff clipboard deferral", () => {
  test("leaves copy to the diff surface under the pointer", () => {
    expect(
      shouldDeferClipboardToReadOnlyDiff(
        keyEvent({ ctrlKey: true }),
        nodeInsideReadOnlyDiff(true),
        null,
      ),
    ).toBe(true);
    expect(
      shouldDeferClipboardToReadOnlyDiff(
        keyEvent({ metaKey: true }),
        nodeInsideReadOnlyDiff(true),
        null,
      ),
    ).toBe(true);
  });

  test("recognizes the diff surface through the focused element", () => {
    expect(
      shouldDeferClipboardToReadOnlyDiff(
        keyEvent({ ctrlKey: true }),
        nodeInsideReadOnlyDiff(false),
        nodeInsideReadOnlyDiff(true),
      ),
    ).toBe(true);
  });

  test("leaves cut to the diff surface as well", () => {
    expect(
      shouldDeferClipboardToReadOnlyDiff(
        keyEvent({ ctrlKey: true, key: "x" }),
        nodeInsideReadOnlyDiff(true),
        null,
      ),
    ).toBe(true);
  });

  test("keeps the editor command outside diff surfaces", () => {
    expect(
      shouldDeferClipboardToReadOnlyDiff(
        keyEvent({ ctrlKey: true }),
        nodeInsideReadOnlyDiff(false),
        nodeInsideReadOnlyDiff(false),
      ),
    ).toBe(false);
  });

  test("ignores shortcuts the diff surface does not own", () => {
    const diffNode = nodeInsideReadOnlyDiff(true);

    // Paste belongs to the editor command, and shifted/bare-letter combos are
    // not clipboard shortcuts at all.
    expect(
      shouldDeferClipboardToReadOnlyDiff(keyEvent({ ctrlKey: true, key: "v" }), diffNode, null),
    ).toBe(false);
    expect(
      shouldDeferClipboardToReadOnlyDiff(
        keyEvent({ ctrlKey: true, shiftKey: true }),
        diffNode,
        null,
      ),
    ).toBe(false);
    expect(
      shouldDeferClipboardToReadOnlyDiff(keyEvent({ ctrlKey: true, altKey: true }), diffNode, null),
    ).toBe(false);
    expect(shouldDeferClipboardToReadOnlyDiff(keyEvent(), diffNode, null)).toBe(false);
  });
});
