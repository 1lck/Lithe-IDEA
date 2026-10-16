import { getServiceUrls } from "@/config/services";

export type UpdateChannel = "stable" | "autobuild";
export const UPDATE_CHANNEL_STORAGE_KEY = "lithe-update-channel";
const AUTOBUILD_RELEASE_URL = "https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild";

export function isUpdateChannel(value: unknown): value is UpdateChannel {
  return value === "stable" || value === "autobuild";
}

interface ChannelStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

function channelStorage(): ChannelStorage | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

export function readUpdateChannel(storage = channelStorage(), installed = getInstalledUpdateChannel()): UpdateChannel {
  try {
    const value = storage?.getItem(UPDATE_CHANNEL_STORAGE_KEY);
    return value == null ? installed : isUpdateChannel(value) ? value : "stable";
  } catch {
    return "stable";
  }
}

/** Failure is visible to the caller; a rolling choice must survive restart. */
export function persistUpdateChannel(channel: unknown, storage = channelStorage()): boolean {
  if (!isUpdateChannel(channel) || !storage) return false;
  try {
    storage.setItem(UPDATE_CHANNEL_STORAGE_KEY, channel);
    return true;
  } catch {
    return false;
  }
}

export function getInstalledUpdateChannel(): UpdateChannel {
  // Build identity is independent of the saved update preference and display version.
  return import.meta.env.VITE_UPDATE_CHANNEL === "autobuild" ? "autobuild" : "stable";
}

export function getInstalledBuildTimestamp(): string | undefined {
  return import.meta.env.VITE_BUILD_TIMESTAMP;
}

/** Accept only real, whole-second UTC ISO timestamps from the publisher. */
export function formatBuildTimestamp(timestamp: string | undefined): string | null {
  if (!timestamp || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(timestamp)) return null;
  const parsed = new Date(timestamp);
  // Date parsing normalizes some impossible dates and 24:00; reject those too.
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString() !== timestamp.replace("Z", ".000Z")) {
    return null;
  }
  return `${timestamp.slice(0, 10)} ${timestamp.slice(11, 19)} UTC`;
}

export function getInstalledVersionLabel(
  version: string,
  translate: (key: string, values?: Record<string, string | number>) => string,
  installedChannel: UpdateChannel = getInstalledUpdateChannel(),
  timestamp: string | undefined = getInstalledBuildTimestamp(),
): string {
  if (installedChannel === "stable") return version;
  const displayTime = formatBuildTimestamp(timestamp);
  return displayTime ? translate("update.autobuildBuiltAt", { timestamp: displayTime }) : "AutoBuild";
}

export function resolveUpdateChannel(
  channel: UpdateChannel,
  installedChannel: UpdateChannel = getInstalledUpdateChannel(),
) {
  const releaseURL = channel === "autobuild"
    ? AUTOBUILD_RELEASE_URL
    : `${getServiceUrls().githubReleasesBaseUrl}/latest`;
  return {
    releaseURL,
    // Rolling assets have no Tauri manifest/signature or monotonic version today.
    // Cross-channel transitions also require an explicit installer choice.
    method: channel === "autobuild" || installedChannel !== channel
      ? "release-page" as const
      : "tauri" as const,
  };
}
