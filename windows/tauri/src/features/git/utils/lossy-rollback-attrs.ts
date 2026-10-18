import { invoke as tauriInvoke } from "@/platform/tauri-core";

/** Attributes that decide whether raw patch bytes can round-trip through
 * `git apply` without silent conversion or filtering. */
export interface GitAttributeSafety {
  /** Safe to route hunk rollback through the raw patch channel. */
  byteSafe: boolean;
  /** Human-readable reason when unsafe, for diagnostics. */
  reason?: string;
}

function parseCheckAttr(output: string): Map<string, string> {
  const attributes = new Map<string, string>();
  for (const line of output.split("\n")) {
    const [name, , value] = line.split(":");
    if (name && value !== undefined) {
      attributes.set(name.trim(), value.trim());
    }
  }
  return attributes;
}

/** Checks Git's effective attributes for the file: any filter, non-trivial
 * working-tree-encoding that could rewrite bytes means the raw patch cannot
 * be proven byte-faithful, and rollback must stay in the protective
 * whole-file mode. `text` and `eol` are conversion directives that Git
 * itself handles faithfully through `git apply`, so they stay safe. */
export async function checkHunkRollbackAttributes(
  rootPath: string,
  filePath: string,
): Promise<GitAttributeSafety> {
  try {
    // Dotted git.command rides the central dispatcher; check-attr is a
    // read-only query with no side effects.
    const response = await tauriInvoke<{ output: string; exitCode: number }>("git.command", {
      root: rootPath,
      arguments: [
        "check-attr",
        "filter",
        "working-tree-encoding",
        "text",
        "eol",
        "--",
        filePath,
      ],
    });
    if (response.exitCode !== 0) {
      return { byteSafe: false, reason: "attribute check failed" };
    }
    const attrs = parseCheckAttr(response.output);
    const filter = attrs.get("filter");
    if (filter && filter !== "unspecified" && filter !== "unset") {
      return { byteSafe: false, reason: `filter=${filter}` };
    }
    const encoding = attrs.get("working-tree-encoding");
    if (encoding && encoding !== "unspecified" && encoding !== "unset") {
      return { byteSafe: false, reason: `working-tree-encoding=${encoding}` };
    }
    return { byteSafe: true };
  } catch {
    return { byteSafe: false, reason: "attribute check failed" };
  }
}
