import { expect, spyOn, test } from "bun:test";
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
