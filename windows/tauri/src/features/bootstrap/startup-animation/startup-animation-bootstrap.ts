/**
 * First-frame cache for the startup animation switch.
 *
 * The settings live in the Tauri store, which is loaded asynchronously. The
 * startup animation has to decide during the first frame whether it shows at
 * all, so the resolved switch is mirrored into `localStorage`, the same way
 * `appearance-bootstrap.ts` mirrors the resolved theme.
 */
export const STARTUP_ANIMATION_BOOTSTRAP_CACHE_KEY = "lithe.bootstrap.startup.v1";

export interface StartupAnimationBootstrapCache {
  version: 1;
  showStartupAnimation: boolean;
}

export const DEFAULT_STARTUP_ANIMATION_BOOTSTRAP_CACHE: StartupAnimationBootstrapCache = {
  version: 1,
  showStartupAnimation: true,
};

export function readStartupAnimationBootstrapCache(): StartupAnimationBootstrapCache | null {
  if (typeof window === "undefined") return null;

  try {
    const raw = window.localStorage.getItem(STARTUP_ANIMATION_BOOTSTRAP_CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<StartupAnimationBootstrapCache> | null;
    if (!parsed || parsed.version !== 1) return null;
    if (typeof parsed.showStartupAnimation !== "boolean") return null;
    return {
      version: 1,
      showStartupAnimation: parsed.showStartupAnimation,
    };
  } catch {
    return null;
  }
}

export function writeStartupAnimationBootstrapCache(
  cache: StartupAnimationBootstrapCache,
): void {
  if (typeof window === "undefined") return;

  try {
    window.localStorage.setItem(
      STARTUP_ANIMATION_BOOTSTRAP_CACHE_KEY,
      JSON.stringify(cache),
    );
  } catch {
    // Ignore localStorage failures (private mode, quota limits, etc.)
  }
}

/**
 * Resolves the switch for the current frame. Without a cache the product
 * default applies, so the animation is enabled on a fresh installation.
 */
export function resolveStartupAnimationEnabled(): boolean {
  return (
    readStartupAnimationBootstrapCache() ?? DEFAULT_STARTUP_ANIMATION_BOOTSTRAP_CACHE
  ).showStartupAnimation;
}
