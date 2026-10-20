import { invoke } from "@/platform/tauri-core";
import type { WslPathInfo } from "./wsl-path";
import { parseWslPath, WSL_DEFAULT_AUTOMOUNT_ROOT } from "./wsl-path";

/**
 * Cache of `<distro>` to automount root.
 *
 * The value comes from the distribution's `/etc/wsl.conf`, which only changes
 * when the user edits it and restarts WSL, so reading it once per session is
 * enough. Path insertion happens on every paste and drop, and re-reading a UNC
 * path each time would put filesystem latency in that path.
 */
const automountRoots = new Map<string, string>();

/**
 * Resolve where the target distribution mounts Windows drives.
 *
 * Falls back to the WSL default whenever the host cannot answer, because a wrong
 * prefix is no worse than a missing one and must not block a paste that could
 * otherwise work.
 */
export async function resolveWslAutomountRoot(distro: string): Promise<string> {
  const cached = automountRoots.get(distro);
  if (cached !== undefined) return cached;

  try {
    const root = await invoke<string>("wsl_automount_root", { distro });
    const resolved = typeof root === "string" ? root : WSL_DEFAULT_AUTOMOUNT_ROOT;
    automountRoots.set(distro, resolved);
    return resolved;
  } catch (error) {
    // Do not cache a failure: a transient condition should not pin the default
    // for the rest of the session.
    console.error("Could not read the WSL automount root:", error);
    return WSL_DEFAULT_AUTOMOUNT_ROOT;
  }
}

/**
 * Resolve the automount root for the shell a terminal is running, or the default
 * when the shell is not a WSL distribution.
 *
 * `shell` is the session shell id. Only `wsl:<distro>` carries a distribution;
 * every other shell returns the default without touching the filesystem, because
 * the lookup reads a UNC path and would otherwise delay unrelated pastes.
 */
export async function resolveAutomountRootForShell(
  shell: string | null | undefined,
): Promise<string> {
  const value = (shell ?? "").trim();
  if (!value.toLowerCase().startsWith("wsl:")) return WSL_DEFAULT_AUTOMOUNT_ROOT;

  const info: WslPathInfo | null = parseWslPath(`wsl://${value.slice("wsl:".length)}/`);
  if (!info) return WSL_DEFAULT_AUTOMOUNT_ROOT;
  return resolveWslAutomountRoot(info.distro);
}

/** Exposed so a test can start from a known cache state. */
export function resetWslAutomountRootCache(): void {
  automountRoots.clear();
}
