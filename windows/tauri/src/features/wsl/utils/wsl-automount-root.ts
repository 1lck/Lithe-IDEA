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
 * Queries still waiting for the host, so concurrent pastes share one read.
 *
 * The host reads a UNC path, and a distribution that is not running can hold
 * that read for seconds. Sharing the in-flight query keeps a burst of pastes
 * from stacking up one filesystem read each.
 */
const automountRootReads = new Map<string, Promise<string>>();

/**
 * How long a paste waits for the host before using the default root.
 *
 * The lookup only refines where Windows drives are mounted. A distribution that
 * answers slowly must not hold the clipboard read behind it, so the wait is
 * bounded and the default is used; the correct value still arrives for the next
 * paste through the cache.
 */
const AUTOMOUNT_ROOT_TIMEOUT_MS = 2_000;

export interface WslAutomountRootOptions {
  /** Override for the bounded wait, in milliseconds. */
  timeoutMs?: number;
}

/**
 * Resolve where the target distribution mounts Windows drives.
 *
 * Falls back to the WSL default whenever the host cannot answer in time or at
 * all, because a wrong prefix is no worse than a missing one and must not block
 * a paste that could otherwise work.
 */
export function resolveWslAutomountRoot(
  distro: string,
  options: WslAutomountRootOptions = {},
): Promise<string> {
  const cached = automountRoots.get(distro);
  if (cached !== undefined) return Promise.resolve(cached);

  const inFlight = automountRootReads.get(distro);
  if (inFlight) return inFlight;

  const read = readAutomountRoot(distro, options.timeoutMs ?? AUTOMOUNT_ROOT_TIMEOUT_MS).finally(
    () => {
      automountRootReads.delete(distro);
    },
  );
  automountRootReads.set(distro, read);
  return read;
}

async function readAutomountRoot(distro: string, timeoutMs: number): Promise<string> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const root = await Promise.race([
      invoke<string>("wsl_automount_root", { distro }),
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(
          () => reject(new Error(`WSL automount root did not arrive within ${timeoutMs}ms`)),
          timeoutMs,
        );
      }),
    ]);
    const resolved = typeof root === "string" ? root : WSL_DEFAULT_AUTOMOUNT_ROOT;
    automountRoots.set(distro, resolved);
    return resolved;
  } catch (error) {
    // Do not cache a failure: a transient condition or a late answer should not
    // pin the default for the rest of the session.
    console.error("Could not read the WSL automount root:", error);
    return WSL_DEFAULT_AUTOMOUNT_ROOT;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/**
 * True when translating these paths needs to know where the distribution mounts
 * Windows drives.
 *
 * Only a Windows drive path is placed under the automount root. Paths already in
 * Linux form, protocol paths, and relative names are translated without it, so
 * an ordinary paste never waits for a UNC read.
 */
export function automountRootNeededForPaths(paths: readonly string[]): boolean {
  return paths.some((path) => /^[A-Za-z]:[\\/]/.test(path));
}

/**
 * Resolve the automount root for the shell a terminal is running, or the default
 * when the shell is not a WSL distribution.
 *
 * `shell` is the session shell id. Only `wsl:<distro>` carries a distribution;
 * every other shell returns the default without touching the filesystem, because
 * the lookup reads a UNC path and would otherwise delay unrelated pastes.
 */
export function resolveAutomountRootForShell(shell: string | null | undefined): Promise<string> {
  const distro = wslDistroForShell(shell);
  return distro ? resolveWslAutomountRoot(distro) : Promise.resolve(WSL_DEFAULT_AUTOMOUNT_ROOT);
}

/**
 * Resolve the automount root only when these paths actually need it.
 *
 * This is what insertion and paste call: the host read is skipped entirely unless
 * a Windows drive path has to be mapped into the distribution.
 */
export function resolveAutomountRootForPaths(
  shell: string | null | undefined,
  paths: readonly string[],
): Promise<string> {
  if (!automountRootNeededForPaths(paths)) return Promise.resolve(WSL_DEFAULT_AUTOMOUNT_ROOT);
  return resolveAutomountRootForShell(shell);
}

function wslDistroForShell(shell: string | null | undefined): string | null {
  const value = (shell ?? "").trim();
  if (!value.toLowerCase().startsWith("wsl:")) return null;
  const info: WslPathInfo | null = parseWslPath(`wsl://${value.slice("wsl:".length)}/`);
  return info ? info.distro : null;
}

/** Exposed so a test can start from a known cache state. */
export function resetWslAutomountRootCache(): void {
  automountRoots.clear();
  automountRootReads.clear();
}
