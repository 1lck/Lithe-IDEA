import { expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useUpdateStore } from "@/features/settings/stores/update.store";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { TitleBarUpdateControl } from "../../window/components/title-bar/title-bar";

test("Windows title bar update control is only rendered for the workbench", async () => {
  const restoreDom = installHappyDom();
  const actEnvironment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousActEnvironment = actEnvironment.IS_REACT_ACT_ENVIRONMENT;
  const previousState = useUpdateStore.getState();
  const translator = createTranslator("en-US");
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
  });

  try {
    actEnvironment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;

    await act(async () => {
      mountedRoot.render(
        <LocaleProvider language="en-US">
          <TitleBarUpdateControl visible={false} />
        </LocaleProvider>,
      );
    });
    expect(container.textContent).not.toContain(translator("update.available"));

    await act(async () => {
      mountedRoot.render(
        <LocaleProvider language="en-US">
          <TitleBarUpdateControl visible />
        </LocaleProvider>,
      );
    });
    expect(container.textContent).toContain(translator("update.available"));
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      useUpdateStore.setState(previousState);
      if (previousActEnvironment === undefined) {
        delete actEnvironment.IS_REACT_ACT_ENVIRONMENT;
      } else {
        actEnvironment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
      }
      restoreDom();
    }
  }
});
