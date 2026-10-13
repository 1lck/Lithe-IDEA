import { expect, test } from "bun:test";
import { parseGitDecorations } from "./git-graph-layout";
import {
  gitReferenceIconWidth,
  groupGitGraphReferences,
  shortenGitReferenceTitle,
} from "./git-graph-reference-group";
import type { GitReference } from "../types/git.types";

const references: GitReference[] = [
  {
    fullName: "refs/heads/main",
    shortName: "main",
    kind: "local",
    isCurrent: true,
    peelsToCommit: true,
    upstreamShortName: "upstream/release",
  },
];
const group = (decorations: string) =>
  groupGitGraphReferences(parseGitDecorations(decorations), references);

// Independent expectations from macOS GitGraphInteractionTests.referenceGroups.
test("attached HEAD and explicit upstream tracking use the macOS compact group and full tooltip", () => {
  const tracked = group("HEAD -> main, refs/remotes/upstream/release, tag: v1");
  expect(tracked.title).toBe("upstream & main");
  expect(tracked.iconKinds).toEqual(["head", "branch", "remote", "tag"]);
  expect(tracked.tooltip).toBe("HEAD\nmain\nupstream/release\nv1");
  expect(gitReferenceIconWidth(tracked, 16)).toBe(31);
  expect(group("main, origin/main").title).toBe("origin & main");
});
test("detached HEAD remains explicit and tags keep full hover information with capped icon stacks", () => {
  expect(group("HEAD").title).toBe("HEAD");
  const tags = group("tag: v3, tag: v1, tag: v2");
  expect(tags.title).toBe("");
  expect(tags.iconKinds).toEqual(["tag", "tag"]);
  expect(tags.tooltip).toBe("v1\nv2\nv3");
  expect(group("").iconKinds).toEqual([]);
  expect(gitReferenceIconWidth(group(""), 16)).toBe(0);
});
test("current local labels outrank other refs and natural name order is retained without mutating labels", () => {
  const labels = parseGitDecorations("feature10, feature2, main, tag: v10, tag: v2");
  const original = [...labels];
  const result = groupGitGraphReferences(labels, references);
  expect(result.title).toBe("main");
  expect(result.tooltip).toBe("main\nfeature2\nfeature10\nv2\nv10");
  expect(labels).toEqual(original);
});
test("non-origin remotes pair with local slash names and explicit upstream metadata takes precedence", () => {
  const refs: GitReference[] = [
    { ...references[0], shortName: "feature/orders", upstreamShortName: "backup/different" },
  ];
  const result = groupGitGraphReferences(
    parseGitDecorations(
      "HEAD -> feature/orders, refs/remotes/upstream/feature/orders, refs/remotes/backup/different",
    ),
    refs,
  );
  expect(result.title).toBe("backup & feature/orders");
  expect(result.tooltip).toContain("upstream/feature/orders");
});
test("long names keep full text when wide and the macOS prefix/22-character shortening when narrow", () => {
  const title = "origin/codex/frontend-preview-with-long-name";
  const measure = (value: string) => Array.from(value).length * 7;
  expect(shortenGitReferenceTitle(title, 1000, measure)).toBe(title);
  const short = shortenGitReferenceTitle(title, 60, measure);
  expect(short.startsWith("../codex/")).toBe(true);
  expect(short.endsWith("…")).toBe(true);
  expect(Array.from(short)).toHaveLength(22);
  expect(shortenGitReferenceTitle("short", 0, measure)).toBe("short");
});
