import type { NativePanelIdentity, NativeSavedState } from "./native-ui.types";

export const nativePanelKey = (identity: NativePanelIdentity) =>
  JSON.stringify([
    identity.pluginId,
    identity.packageIdentity,
    identity.hostWindowId,
    identity.workspaceId,
    identity.windowId,
    identity.panelId,
  ]);
const MAX_SCOPE_BYTES = 64 * 1024;
const MAX_ENTRIES = 64;

/** Window-local, bounded memory only. No installed resource or runtime file is
 * writable. Entries survive hide/reopen, and revocation removes the owner. */
export class NativePanelStateStore {
  private readonly entries = new Map<
    string,
    { pluginId: string; scope: string; bytes: number; state: NativeSavedState }
  >();
  read(identity: NativePanelIdentity): NativeSavedState | undefined {
    const entry = this.entries.get(nativePanelKey(identity));
    return entry ? structuredClone(entry.state) : undefined;
  }
  write(identity: NativePanelIdentity, state: NativeSavedState): boolean {
    const bytes = new TextEncoder().encode(JSON.stringify(state)).byteLength;
    if (bytes > MAX_SCOPE_BYTES) return false;
    const key = nativePanelKey(identity);
    // The contract's budget belongs to the plugin/window/workspace scope,
    // even when several panels keep separate drafts within that scope.
    const scope = JSON.stringify([identity.pluginId, identity.hostWindowId, identity.workspaceId]);
    let scopeBytes = bytes;
    for (const [savedKey, entry] of this.entries) {
      if (savedKey !== key && entry.scope === scope) scopeBytes += entry.bytes;
    }
    if (scopeBytes > MAX_SCOPE_BYTES) return false;
    this.entries.delete(key);
    this.entries.set(key, {
      pluginId: identity.pluginId,
      scope,
      bytes,
      state: structuredClone(state),
    });
    while (this.entries.size > MAX_ENTRIES) this.entries.delete(this.entries.keys().next().value!);
    return true;
  }
  remove(identity: NativePanelIdentity): void {
    this.entries.delete(nativePanelKey(identity));
  }
  revoke(pluginId: string): void {
    for (const [key, entry] of this.entries)
      if (entry.pluginId === pluginId) this.entries.delete(key);
  }
}
