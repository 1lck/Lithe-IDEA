import type { ExtensionManifest } from "../types/extension-manifest";

const PREFIX = "lithe.worker-package:";
export const MAX_PLUGIN_PACKAGE_BYTES = 256 * 1024;
export interface LocalExtensionPackage {
  format: "lithe-worker-plugin";
  version: 1;
  manifest: ExtensionManifest;
  source: string;
  installed?: boolean;
}

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function strings(value: unknown, maximum = 128): value is string[] {
  return (
    Array.isArray(value) &&
    value.length <= maximum &&
    value.every((s) => typeof s === "string" && s.length <= 4096 && !s.includes("\0"))
  );
}

/** This format intentionally accepts only a single worker and declarative language tools. */
export function parseLocalExtensionPackage(text: string): LocalExtensionPackage {
  if (new TextEncoder().encode(text).length > MAX_PLUGIN_PACKAGE_BYTES)
    throw new Error("Plugin package exceeds 256 KB");
  const pkg: unknown = JSON.parse(text);
  if (
    !object(pkg) ||
    pkg.format !== "lithe-worker-plugin" ||
    pkg.version !== 1 ||
    typeof pkg.source !== "string" ||
    !pkg.source.trim() ||
    !object(pkg.manifest)
  )
    throw new Error("Invalid worker plugin package");
  const m = pkg.manifest;
  if (
    typeof m.id !== "string" ||
    !/^[a-z][a-z0-9-]*\.[a-z0-9.-]+$/.test(m.id) ||
    m.id.length > 128 ||
    m.main !== "plugin.js"
  )
    throw new Error("Invalid plugin identity or entrypoint");
  for (const key of ["name", "displayName", "description", "version", "publisher"]) {
    if (typeof m[key] !== "string" || (m[key] as string).length > 4096)
      throw new Error(`Invalid plugin ${key}`);
  }
  if (!Array.isArray(m.languages) || m.languages.length === 0 || m.languages.length > 16)
    throw new Error("A language plugin must declare its languages");
  for (const language of m.languages) {
    if (
      !object(language) ||
      typeof language.id !== "string" ||
      !/^[a-z][a-z0-9-]*$/.test(language.id) ||
      !strings(language.extensions) ||
      !language.extensions.every((s) => /^\.[a-z0-9]+$/i.test(s)) ||
      (language.aliases !== undefined && !strings(language.aliases))
    )
      throw new Error("Invalid language contribution");
  }
  const run = m.runActions;
  if (
    !object(run) ||
    !strings(run.manifestFiles, 16) ||
    !run.manifestFiles.every((name) => /^[a-z0-9][a-z0-9_.-]*$/i.test(name)) ||
    !strings(run.executables, 16) ||
    !run.executables.every((name) => /^[a-z0-9][a-z0-9_.-]*$/i.test(name))
  )
    throw new Error("Invalid run action declarations");
  const lsp = m.lsp;
  if (
    lsp !== undefined &&
    (!object(lsp) ||
      typeof lsp.name !== "string" ||
      !/^[a-z0-9][a-z0-9_.-]*$/i.test(lsp.name) ||
      !["bun", "system"].includes(String(lsp.runtime)) ||
      !object(lsp.server) ||
      lsp.server.default !== lsp.name ||
      !strings(lsp.args) ||
      !strings(lsp.fileExtensions) ||
      !strings(lsp.languageIds) ||
      (lsp.runtime === "bun" &&
        (typeof lsp.package !== "string" || !/^(@[a-z0-9-]+\/)?[a-z0-9_.-]+$/.test(lsp.package))))
  )
    throw new Error("Invalid language server configuration");
  if (
    object(lsp) &&
    lsp.requiredExecutables !== undefined &&
    (!strings(lsp.requiredExecutables, 16) ||
      !lsp.requiredExecutables.every((name) => /^[a-z0-9][a-z0-9_.-]*$/i.test(name)))
  )
    throw new Error("Invalid executable requirements");
  // Copy only supported fields: packages cannot grant themselves other host services.
  const manifest = {
    id: m.id,
    name: m.name,
    displayName: m.displayName,
    description: m.description,
    version: m.version,
    publisher: m.publisher,
    categories: ["Language"],
    main: "plugin.js",
    languages: m.languages.map((language) => ({
      id: language.id,
      extensions: language.extensions,
      ...(language.aliases ? { aliases: language.aliases } : {}),
    })),
    ...(lsp
      ? {
          lsp: {
            name: lsp.name,
            runtime: lsp.runtime,
            requiredExecutables: lsp.requiredExecutables,
            package: lsp.package,
            server: { default: lsp.name },
            args: lsp.args,
            fileExtensions: lsp.fileExtensions,
            languageIds: lsp.languageIds,
          },
        }
      : {}),
    runActions: { manifestFiles: run.manifestFiles, executables: run.executables },
    installation: { type: "local" },
  } as ExtensionManifest;
  return {
    format: "lithe-worker-plugin",
    version: 1,
    manifest,
    source: pkg.source,
    installed: pkg.installed === true,
  };
}

/** One atomic storage item owns both source and state; failed writes leave the old package intact. */
type PackageStorage = Pick<Storage, "length" | "key" | "getItem" | "setItem" | "removeItem">;
export class LocalExtensionPackageStore {
  constructor(private readonly storage: () => PackageStorage = () => localStorage) {}
  list(): LocalExtensionPackage[] {
    const packages: LocalExtensionPackage[] = [];
    for (let i = 0; i < this.storage().length; i++) {
      const key = this.storage().key(i);
      if (!key?.startsWith(PREFIX)) continue;
      const raw = this.storage().getItem(key);
      if (!raw) continue;
      try {
        packages.push(parseLocalExtensionPackage(raw));
      } catch (error) {
        console.warn(`Ignoring invalid plugin package ${key}:`, error);
      }
    }
    return packages;
  }
  get(id: string): LocalExtensionPackage | undefined {
    const raw = this.storage().getItem(PREFIX + id);
    return raw ? parseLocalExtensionPackage(raw) : undefined;
  }
  stage(pkg: LocalExtensionPackage) {
    if (this.get(pkg.manifest.id))
      throw new Error("Uninstall the existing plugin before importing a replacement.");
    const validated = parseLocalExtensionPackage(JSON.stringify(pkg));
    this.storage().setItem(
      PREFIX + validated.manifest.id,
      JSON.stringify({ ...validated, installed: false }),
    );
  }
  markInstalled(id: string) {
    const pkg = this.get(id);
    if (!pkg) throw new Error("Plugin package is missing. Import it again.");
    this.storage().setItem(PREFIX + id, JSON.stringify({ ...pkg, installed: true }));
  }
  remove(id: string) {
    this.storage().removeItem(PREFIX + id);
  }
}
export const localExtensionPackages = new LocalExtensionPackageStore();
