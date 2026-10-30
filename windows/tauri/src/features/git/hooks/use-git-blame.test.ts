import { expect, test } from "bun:test";
import { gitChangeForMetadata } from "../runtime/git-metadata-watch-host";
import { changeAffectsBlame } from "./use-git-blame";

const REPO = "C:/work/repo";
const FILE = "C:/work/repo/src/App.java";

test("an index rewrite does not reload blame, a ref move does", () => {
  // Tools rewrite .git/index constantly while a project opens.
  expect(changeAffectsBlame(gitChangeForMetadata(REPO, { indexOnly: true }), REPO, FILE)).toBe(false);
  expect(changeAffectsBlame(gitChangeForMetadata(REPO, { indexOnly: false }), REPO, FILE)).toBe(true);
});

test("writes to the file reload its blame, other files and repositories do not", () => {
  expect(changeAffectsBlame({ filePath: FILE, scopes: ["working-tree"], source: "save" }, REPO, FILE)).toBe(true);
  expect(
    changeAffectsBlame({ filePath: "C:/work/repo/src/Other.java", scopes: ["working-tree"] }, REPO, FILE),
  ).toBe(false);
  expect(changeAffectsBlame({ repoPath: "C:/work/other", scopes: ["history"] }, REPO, FILE)).toBe(false);
});

test("repository changes reload blame only when history may have moved", () => {
  expect(changeAffectsBlame({ repoPath: REPO, scopes: ["working-tree"] }, REPO, FILE)).toBe(false);
  expect(changeAffectsBlame({ repoPath: REPO, scopes: ["stashes"] }, REPO, FILE)).toBe(false);
  expect(changeAffectsBlame({ repoPath: REPO, scopes: ["working-tree", "history"] }, REPO, FILE)).toBe(true);
  // A change without scopes may be anything.
  expect(changeAffectsBlame({ repoPath: REPO }, REPO, FILE)).toBe(true);
});

test("metadata batches map to the scopes their consumers refresh", () => {
  expect(gitChangeForMetadata(REPO, { indexOnly: true }).scopes).toEqual(["working-tree"]);
  expect(gitChangeForMetadata(REPO, {}).scopes).toEqual([
    "working-tree",
    "history",
    "refs",
    "stashes",
    "repository",
  ]);
});
