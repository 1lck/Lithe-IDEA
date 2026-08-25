import type { PaneContent } from "@/features/panes/types/pane-content.types";
import { isVirtualContent } from "@/features/panes/types/pane-content.types";

/**
 * Get path segments (directories) from a file path
 */
function getPathSegments(filePath: string): string[] {
  // Normalize path separators to forward slash
  const normalized = filePath.replace(/\\/g, "/");
  const parts = normalized.split("/");
  // Return all parts except the last one (filename)
  return parts.slice(0, -1);
}

/**
 * Get the filename from a path
 */
function getFileName(filePath: string): string {
  const normalized = filePath.replace(/\\/g, "/");
  const parts = normalized.split("/");
  return parts[parts.length - 1] || "";
}

/**
 * Check if a path is within the root directory
 */
/**
 * Calculate minimal distinguishing display names for buffers
 * Returns a map of buffer ID to display name
 */
export function calculateDisplayNames(
  buffers: PaneContent[],
  _rootPath: string | undefined,
): Map<string, string> {
  const displayNames = new Map<string, string>();

  // Group buffers by filename
  const fileNameGroups = new Map<
    string,
    { items: Array<{ buffer: PaneContent; segments: string[] }>; maxSegments: number }
  >();
  for (const buffer of buffers) {
    if (isVirtualContent(buffer) || buffer.path === "extensions://marketplace") {
      continue;
    }

    const fileName = getFileName(buffer.path);
    const segments = getPathSegments(buffer.path);
    let group = fileNameGroups.get(fileName);
    if (!group) {
      group = { items: [], maxSegments: 0 };
      fileNameGroups.set(fileName, group);
    }

    group.items.push({ buffer, segments });
    if (segments.length > group.maxSegments) {
      group.maxSegments = segments.length;
    }
  }

  // For each filename group, determine minimal distinguishing paths
  for (const [fileName, group] of fileNameGroups) {
    const { items, maxSegments } = group;
    if (items.length === 1) {
      // Only one file with this name, just show the filename
      displayNames.set(items[0].buffer.id, fileName);
      continue;
    }

    // Prefer a single distinguishing directory segment, IDE-style:
    // "X.java · data-carrier-web" instead of a long "../a/b/c/X.java" chain.
    // Java projects often share deep identical package paths across modules,
    // which made the suffix-join approach degenerate into near-full paths.
    let resolved = false;
    for (let depth = 1; depth <= maxSegments && !resolved; depth++) {
      const seen = new Set<string>();
      let allDistinct = true;
      for (const { segments } of items) {
        const segment = segments[segments.length - depth] ?? "";
        if (seen.has(segment)) {
          allDistinct = false;
          break;
        }
        seen.add(segment);
      }
      if (allDistinct) {
        for (const { buffer, segments } of items) {
          const segment = segments[segments.length - depth];
          displayNames.set(buffer.id, segment ? `${fileName} · ${segment}` : fileName);
        }
        resolved = true;
      }
    }

    // Fallback: no single directory level tells them apart (e.g. a/p, b/p,
    // a/q). Use the shortest distinct suffix, capped to avoid huge tab labels.
    if (!resolved) {
      for (const { buffer, segments } of items) {
        const suffix = segments.slice(-2).join("/");
        displayNames.set(buffer.id, suffix ? `${fileName} · ${suffix}` : fileName);
      }
    }
  }

  // Set display names for special/virtual buffers
  for (const buffer of buffers) {
    if (!displayNames.has(buffer.id)) {
      displayNames.set(buffer.id, buffer.name);
    }
  }

  return displayNames;
}
