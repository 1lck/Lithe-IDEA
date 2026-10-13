import type { JavaEntrypoint, JavaEntrypoints } from "@/platform/lsp-core-adapter";
import type { RunConfiguration } from "../types/run.types";

/** Merge an explicit, freshly JDT-confirmed marker, including unmanaged Java files.
 * JDT's workspace search can omit files in its default/invisible project even
 * though resolveMainMethod recognizes the open file. Never infer an entry from text.
 */
export function withContextJavaEntrypoint(
  discovered: JavaEntrypoints | undefined,
  requested: JavaEntrypoint | undefined,
  previous: readonly RunConfiguration[],
): JavaEntrypoints | undefined {
  if (!requested) return discovered;
  const entries =
    discovered?.entries ??
    previous.flatMap((configuration) =>
      configuration.mainClass && configuration.sourcePath
        ? [{ mainClass: configuration.mainClass, sourcePath: configuration.sourcePath }]
        : [],
    );
  const key = (entry: JavaEntrypoint) =>
    `${entry.sourcePath.replace(/\\/g, "/").toLowerCase()}\0${entry.mainClass}`;
  const merged = new Map(entries.map((entry) => [key(entry), entry]));
  merged.set(key(requested), requested);
  return {
    schemaVersion: 1,
    entries: [...merged.values()].sort(
      (a, b) => a.sourcePath.localeCompare(b.sourcePath) || a.mainClass.localeCompare(b.mainClass),
    ),
    diagnostics: discovered?.diagnostics ?? [],
  };
}
