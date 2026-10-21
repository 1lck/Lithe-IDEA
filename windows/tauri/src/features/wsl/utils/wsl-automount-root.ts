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
 * The host read for each distribution, tracked to the end of its own lifetime.
 *
 * `automountRootReads` is keyed by distribution and removed only when the host
 * actually finishes, not when a caller stops waiting. A read that outlives one
 * caller's timeout therefore stays reusable: the next paste attaches to it
 * instead of starting another UNC read, and a late answer still reaches the
 * cache through `readAutomountRoot`.
 */
const automountRootReads = new Map<string, Promise<string>>();

/**
 * How long a caller waits for the host before using the default root.
 *
 * The lookup only refines where Windows drives are mounted. A distribution that
 * answers slowly must not hold the clipboard read behind it, so the wait is
 * bounded. This bounds the caller, not the read: the host call keeps running and
 * its answer is cached when it arrives, so a slow distribution converges to the
 * right root instead of falling back to `/mnt` on every paste.
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

  return waitForAutomountRoot(
    distro,
    options.timeoutMs ?? AUTOMOUNT_ROOT_TIMEOUT_MS,
  );
}

/**
 * Attach to the distribution's host read, bounded by `timeoutMs`.
 *
 * The read itself is created once per distribution and is deliberately not
 * awaited to completion here: when the caller's wait expires it returns the
 * default, while the read continues and stores its answer for the next caller.
 */
async function waitForAutomountRoot(distro: string, timeoutMs: number): Promise<string> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      readAutomountRoot(distro),
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(
          () => reject(new Error(`WSL automount root did not arrive within ${timeoutMs}ms`)),
          timeoutMs,
        );
      }),
    ]);
  } catch (error) {
    console.error("Could not read the WSL automount root:", error);
    return WSL_DEFAULT_AUTOMOUNT_ROOT;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/**
 * Start, or join, the host read for this distribution.
 *
 * The entry lives until the host answers or fails, so a second caller shares the
 * first read even after the first caller gave up waiting.
 */
function readAutomountRoot(distro: string): Promise<string> {
  const existing = automountRootReads.get(distro);
  if (existing) return existing;

  const read = invoke<string | null>("wsl_automount_root", { distro })
    .then((root) => {
      // The host answers `null` when it could not read the distribution's
      // wsl.conf at all. That is not knowledge worth remembering: caching it
      // would pin `/mnt` for the rest of the session even after the read starts
      // working again. A string — including the default — is a real answer.
      if (typeof root !== "string") {
        return WSL_DEFAULT_AUTOMOUNT_ROOT;
      }
      // The answer arrives even if every caller already returned the default,
      // which is what lets the next paste use the real root.
      automountRoots.set(distro, root);
      return root;
    })
    .catch((error: unknown) => {
      // Do not cache a failure: a transient condition should not pin the default
      // for the rest of the session.
      console.error("Could not read the WSL automount root:", error);
      return WSL_DEFAULT_AUTOMOUNT_ROOT;
    })
    .finally(() => {
      // Retire the entry only after the host is done. A caller that timed out
      // must not remove a read that is still in progress.
      if (automountRootReads.get(distro) === read) automountRootReads.delete(distro);
    });

  automountRootReads.set(distro, read);
  return read;
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
