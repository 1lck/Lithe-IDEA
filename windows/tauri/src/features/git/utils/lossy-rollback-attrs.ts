import { invoke as tauriInvoke } from "@/platform/tauri-core";

/** Attributes that decide whether raw patch bytes can round-trip through
 * `git apply` without silent conversion or filtering. */
export interface GitAttributeSafety {
  /** Safe to route hunk rollback through the raw patch channel. */
  byteSafe: boolean;
  /** Human-readable reason when unsafe, for diagnostics. */
  reason?: string;
}

/**
 * Parses `git check-attr` output. Each line is `path: attr: value`; the
 * attribute name is the key, not the path. Missing or unparseable output
 * fails closed (unsafe).
 */
function parseCheckAttr(output: string): Map<string, string> {
  const attributes = new Map<string, string>();
  for (const line of output.split("\n")) {
    const parts = line.split(":");
    // path : attrName : value — three colon-separated fields; the path may
    // contain colons on some platforms but check-attr on a single file
    // always emits exactly `path: attr: value` per line.
    if (parts.length < 3) continue;
    const attrName = parts[parts.length - 2].trim();
    const value = parts[parts.length - 1].trim();
    if (attrName) {
      attributes.set(attrName, value);
    }
  }
  return attributes;
}

/** Checks Git's effective attributes for the file: any filter or non-trivial
 * working-tree-encoding that could rewrite bytes means the raw patch cannot
 * be proven byte-faithful, and rollback must stay in the protective
 * whole-file mode. `text` and `eol` are conversion directives that Git
 * itself handles faithfully through `git apply`, so they stay safe. */
export async function checkHunkRollbackAttributes(
  rootPath: string,
  filePath: string,
): Promise<GitAttributeSafety> {
  try {
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
    // Fail closed: if the required attributes are absent from the output,
    // the check itself is unreliable.
    const filter = attrs.get("filter");
    if (filter === undefined) {
      return { byteSafe: false, reason: "filter attribute not reported" };
    }
    if (filter !== "unspecified" && filter !== "unset") {
      return { byteSafe: false, reason: `filter=${filter}` };
    }
    const encoding = attrs.get("working-tree-encoding");
    if (encoding !== undefined && encoding !== "unspecified" && encoding !== "unset") {
      return { byteSafe: false, reason: `working-tree-encoding=${encoding}` };
    }
    return { byteSafe: true };
  } catch {
    return { byteSafe: false, reason: "attribute check failed" };
  }
}
