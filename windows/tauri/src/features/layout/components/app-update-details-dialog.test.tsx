import { expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useUpdateStore } from "@/features/settings/stores/update.store";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as dialog from "@/ui/dialog";
import { AppUpdateDetailsDialog } from "./app-update-details-dialog";

// Issue #853: the details dialog is mounted once per window and follows the
// store, so a menu check can offer the install action without the title bar.
test("update details dialog follows the store and closes through it", async () => {
  const restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  const previousState = useUpdateStore.getState();
  const translator = createTranslator("en-US");
  const installLabel = translator("settings.general.installUpdate", { version: "0.12.0" });
  // The native dialog's portal/focus lifecycle is outside this store-driven regression.
  const frame = spyOn(dialog, "default").mockImplementation(({ children, footer, onClose }) => (
    <div>
      {children}
      {footer}
      <button type="button" onClick={onClose}>
        close-frame
      </button>
    </div>
  ));
  const container = document.createElement("div");
  let root: Root | undefined;

  useUpdateStore.setState({
    status: "available",
    error: null,
    errorCode: null,
    updateInfo: {
      currentVersion: "0.11.0",
      targetVersion: "0.12.0",
      releaseDate: "2026-09-01",
      releaseNotes: "Test update",
      releaseURL: "https://example.test/releases/v0.12.0",
    },
    downloadProgress: null,
    detailsOpen: false,
  });

  try {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;

    await act(async () => {
      mountedRoot.render(
        <LocaleProvider language="en-US">
          <AppUpdateDetailsDialog />
        </LocaleProvider>,
      );
    });
    expect(document.body.textContent).not.toContain(installLabel);

    await act(async () => useUpdateStore.getState().actions.openDetails());
    expect(document.body.textContent).toContain(installLabel);
    expect(document.body.textContent).toContain("Test update");

    const closeButton = Array.from(document.body.querySelectorAll("button")).find(
      (button) => button.textContent === "close-frame",
    );
    expect(closeButton).toBeDefined();
    await act(async () => closeButton?.click());
    expect(useUpdateStore.getState().detailsOpen).toBe(false);
    expect(document.body.textContent).not.toContain(installLabel);
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      frame.mockRestore();
      useUpdateStore.setState(previousState, true);
      if (previousActEnvironment === undefined) {
        delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
      } else {
        actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
      }
      restoreDom();
    }
  }
});


test("manual download dialog explains rolling risk and opens only through acknowledgement", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previous = useUpdateStore.getState();
  const open = mock(async (_acknowledged: boolean) => {});
  const frame = spyOn(dialog, "default").mockImplementation(({ children, footer }) => <div>{children}{footer}</div>);
  const container = document.createElement("div");
  const root = createRoot(container);
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    useUpdateStore.setState({
      channel: "autobuild", status: "manualDownload", detailsOpen: true,
      manualReleaseURL: "https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild",
      updateInfo: null, operationBusy: false,
      actions: { ...previous.actions, openReleaseDownload: open },
    });
    await act(async () => root.render(<LocaleProvider language="en-US"><AppUpdateDetailsDialog /></LocaleProvider>));
    expect(container.textContent).toContain("many bugs and unfinished features");
    expect(container.textContent).toContain(createTranslator("en-US")("update.manualDownloadExplanation"));
    expect(container.textContent).toContain("https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild");
    expect(open).not.toHaveBeenCalled();
    const acknowledge = Array.from(container.querySelectorAll("button")).find((button) => button.textContent === createTranslator("en-US")("update.acknowledgeDownload"));
    expect(acknowledge).toBeDefined();
    await act(async () => acknowledge?.click());
    expect(open).toHaveBeenCalledWith(true);
  } finally {
    try {
      await act(async () => root.unmount());
    } finally {
      useUpdateStore.setState(previous, true);
      frame.mockRestore();
      container.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});
