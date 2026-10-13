// Adapted from macOS GitGraphReferenceGroup and IntelliJ LabelPainter.
// Apache-2.0 attribution: macos/Resources/GitGraph/NOTICE.txt.
import type { GitReference } from "../types/git.types";
import { naturalCompare, type GitGraphLabel, type GitGraphLabelKind } from "./git-graph-layout";

export interface GitGraphReferenceGroup {
  title: string;
  labels: readonly GitGraphLabel[];
  iconKinds: readonly GitGraphLabelKind[];
  tooltip: string;
}

export function groupGitGraphReferences(
  labels: readonly GitGraphLabel[],
  references: readonly GitReference[] = [],
): GitGraphReferenceGroup {
  const current = references.find(
    (reference) => reference.kind === "local" && reference.isCurrent,
  )?.shortName;
  const rank = (label: GitGraphLabel) =>
    label.kind === "head"
      ? 0
      : label.kind === "branch"
        ? label.title === current
          ? 1
          : ["main", "master"].includes(label.title)
            ? 2
            : 4
        : label.kind === "remote"
          ? ["origin/main", "origin/master"].includes(label.title)
            ? 3
            : 5
          : 6;
  const sorted = [...labels].sort(
    (left, right) => rank(left) - rank(right) || naturalCompare(left.title, right.title),
  );
  const remotes = sorted.filter((label) => label.kind === "remote");
  const paired = new Set<GitGraphLabel>();
  const tracked: string[] = [];
  for (const local of sorted.filter((label) => label.kind === "branch")) {
    const upstream = references.find(
      (reference) => reference.kind === "local" && reference.shortName === local.title,
    )?.upstreamShortName;
    const remote =
      remotes.find((label) => label.title === upstream) ??
      remotes.find((label) => label.title.slice(label.title.indexOf("/") + 1) === local.title);
    if (remote) {
      paired.add(local);
      paired.add(remote);
      tracked.push(`${remote.title.split("/")[0]} & ${local.title}`);
    }
  }
  const unpaired = sorted.filter((label) => label.kind !== "head" && !paired.has(label));
  const currentLabel = unpaired.find((label) => label.kind === "branch" && label.title === current);
  const first = unpaired[0];
  const title =
    currentLabel?.title ??
    tracked[0] ??
    (first
      ? first.kind === "tag"
        ? ""
        : first.title
      : sorted.some((label) => label.kind === "head")
        ? "HEAD"
        : "");
  const iconKinds: GitGraphLabelKind[] = [];
  for (const label of sorted)
    if (iconKinds.filter((kind) => kind === label.kind).length < 2) iconKinds.push(label.kind);
  return {
    title,
    labels: sorted,
    iconKinds,
    tooltip: sorted.map((label) => label.title).join("\n"),
  };
}

export function gitReferenceIconWidth(group: GitGraphReferenceGroup, height: number): number {
  return group.labels.length
    ? Math.round(height + (((group.iconKinds.length - 1) * height) / 6.25) * 2)
    : 0;
}

/** Width-based IDEA shortening keeps at least 22 characters before clipping. */
export function shortenGitReferenceTitle(
  title: string,
  availableWidth: number,
  measure: (text: string) => number,
): string {
  const characters = (value: string) => Array.from(value);
  if (characters(title).length <= 22 || measure(title) <= availableWidth) return title;
  let result = title;
  const slash = result.indexOf("/");
  if (slash > 2) result = ".." + result.slice(slash);
  if (availableWidth > 0 && measure(result) <= availableWidth) return result;
  while (characters(result).length > 22) {
    if (result.endsWith("…")) result = result.slice(0, -1);
    const chars = characters(result);
    chars.pop();
    result = chars.join("");
    const candidate = result + "…";
    if (availableWidth > 0 && measure(candidate) <= availableWidth) return candidate;
  }
  return characters(result).length >= 22 ? characters(result).slice(0, 21).join("") + "…" : result;
}
