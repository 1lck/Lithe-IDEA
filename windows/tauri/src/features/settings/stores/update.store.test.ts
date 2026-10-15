import { afterEach, expect, mock, spyOn, test } from "bun:test";
import type { Update } from "@tauri-apps/plugin-updater";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as externalNavigation from "@/features/window/utils/external-navigation";
import * as projectTransition from "@/features/file-system/controllers/workspace-project-transition";
import { readUpdateChannel } from "../lib/update-channel";
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
    expect(useUpdateStore.getState()).toMatchObject({ status: "idle", detailsOpen: false });

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

// A failed request must never produce the reassuring app-version notification.
test("a failed check remains failed rather than up to date", async () => {
  check.mockImplementationOnce(async () => { throw new Error("connection failed"); });
  expect(await useUpdateStore.getState().actions.checkForUpdates({ userInitiated: true })).toBe("failed");
  expect(useUpdateStore.getState()).toMatchObject({ status: "failed", error: "connection failed" });
});


test("rolling selection requires acknowledgement and clears the previous stable result", async () => {
  const restoreDom = installHappyDom();
  try {
    const { actions } = useUpdateStore.getState();
    await actions.checkForUpdates({ userInitiated: true });
    expect(actions.setChannel("autobuild")).toBe(false);
    expect(actions.setChannel("preview", true)).toBe(false);
    expect(useUpdateStore.getState().channel).toBe("stable");
    expect(actions.setChannel("autobuild", true)).toBe(true);
    expect(readUpdateChannel()).toBe("autobuild");
    expect(useUpdateStore.getState()).toMatchObject({
      channel: "autobuild", status: "idle", updateInfo: null, detailsOpen: false,
    });
    expect(await actions.checkForUpdates({ userInitiated: true })).toBe("manual-download");
    expect(check).toHaveBeenCalledTimes(1);
    expect(useUpdateStore.getState()).toMatchObject({
      status: "manualDownload", detailsOpen: true, updateInfo: null,
      manualReleaseURL: "https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild",
    });
    await actions.downloadAndInstall();
    expect(useUpdateStore.getState().status).toBe("manualDownload");
    expect(actions.setChannel("stable")).toBe(true);
    expect(useUpdateStore.getState().manualReleaseURL).toBeNull();
    expect(readUpdateChannel()).toBe("stable");
  } finally {
    restoreDom();
  }
});

test("checks coalesce and prevent channel changes or installs until the result terminates", async () => {
  const restoreDom = installHappyDom();
  const deferred = Promise.withResolvers<Update | null>();
  check.mockImplementationOnce(() => deferred.promise);
  const { actions } = useUpdateStore.getState();
  const scheduled = actions.checkForUpdates();
  const manual = actions.checkForUpdates({ userInitiated: true });
  try {
    expect(actions.setChannel("autobuild", true)).toBe(false);
    actions.dismissUpdate();
    expect(useUpdateStore.getState().status).toBe("checking");
    await actions.downloadAndInstall();
    expect(useUpdateStore.getState().status).toBe("checking");
    deferred.resolve(availableUpdate);
    expect(await scheduled).toBe("available");
    expect(await manual).toBe("available");
    expect(check).toHaveBeenCalledTimes(1);
    expect(useUpdateStore.getState().detailsOpen).toBe(true);
    expect(actions.setChannel("autobuild", true)).toBe(true);
    expect(useUpdateStore.getState().updateInfo).toBeNull();
  } finally {
    deferred.resolve(null);
    await Promise.all([scheduled, manual]);
    restoreDom();
  }
});

test("manual downloads require acknowledgement, coalesce browser opens and retain retry after failure", async () => {
  const restoreDom = installHappyDom();
  const deferred = Promise.withResolvers<boolean>();
  const open = spyOn(externalNavigation, "openExternalBrowserUrl").mockImplementation(() => deferred.promise);
  const { actions } = useUpdateStore.getState();
  let opening: Promise<void> | undefined;
  try {
    expect(actions.setChannel("autobuild", true)).toBe(true);
    await actions.checkForUpdates({ userInitiated: true });
    await actions.openReleaseDownload(false);
    expect(open).not.toHaveBeenCalled();
    opening = actions.openReleaseDownload(true);
    await actions.openReleaseDownload(true);
    expect(open).toHaveBeenCalledTimes(1);
    expect(open).toHaveBeenCalledWith("https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild");
    expect(actions.setChannel("stable")).toBe(false);
    expect(await actions.checkForUpdates()).toBe("busy");
    deferred.reject(new Error("browser unavailable"));
    await opening;
    expect(useUpdateStore.getState()).toMatchObject({
      status: "manualDownload", operationBusy: false, detailsOpen: true, error: "browser unavailable",
    });
    open.mockResolvedValueOnce(true);
    await actions.openReleaseDownload(true);
    expect(useUpdateStore.getState()).toMatchObject({ detailsOpen: false, error: null });
    expect(actions.setChannel("stable")).toBe(true);
    await actions.openReleaseDownload(true);
    expect(open).toHaveBeenCalledTimes(2);
    expect(check).not.toHaveBeenCalled();
  } finally {
    deferred.resolve(false);
    await opening;
    open.mockRestore();
    restoreDom();
  }
});

test("install preparation blocks duplicate installs, rechecks and channel changes before download", async () => {
  const restoreDom = installHappyDom();
  const deferred = Promise.withResolvers<boolean>();
  const prepare = spyOn(projectTransition, "prepareProjectTransitionWithUnsavedBuffers")
    .mockImplementation(() => deferred.promise);
  const { actions } = useUpdateStore.getState();
  let installing: Promise<void> | undefined;
  try {
    await actions.checkForUpdates();
    installing = actions.downloadAndInstall();
    await actions.downloadAndInstall();
    expect(prepare).toHaveBeenCalledTimes(1);
    expect(useUpdateStore.getState().operationBusy).toBe(true);
    expect(actions.setChannel("autobuild", true)).toBe(false);
    expect(await actions.checkForUpdates()).toBe("busy");
    deferred.resolve(false);
    await installing;
    expect(useUpdateStore.getState()).toMatchObject({ status: "available", operationBusy: false });
    expect(actions.setChannel("autobuild", true)).toBe(true);
  } finally {
    deferred.resolve(false);
    await installing;
    prepare.mockRestore();
    restoreDom();
  }
});


test("changing channel releases a checked stable update resource and prevents stale installation", async () => {
  const restoreDom = installHappyDom();
  const close = mock(async () => {});
  const download = mock(async () => {});
  check.mockResolvedValueOnce({ ...availableUpdate, close, downloadAndInstall: download } as unknown as Update);
  try {
    const { actions } = useUpdateStore.getState();
    await actions.checkForUpdates();
    expect(actions.setChannel("autobuild", true)).toBe(true);
    expect(close).toHaveBeenCalledTimes(1);
    await actions.downloadAndInstall();
    expect(download).not.toHaveBeenCalled();
    expect(useUpdateStore.getState()).toMatchObject({ channel: "autobuild", updateInfo: null });
  } finally {
    restoreDom();
  }
});
