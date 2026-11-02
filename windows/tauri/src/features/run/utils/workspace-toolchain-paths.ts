import { joinPath, normalizePath } from "@/utils/path-helpers";
import type { GlobalToolchain } from "../types/run.types";

/** Resolve persisted workspace-relative selections at the native boundary.
 * Drive-relative paths stay intact so native validation can reject them. */
export function workspaceToolchainPath(root: string, value: string): string {
  if (!value.trim()) return "";
  const path = normalizePath(value);
  if (/^[A-Za-z]:/.test(path) || path.startsWith("/")) return path;
  const rooted = normalizePath(joinPath(root, path));
  // Discovery returns canonical paths. Collapse lexical dot segments before
  // matching its candidates, retaining the drive or UNC share as the anchor.
  const anchor = rooted.match(/^(?:[A-Za-z]:\/|\/\/[^/]+\/[^/]+\/|\/)/)?.[0];
  if (!anchor) return rooted;
  const parts: string[] = [];
  for (const part of rooted.slice(anchor.length).split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return anchor + parts.join("/");
}

export function workspaceToolchainSelection(root: string, selected: GlobalToolchain): GlobalToolchain {
  return {
    javaHomePath: workspaceToolchainPath(root, selected.javaHomePath),
    mavenExecutablePath: workspaceToolchainPath(root, selected.mavenExecutablePath),
    mavenJavaHomePath: workspaceToolchainPath(root, selected.mavenJavaHomePath),
    runtimeExecutablePaths: Object.fromEntries(Object.entries(selected.runtimeExecutablePaths)
      .map(([id, path]) => [id, workspaceToolchainPath(root, path)])),
  };
}
