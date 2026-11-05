import { expect, spyOn, test } from "bun:test";
import * as dialogs from "@/ui/dialog";
import * as core from "@/platform/tauri-core";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import fixture from "../../../../../../shared/fixtures/editor/navigation-input-v1.json";
import { promptGoToLine } from "./navigation-command-actions";

test("go to line dispatches the parsed column and rejects trailing text", async () => {
  const restoreDom = installHappyDom();
  const previousCustomEvent = Object.getOwnPropertyDescriptor(globalThis, "CustomEvent");
  Object.defineProperty(globalThis, "CustomEvent", { configurable: true, writable: true, value: window.CustomEvent });
  const prompt = spyOn(dialogs, "showPromptDialog")
    .mockResolvedValueOnce("120:35").mockResolvedValueOnce("12abc").mockResolvedValueOnce("120");
  const parse = spyOn(core, "invoke").mockImplementation((async (command, args) => {
    expect(command).toBe("editor.parseNavigationInput");
    const text = (args as { text: string }).text;
    return { target: fixture.cases.find((entry) => entry.input === text)?.target ?? null };
  }) as typeof core.invoke);
  const events: CustomEvent[] = [];
  const onEvent = (event: Event) => events.push(event as CustomEvent);
  window.addEventListener("menu-go-to-line", onEvent);
  try {
    await promptGoToLine();
    await promptGoToLine();
    await promptGoToLine();
    expect(events.map((event) => event.detail)).toEqual([
      { line: 120, column: 35, selectsWholeLine: false },
      { line: 120, column: 1, selectsWholeLine: true },
    ]);
  } finally {
    window.removeEventListener("menu-go-to-line", onEvent);
    parse.mockRestore();
    prompt.mockRestore();
    if (previousCustomEvent) Object.defineProperty(globalThis, "CustomEvent", previousCustomEvent);
    else Reflect.deleteProperty(globalThis, "CustomEvent");
    restoreDom();
  }
});

test("a late parse result cannot navigate a different active document", async () => {
  const restoreDom = installHappyDom();
  const previousCustomEvent = Object.getOwnPropertyDescriptor(globalThis, "CustomEvent");
  Object.defineProperty(globalThis, "CustomEvent", { configurable: true, writable: true, value: window.CustomEvent });
  const prompt = spyOn(dialogs, "showPromptDialog").mockResolvedValue("12:3");
  let complete!: (value: unknown) => void;
  const parse = spyOn(core, "invoke").mockImplementation((() => {
    return new Promise<unknown>((resolve) => { complete = resolve; });
  }) as typeof core.invoke);
  const state = useBufferStore.getState();
  const buffer = spyOn(useBufferStore, "getState").mockReturnValue({ ...state, activeBufferId: "before" });
  const events: Event[] = [];
  const onEvent = (event: Event) => events.push(event);
  window.addEventListener("menu-go-to-line", onEvent);
  try {
    const pending = promptGoToLine();
    // Flush the already-resolved prompt; the fake Core response remains gated.
    await Promise.resolve();
    expect(complete).toBeDefined();
    buffer.mockReturnValue({ ...state, activeBufferId: "after" });
    complete({ target: { line: 11, column: 2, selectsWholeLine: false } });
    await pending;
    expect(events).toEqual([]);
  } finally {
    window.removeEventListener("menu-go-to-line", onEvent);
    buffer.mockRestore();
    parse.mockRestore();
    prompt.mockRestore();
    if (previousCustomEvent) Object.defineProperty(globalThis, "CustomEvent", previousCustomEvent);
    else Reflect.deleteProperty(globalThis, "CustomEvent");
    restoreDom();
  }
});

test("an oversized paste never crosses the Core boundary", async () => {
  const prompt = spyOn(dialogs, "showPromptDialog").mockResolvedValue("1".repeat(129));
  const parse = spyOn(core, "invoke");
  try {
    await promptGoToLine();
    expect(parse).not.toHaveBeenCalled();
  } finally {
    parse.mockRestore();
    prompt.mockRestore();
  }
});
