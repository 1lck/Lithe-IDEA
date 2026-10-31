import { getPathIdentity, isCaseInsensitivePath, normalizePath, getRelativePath, joinPath, pathStartsWithRoot } from "@/utils/path-helpers";

export function buildCatalogMayChange(manifests: Record<string, Record<string, unknown>>, workspace: string, path: string, rescan: boolean): boolean {
  if (!pathStartsWithRoot(path, workspace)) return false;
  if (rescan) return true;
  const identity = (value: string) => isCaseInsensitivePath(workspace) ? normalizePath(value).toLowerCase() : normalizePath(value);
  const relative = identity(getRelativePath(path, workspace));
  if ([".lithe/build/options.json", ".lithe/run/local.json", ".lithe/run/configurations.json", ".lithe/toolchains/local.json", ".lithe/project.json"]
    .some(input => relative === identity(input))) return true;
  return Object.values(manifests).some(manifest => (manifest.buildSystems as Array<{ detection?: { markers?: string[] } }> | undefined)
    ?.some(system => system.detection?.markers?.some(marker => {
      const normalized = identity(marker);
      return relative === normalized || relative.endsWith(`/${normalized}`);
    })));
}

/** Hosts compare paths from Core's watch projection; declaration parsing,
 * workspace reads and fingerprints remain in Core. */
export class BuildFileInputs {
  private readonly watches = new Map<string, string[]>();
  private readonly preparing = new Map<string, { owner: string; model: boolean }>();
  constructor(private readonly workspacePath: string) {}
  remember(owner: string, paths: string[]): void { this.watches.set(owner, paths.map(path => joinPath(this.workspacePath, path))); }
  begin(id: string, owner: string, model: boolean): void { this.preparing.set(id, { owner, model }); }
  finish(id: string): void { this.preparing.delete(id); }
  forget(owner: string): void { this.watches.delete(owner); }
  clear(): void { this.watches.clear(); this.preparing.clear(); }
  changed(path: string, rescan: boolean): { owners: Set<string>; cancelled: string[]; workspace: boolean } {
    const workspace = pathStartsWithRoot(path, this.workspacePath);
    const owners = new Set<string>(), cancelled: string[] = [];
    for (const [owner, paths] of this.watches) {
      if ((rescan && workspace) || paths.some(watched => getPathIdentity(watched) === getPathIdentity(path) || pathStartsWithRoot(watched, path))) owners.add(owner);
    }
    if (workspace) for (const [id, preparation] of this.preparing) {
      if (preparation.model) owners.add(preparation.owner); else cancelled.push(id);
    }
    return { owners, cancelled, workspace };
  }
}
