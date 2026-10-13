import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { editorAPI } from "@/features/editor/extensions/api";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useJumpListStore } from "@/features/editor/stores/jump-list.store";
import { useWebViewerNavigationStore } from "@/features/viewer/web/stores/web-viewer-navigation.store";
import { goBack, goForward } from "./navigation-command-actions";

const WEB_BUFFER_ID = "web-viewer-buffer";

const webGoBack = mock(() => undefined);
const webGoForward = mock(() => undefined);
const jumpGoBack = mock(() => null);
const jumpGoForward = mock(() => null);
const restorers: Array<{ mockRestore: () => void }> = [];

function setWebHistory(canGoBack: boolean, canGoForward: boolean) {
  const actions = useWebViewerNavigationStore.getState().actions;
  actions.registerNavigationActions(WEB_BUFFER_ID, { goBack: webGoBack, goForward: webGoForward });
  actions.setNavigationState(WEB_BUFFER_ID, { canGoBack, canGoForward });
}

beforeEach(() => {
  restorers.push(
    spyOn(useBufferStore, "getState").mockReturnValue({
      activeBufferId: WEB_BUFFER_ID,
      buffers: [{ id: WEB_BUFFER_ID, type: "webViewer", path: "https://example.com" }],
    } as unknown as ReturnType<typeof useBufferStore.getState>),
    spyOn(useJumpListStore, "getState").mockReturnValue({
      currentIndex: -1,
      actions: { goBack: jumpGoBack, goForward: jumpGoForward },
    } as unknown as ReturnType<typeof useJumpListStore.getState>),
    spyOn(editorAPI, "getCursorPosition").mockReturnValue({ line: 0, column: 0, offset: 0 }),
    spyOn(editorAPI, "focus").mockImplementation(() => undefined),
    spyOn(editorAPI, "focusWhenReady").mockImplementation(() => undefined),
  );
});

afterEach(() => {
  for (const restorer of restorers.splice(0)) restorer.mockRestore();
  useWebViewerNavigationStore.getState().actions.unregisterNavigationActions(WEB_BUFFER_ID);
  for (const fn of [webGoBack, webGoForward, jumpGoBack, jumpGoForward]) fn.mockClear();
});

describe("navigation commands on a web viewer tab", () => {
  test("walk the page history while it has entries", async () => {
    setWebHistory(true, true);

    await goBack();
    await goForward();

    expect(webGoBack).toHaveBeenCalledTimes(1);
    expect(webGoForward).toHaveBeenCalledTimes(1);
    expect(jumpGoBack).not.toHaveBeenCalled();
    expect(jumpGoForward).not.toHaveBeenCalled();
  });

  test("fall back to the editor jump list at either end of the page history", async () => {
    setWebHistory(false, false);

    await goBack();
    await goForward();

    expect(webGoBack).not.toHaveBeenCalled();
    expect(webGoForward).not.toHaveBeenCalled();
    // The page has no editor cursor, so leaving it must not record a jump position.
    expect(jumpGoBack).toHaveBeenCalledWith(undefined);
    expect(jumpGoForward).toHaveBeenCalledTimes(1);
  });
});
