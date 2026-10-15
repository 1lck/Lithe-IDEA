import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { create } from "zustand";
import { getServiceUrls } from "@/config/services";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { prepareProjectTransitionWithUnsavedBuffers } from "@/features/file-system/controllers/workspace-project-transition";
import { openExternalBrowserUrl } from "@/features/window/utils/external-navigation";
import {
  isUpdateChannel,
  persistUpdateChannel,
  readUpdateChannel,
  resolveUpdateChannel,
  type UpdateChannel,
} from "../lib/update-channel";
import { useWhatsNewStore } from "./whats-new.store";
import {
  clearUpdatePreferencesForNewVersion,
  notifyUpdateDismissed,
  remindAboutUpdateLater,
  shouldSuppressUpdate,
  skipUpdateVersion,
} from "../lib/update-preferences";

export type UpdateStatus =
  | "idle"
  | "checking"
  | "manualDownload"
  | "available"
  | "downloading"
  | "installing"
  | "upToDate"
  | "failed";

export type UpdateErrorCode =
  | "no_published_release"
  | "invalid_response"
  | "rate_limited"
  | "http_status"
  | "timed_out"
  | "tls_or_proxy_failure"
  | "connection_failed"
  | "invalid_manifest"
  | "unsupported_schema"
  | "no_compatible_asset"
  | "checksum_mismatch"
  | "download_failed"
  | "install_failed"
  | "not_app_bundle"
  | "app_not_found_in_disk_image";

export interface UpdateInfo {
  currentVersion: string;
  targetVersion: string;
  releaseDate: string | null;
  releaseNotes: string | null;
  releaseURL: string;
}

export interface DownloadProgress {
  contentLength: number;
  downloaded: number;
  percentage: number;
}

export interface UpdateState {
  channel: UpdateChannel;
  channelPreferenceError: boolean;
  operationBusy: boolean;
  manualReleaseURL: string | null;
  status: UpdateStatus;
  error: string | null;
  errorCode: UpdateErrorCode | null;
  updateInfo: UpdateInfo | null;
  downloadProgress: DownloadProgress | null;
  /** Whether the update details dialog is open; one dialog serves every trigger. */
  detailsOpen: boolean;
}

interface CheckForUpdatesOptions {
  ignoreSuppression?: boolean;
  /**
   * A person asked for this check from a menu or button. Remind-later and
   * skipped-version preferences do not hide the result, and an available
   * update opens its details so it can be installed from there.
   */
  userInitiated?: boolean;
}

export type UpdateCheckResult = "available" | "up-to-date" | "suppressed" | "failed" | "manual-download" | "busy";

interface UpdateActions {
  setChannel: (channel: unknown, acknowledged?: boolean) => boolean;
  openReleaseDownload: (acknowledged: boolean) => Promise<void>;
  checkForUpdates: (options?: CheckForUpdatesOptions) => Promise<UpdateCheckResult>;
  downloadAndInstall: () => Promise<void>;
  dismissUpdate: () => void;
  downloadLater: () => void;
  remindLater: (delayMs?: number) => void;
  skipVersion: () => void;
  viewReleaseNotes: () => void;
  openDetails: () => void;
  closeDetails: () => void;
}

interface UpdateStore extends UpdateState {
  actions: UpdateActions;
}

let updateRef: Update | null = null;
let updateInfoRef: UpdateInfo | null = null;
let checkInFlight: Promise<UpdateCheckResult> | null = null;
let installInFlight = false;
let manualOpenInFlight = false;

function clearUpdateReference() {
  const discarded = updateRef;
  updateRef = null;
  updateInfoRef = null;
  // Each Tauri Update owns a native resource; channel changes must release it.
  if (discarded && typeof discarded.close === "function") {
    void discarded.close().catch((error) => console.warn("Failed to close update resource", error));
  }
}

function isBusy(state: UpdateState) {
  return state.operationBusy || state.status === "checking" ||
    state.status === "downloading" || state.status === "installing";
}

function readRawUpdateText(update: Update, key: string): string | undefined {
  const value = update.rawJson?.[key];
  return typeof value === "string" && value.trim() ? value : undefined;
}

