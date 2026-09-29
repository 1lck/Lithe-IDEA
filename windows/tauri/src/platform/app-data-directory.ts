import { appDataDir } from "@tauri-apps/api/path";

/**
 * Platform-owned writable data root for Lithe-managed runtime state.
 *
 * Adapter installs and other runtime files must never be derived from the
 * install directory: writing there breaks the release baseline and Sparkle
 * differential updates. Every feature asks here instead.
 */
export async function resolveAppDataDirectory(): Promise<string> {
  return (await appDataDir()).replace(/[\\/]+$/, "");
}
