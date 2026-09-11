import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { create } from "zustand";
import { getServiceUrls } from "@/config/services";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { prepareProjectTransitionWithUnsavedBuffers } from "@/features/file-system/controllers/workspace-project-transition";
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
  status: UpdateStatus;
  error: string | null;
  errorCode: UpdateErrorCode | null;
  updateInfo: UpdateInfo | null;
  downloadProgress: DownloadProgress | null;
}

interface CheckForUpdatesOptions {
  ignoreSuppression?: boolean;
}

export type UpdateCheckResult = "available" | "up-to-date" | "suppressed" | "failed";

interface UpdateActions {
  checkForUpdates: (options?: CheckForUpdatesOptions) => Promise<UpdateCheckResult>;
  downloadAndInstall: () => Promise<void>;
  dismissUpdate: () => void;
  downloadLater: () => void;
  remindLater: (delayMs?: number) => void;
  skipVersion: () => void;
  viewReleaseNotes: () => void;
}

interface UpdateStore extends UpdateState {
  actions: UpdateActions;
}

let updateRef: Update | null = null;
let updateInfoRef: UpdateInfo | null = null;
let checkInFlight: Promise<UpdateCheckResult> | null = null;

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
  status: "idle",
  error: null,
  errorCode: null,
  updateInfo: null,
  downloadProgress: null,

  actions: {
    checkForUpdates: async (options = {}) => {
      if (checkInFlight) return checkInFlight;

      checkInFlight = (async () => {
        updateRef = null;
        updateInfoRef = null;
        set({
          status: "checking",
          error: null,
          errorCode: null,
          updateInfo: null,
          downloadProgress: null,
        });

        try {
          const update = await check();
          updateRef = update;

          if (!update?.available) {
            updateRef = null;
            updateInfoRef = null;
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
            shouldSuppressUpdate({ version: updateInfo.targetVersion })
          ) {
            updateRef = null;
            updateInfoRef = null;
            set({
              status: "upToDate",
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
      try {
        if (!updateRef?.available) {
          const result = await get().actions.checkForUpdates({ ignoreSuppression: true });
          if (result !== "available" || !updateRef?.available) {
            throw new Error("No update available");
          }
        }

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
      }
    },

    dismissUpdate: () => {
      updateRef = null;
      updateInfoRef = null;
      set({
        status: "idle",
        error: null,
        errorCode: null,
        updateInfo: null,
        downloadProgress: null,
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
  },
}));

export { useUpdateStore };
