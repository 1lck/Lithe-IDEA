import { invoke } from "@/platform/tauri-core";
import { pluginCore } from "./plugin-core";
import type { ExtensionManifest } from "../types/extension-manifest";

const PREFIX = "lithe.worker-package:";
export const MAX_PLUGIN_PACKAGE_BYTES = 128 * 1024 * 1024;
export interface LocalExtensionPackage {
  format: "lithe-worker-plugin";
  version: 1;
  manifest: ExtensionManifest;
  source: string;
  installed?: boolean;
  nativePackage?: { manifestJSON: string; signature: Record<string, unknown>; stagingId?: string };
}

/** Core validates identity, declarations and grants before any package is stored or executed. */
export async function parseLocalExtensionPackage(text: string): Promise<LocalExtensionPackage> {
  // Bound transport allocation before crossing the native boundary; Core repeats
  // the byte limit because callers cannot be trusted to enforce it.
  if (new TextEncoder().encode(text).length > MAX_PLUGIN_PACKAGE_BYTES)
    throw new Error("Plugin package exceeds 128 MB");
  return pluginCore.execute("plugin.validateWorkerPackage", { text });
}

/** One atomic storage item owns both source and state; failed writes leave the old package intact. */
type PackageStorage = Pick<Storage, "length" | "key" | "getItem" | "setItem" | "removeItem">;
export class LocalExtensionPackageStore {
  constructor(private readonly storage: () => PackageStorage = () => localStorage) {}
  async list(): Promise<LocalExtensionPackage[]> {
    const packages: LocalExtensionPackage[] = [];
    for (let i = 0; i < this.storage().length; i++) {
      const key = this.storage().key(i);
      if (!key?.startsWith(PREFIX)) continue;
      const raw = this.storage().getItem(key);
      if (!raw) continue;
      try {
        packages.push(await this.decode(raw));
      } catch (error) {
        console.warn(`Ignoring invalid plugin package ${key}:`, error);
      }
    }
    return packages;
  }
  async get(id: string): Promise<LocalExtensionPackage | undefined> {
    const raw = this.storage().getItem(PREFIX + id);
    return raw ? this.decode(raw) : undefined;
  }
  private async decode(raw: string): Promise<LocalExtensionPackage> {
    const record = JSON.parse(raw);
    return parseLocalExtensionPackage(JSON.stringify(record.current ?? record));
  }
  async previous(id: string): Promise<LocalExtensionPackage | undefined> {
    const raw = this.storage().getItem(PREFIX + id);
    const previous = raw ? JSON.parse(raw).previous : undefined;
    return previous ? parseLocalExtensionPackage(JSON.stringify(previous)) : undefined;
  }
  async stage(pkg: LocalExtensionPackage, signedBundleText?: string, replace = false) {
    const key = PREFIX + pkg.manifest.id;
    const before = this.storage().getItem(key);
    const previous = before ? await this.decode(before) : undefined;
    if (previous && !replace)
      throw new Error("Disable the existing plugin before importing a replacement.");
    let validated = await parseLocalExtensionPackage(JSON.stringify(pkg));
    if (validated.nativePackage) {
      if (!signedBundleText) throw new Error("The complete signed package is required");
      validated = await invoke<LocalExtensionPackage>("stage_worker_resources", {
        text: signedBundleText, stagingId: crypto.randomUUID(),
      });
    }
    try {
      if (validated.manifest.id !== pkg.manifest.id || validated.manifest.version !== pkg.manifest.version)
        throw new Error("Signed package identity does not match the imported metadata");
      if (this.storage().getItem(key) !== before)
        throw new Error("Plugin changed while preparing the replacement");
      this.storage().setItem(key, JSON.stringify({
        current: { ...validated, installed: false },
        previous: previous?.installed ? previous : undefined,
      }));
    } catch (error) {
      if (validated.nativePackage?.stagingId)
        await invoke("discard_worker_staging", { stagingId: validated.nativePackage.stagingId });
      throw error;
    }
  }
  async markInstalled(id: string) {
    const raw = this.storage().getItem(PREFIX + id);
    const pkg = await this.get(id);
    if (this.storage().getItem(PREFIX + id) !== raw) throw new Error("Plugin changed during installation");
    if (!pkg) throw new Error("Plugin package is missing. Import it again.");
    if (pkg.nativePackage) delete pkg.nativePackage.stagingId;
    this.storage().setItem(PREFIX + id, JSON.stringify({
      current: { ...pkg, installed: true }, previous: raw ? JSON.parse(raw).previous : undefined,
    }));
  }
  /** Switch metadata atomically; native versions remain immutable until uninstall. */
  async rollback(id: string) {
    const raw = this.storage().getItem(PREFIX + id);
    const previous = await this.previous(id);
    if (!raw || !previous) throw new Error("No previous plugin version is available");
    const current = await this.decode(raw);
    if (current.nativePackage?.stagingId)
      await invoke("discard_worker_staging", { stagingId: current.nativePackage.stagingId });
    if (this.storage().getItem(PREFIX + id) !== raw) throw new Error("Plugin changed during rollback");
    this.storage().setItem(PREFIX + id, JSON.stringify({ current: previous,
      previous: current.installed ? current : undefined }));
    return previous;
  }
  /** A WebView/app crash before commit must not hide the last installed version. */
  async recoverInterruptedReplacements() {
    for (const current of await this.list()) {
      if (!current.installed && await this.previous(current.manifest.id))
        await this.rollback(current.manifest.id);
    }
  }
  remove(id: string) {
    this.storage().removeItem(PREFIX + id);
  }
}
export const localExtensionPackages = new LocalExtensionPackageStore();
