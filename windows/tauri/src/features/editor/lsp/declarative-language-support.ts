import {
  pluginPlanGuard,
  subscribePluginActivity,
} from "@/features/plugins/declarative-plugin-lifecycle";
import { extensionRegistry } from "@/extensions/registry/extension-registry";

interface DeclarativeLanguageOwner {
  pluginId: string;
  languageId: string;
  displayName: string;
}

/** Execution follows the existing Worker-first migration rule per capability.
 * A Worker language with run actions must not get duplicate contract actions. */
export async function probeDeclarativeExecutionOwner(
  filePath: string,
): Promise<DeclarativeLanguageOwner | null> {
  if (extensionRegistry.getExtensionForFilePath(filePath)?.manifest.runActions) return null;
  const owner = await probeDeclarativeLanguageOwner(filePath);
  return extensionRegistry.getExtensionForFilePath(filePath)?.manifest.runActions ? null : owner;
}

interface CachedOwner {
  owner: DeclarativeLanguageOwner;
  assertCurrent: (pluginId: string) => void;
}

// These are native ownership hints for editor admission, not a second
// manifest matcher. The actual launch still rechecks the trusted live package.
const owners = new Map<string, CachedOwner>();
const pending = new Map<string, Promise<DeclarativeLanguageOwner | null>>();
const listeners = new Set<() => void>();
let revision = 0;
let unsubscribeActivity: (() => void) | null = null;

function publishChange(): void {
  revision += 1;
  for (const listener of listeners) listener();
}

export function declarativeLanguageSupportRevision(): number {
  return revision;
}

export function subscribeDeclarativeLanguageSupport(listener: () => void): () => void {
  listeners.add(listener);
  if (!unsubscribeActivity) {
    // Revocation may have happened while every editor was unmounted. Do
    // not reuse an old lookup whose rejected answer cannot wake this editor.
    pending.clear();
    unsubscribeActivity = subscribePluginActivity((pluginId) => {
      for (const [path, cached] of owners) {
        if (cached.owner.pluginId === pluginId) owners.delete(path);
      }
      // Pending answers do not carry an owner yet. Let the active editor
      // issue a fresh lookup; the old answer remains protected by its guard.
      pending.clear();
      publishChange();
    });
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      unsubscribeActivity?.();
      unsubscribeActivity = null;
    }
  };
}

export function cachedDeclarativeLanguageOwner(filePath: string): DeclarativeLanguageOwner | null {
  const cached = owners.get(filePath);
  if (!cached) return null;
  try {
    cached.assertCurrent(cached.owner.pluginId);
    return cached.owner;
  } catch {
    // A mutation while no editor subscribed must also invalidate the hint.
    owners.delete(filePath);
    return null;
  }
}

/** Query accepted/enabled ownership without preparing or starting a process. */
export function probeDeclarativeLanguageOwner(
  filePath: string,
): Promise<DeclarativeLanguageOwner | null> {
  const cached = cachedDeclarativeLanguageOwner(filePath);
  if (cached) return Promise.resolve(cached);
  const existing = pending.get(filePath);
  if (existing) return existing;
  const assertCurrent = pluginPlanGuard();
  const task = (async () => {
    const { invokeDeclarativePluginOwner } =
      await import("@/features/plugins/declarative-plugin-launch");
    const owner = await invokeDeclarativePluginOwner(filePath);
    if (!owner) return null;
    try {
      assertCurrent(owner.pluginId);
    } catch {
      return null;
    }
    owners.set(filePath, { owner, assertCurrent });
    publishChange();
    return owner;
  })().finally(() => {
    if (pending.get(filePath) === task) pending.delete(filePath);
  });
  pending.set(filePath, task);
  return task;
}
