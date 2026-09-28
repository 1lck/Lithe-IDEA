import { afterEach, expect, mock, test } from "bun:test";
import type { Update } from "@tauri-apps/plugin-updater";
import { installHappyDom } from "@/test-utils/happy-dom";
import { skipUpdateVersion } from "../lib/update-preferences";

const availableUpdate = {
  available: true,
  currentVersion: "0.5.4",
  version: "0.6.0",
  date: "2026-09-26",
  body: "Release notes",
  rawJson: {},
} as unknown as Update;

const check = mock(async (): Promise<Update | null> => availableUpdate);
mock.module("@tauri-apps/plugin-updater", () => ({ check }));

const { useUpdateStore } = await import("./update.store");
const initialState = useUpdateStore.getState();

afterEach(() => {
  check.mockClear();
  useUpdateStore.setState(initialState, true);
});

// Issue #853: an update found by a menu or button check is shown with its
// install action instead of only changing the title bar indicator.
test("a user-initiated check that finds an update opens its details", async () => {
  const { actions } = useUpdateStore.getState();

  expect(await actions.checkForUpdates({ userInitiated: true })).toBe("available");
  expect(useUpdateStore.getState().detailsOpen).toBe(true);

  actions.closeDetails();
  expect(useUpdateStore.getState().detailsOpen).toBe(false);
  actions.openDetails();
  expect(useUpdateStore.getState().detailsOpen).toBe(true);

  actions.remindLater();
  expect(useUpdateStore.getState()).toMatchObject({ status: "idle", detailsOpen: false });
});

test("a scheduled check only reports the update", async () => {
  const { actions } = useUpdateStore.getState();

  expect(await actions.checkForUpdates()).toBe("available");
  expect(useUpdateStore.getState()).toMatchObject({ status: "available", detailsOpen: false });
});

test("a user-initiated check shows a skipped version that a scheduled check hides", async () => {
  const restoreDom = installHappyDom();
  try {
    skipUpdateVersion({ version: availableUpdate.version });
    const { actions } = useUpdateStore.getState();

    expect(await actions.checkForUpdates()).toBe("suppressed");
    expect(useUpdateStore.getState().detailsOpen).toBe(false);

    expect(await actions.checkForUpdates({ userInitiated: true })).toBe("available");
    expect(useUpdateStore.getState().detailsOpen).toBe(true);
  } finally {
    restoreDom();
  }
});

test("details cannot open without an update and close when a new check starts", async () => {
  const { actions } = useUpdateStore.getState();
  actions.openDetails();
  expect(useUpdateStore.getState().detailsOpen).toBe(false);

  await actions.checkForUpdates({ userInitiated: true });
  check.mockImplementationOnce(async () => null);
  expect(await actions.checkForUpdates()).toBe("up-to-date");
  expect(useUpdateStore.getState()).toMatchObject({ status: "upToDate", detailsOpen: false });
});