function toUpdateInfo(update: Update): UpdateInfo {
  const services = getServiceUrls();
  return {
    currentVersion: update.currentVersion,
    targetVersion: update.version,
    releaseDate: update.date || readRawUpdateText(update, "pub_date") || null,
    releaseNotes: update.body || readRawUpdateText(update, "notes") || null,
    releaseURL: `${services.githubReleasesBaseUrl}/tag/v${update.version}`,
  };
}

function errorCodeForPhase(phase: "check" | "install", error: unknown): UpdateErrorCode {
  const message =
    error instanceof Error ? error.message.toLowerCase() : String(error).toLowerCase();
  if (message.includes("rate limit")) return "rate_limited";
  if (message.includes("timeout")) return "timed_out";
  if (message.includes("certificate") || message.includes("tls")) return "tls_or_proxy_failure";
  if (message.includes("http") && /\b\d{3}\b/.test(message)) return "http_status";
  return phase === "check" ? "connection_failed" : "install_failed";
}

function errorMessageForPhase(phase: "check" | "install", error: unknown): string {
  if (error instanceof Error && error.message.trim()) return error.message;
  return phase === "check" ? "Failed to check for updates" : "Failed to install update";
}

const useUpdateStore = create<UpdateStore>()((set, get) => ({
  channel: readUpdateChannel(),
  channelPreferenceError: false,
  operationBusy: false,
  manualReleaseURL: null,
  status: "idle",
  error: null,
  errorCode: null,
  updateInfo: null,
  downloadProgress: null,
  detailsOpen: false,

  actions: {
    setChannel: (channel, acknowledged = false) => {
      if (!isUpdateChannel(channel) || isBusy(get())) return false;
      if (channel === get().channel) return true;
      if (channel === "autobuild" && !acknowledged) return false;
      if (!persistUpdateChannel(channel)) {
        set({ channelPreferenceError: true });
        return false;
      }
      get().actions.dismissUpdate();
      set({ channel, channelPreferenceError: false });
      return true;
    },

    openReleaseDownload: async (acknowledged) => {
      const { channel, manualReleaseURL } = get();
      if (!acknowledged || !manualReleaseURL || isBusy(get()) || manualOpenInFlight) return;
      // Re-resolve rather than trusting an old dialog after a channel change.
      if (resolveUpdateChannel(channel).releaseURL !== manualReleaseURL) return;
      manualOpenInFlight = true;
      set({ operationBusy: true, error: null, errorCode: null });
      try {
        if (!await openExternalBrowserUrl(manualReleaseURL)) throw new Error("Could not open release downloads");
        set({ detailsOpen: false });
      } catch (error) {
        set({ error: errorMessageForPhase("install", error), errorCode: "download_failed" });
      } finally {
        manualOpenInFlight = false;
        set({ operationBusy: false });
      }
    },
    checkForUpdates: async (options = {}) => {
      if (checkInFlight) {
        const result = await checkInFlight;
        if (options.userInitiated && result === "available") get().actions.openDetails();
        return result;
      }
      if (isBusy(get()) || installInFlight) return "busy";
      const route = resolveUpdateChannel(get().channel);
      if (route.method === "release-page") {
        clearUpdateReference();
        set({
          status: "manualDownload", manualReleaseURL: route.releaseURL,
          updateInfo: null, downloadProgress: null, error: null, errorCode: null,
          detailsOpen: Boolean(options.userInitiated || get().detailsOpen),
        });
        return "manual-download";
      }

      checkInFlight = (async () => {
        clearUpdateReference();
        set({
          status: "checking",
          manualReleaseURL: null,
          error: null,
          errorCode: null,
          updateInfo: null,
          downloadProgress: null,
          detailsOpen: false,
        });

        try {
          const update = await check({ timeout: 15_000 });
          updateRef = update;

          if (!update?.available) {
            clearUpdateReference();
            set({
              status: "upToDate",
              error: null,
              errorCode: null,
              updateInfo: null,
              downloadProgress: null,
            });
            return "up-to-date";
          }

          const updateInfo = toUpdateInfo(update);
          clearUpdatePreferencesForNewVersion({ version: updateInfo.targetVersion });

          if (
            !options.ignoreSuppression &&
            !options.userInitiated &&
            shouldSuppressUpdate({ version: updateInfo.targetVersion })
          ) {
            clearUpdateReference();
            set({
              status: "idle",
              error: null,
              errorCode: null,
              updateInfo: null,
              downloadProgress: null,
            });
            return "suppressed";
          }

          updateInfoRef = updateInfo;
          set({
            status: "available",
            error: null,
            errorCode: null,
            updateInfo,
            downloadProgress: null,
            detailsOpen: Boolean(options.userInitiated),
          });
          return "available";
        } catch (error) {
          updateRef = null;
          updateInfoRef = null;
          set({
            status: "failed",
            error: errorMessageForPhase("check", error),
            errorCode: errorCodeForPhase("check", error),
            updateInfo: null,
            downloadProgress: null,
          });
          return "failed";
        } finally {
          checkInFlight = null;
        }
      })();

      return checkInFlight;
    },

    downloadAndInstall: async () => {
      if (installInFlight || isBusy(get()) || resolveUpdateChannel(get().channel).method !== "tauri") return;
      // Lock before the first await, including the unsaved-buffer prompt.
      installInFlight = true;
      try {
        if (!updateRef?.available) throw new Error("No update available");
        set({ operationBusy: true });

        const update = updateRef;
        const updateInfo = updateInfoRef;
        if (!update || !updateInfo) {
          throw new Error("No update available");
        }

        const canRestart = await prepareProjectTransitionWithUnsavedBuffers(
          "restarting to update",
          useBufferStore.getState().buffers,
        );
        if (!canRestart) return;

        set({
          status: "downloading",
          error: null,
          errorCode: null,
          downloadProgress: { contentLength: 0, downloaded: 0, percentage: 0 },
          detailsOpen: false,
        });

        let contentLength = 0;
        let downloaded = 0;
        await update.downloadAndInstall((event) => {
          switch (event.event) {
            case "Started":
              contentLength = event.data.contentLength ?? 0;
              set({
                status: "downloading",
                downloadProgress: { contentLength, downloaded: 0, percentage: 0 },
              });
              break;
            case "Progress": {
              downloaded += event.data.chunkLength;
              const percentage =
                contentLength > 0 ? Math.round((downloaded / contentLength) * 100) : 0;
              set({
                status: "downloading",
                downloadProgress: { contentLength, downloaded, percentage },
              });
              break;
            }
            case "Finished":
              set({
                status: "installing",
                downloadProgress: { contentLength, downloaded: contentLength, percentage: 100 },
              });
              break;
          }
        });

        useWhatsNewStore.getState().actions.queuePendingUpdate(updateInfo);
        await relaunch();
      } catch (error) {
        set((state) => ({
          status: "failed",
          error: errorMessageForPhase("install", error),
          errorCode:
            error instanceof Error && error.message === "No update available"
              ? "no_published_release"
              : errorCodeForPhase("install", error),
          updateInfo: state.updateInfo,
          downloadProgress: null,
        }));
      } finally {
        installInFlight = false;
        set({ operationBusy: false });
      }
    },

    dismissUpdate: () => {
      if (isBusy(get())) return;
      clearUpdateReference();
      set({
        status: "idle",
        manualReleaseURL: null,
        error: null,
        errorCode: null,
        updateInfo: null,
        downloadProgress: null,
        detailsOpen: false,
      });
    },

    downloadLater: () => {
      const updateInfo = updateInfoRef;
      if (updateInfo) {
        remindAboutUpdateLater({ version: updateInfo.targetVersion });
      }
      get().actions.dismissUpdate();
      notifyUpdateDismissed();
    },

    remindLater: (delayMs) => {
      const updateInfo = updateInfoRef;
      if (!updateInfo) return;
      remindAboutUpdateLater({ version: updateInfo.targetVersion }, Date.now(), delayMs);
      get().actions.dismissUpdate();
    },

    skipVersion: () => {
      const updateInfo = updateInfoRef;
      if (!updateInfo) return;
      skipUpdateVersion({ version: updateInfo.targetVersion });
      get().actions.dismissUpdate();
    },

    viewReleaseNotes: () => {
      const updateInfo = updateInfoRef;
      if (!updateInfo) return;
      void useWhatsNewStore.getState().actions.openInfo({
        version: updateInfo.targetVersion,
        previousVersion: updateInfo.currentVersion,
        body: updateInfo.releaseNotes ?? undefined,
        date: updateInfo.releaseDate ?? undefined,
      });
    },

    openDetails: () => {
      if (get().updateInfo || get().manualReleaseURL) set({ detailsOpen: true });
    },

    closeDetails: () => set({ detailsOpen: false }),
  },
}));

export { useUpdateStore };
