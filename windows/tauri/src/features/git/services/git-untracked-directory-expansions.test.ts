import { afterEach, expect, test } from "bun:test";
import type { GitFile } from "../types/git.types";
import {
  isUntrackedDirectoryExpanded,
  listExpandedUntrackedDirectories,
  setUntrackedDirectoryExpanded,
} from "./git-untracked-directory-expansions";

const repo = "C:\\workspace\\expansions";
const untracked = (path: string, untrackedFileCount?: number): GitFile => ({
  path,
  status: "untracked",
  staged: false,
  ...(untrackedFileCount === undefined ? {} : { untrackedFileCount }),
});

afterEach(() => {
  for (const directory of ["target/", "target2/", "later/"])
    setUntrackedDirectoryExpanded(repo, directory, false);
});

test("collapsing a summary also forgets the summaries listed below it", () => {
  setUntrackedDirectoryExpanded(repo, "target/", true);
  setUntrackedDirectoryExpanded(repo, "target/debug/", true);
  setUntrackedDirectoryExpanded(repo, "target2/", true);
  // Native paths and Git's forward-slash paths name the same repository.
  expect(isUntrackedDirectoryExpanded("C:/workspace/expansions", "target/debug/")).toBe(true);

  setUntrackedDirectoryExpanded(repo, "target/", false);
  expect(isUntrackedDirectoryExpanded(repo, "target/")).toBe(false);
  expect(isUntrackedDirectoryExpanded(repo, "target/debug/")).toBe(false);
  expect(isUntrackedDirectoryExpanded(repo, "target2/")).toBe(true);
});

test("a summary expanded while a read runs survives that read", async () => {
  setUntrackedDirectoryExpanded(repo, "target/", true);
  const files = await listExpandedUntrackedDirectories(
    repo,
    [untracked("target/", 200)],
    async () => {
      // Expanded after this read captured its expansions, from a newer status.
      setUntrackedDirectoryExpanded(repo, "later/", true);
      return [untracked("target/a.o")];
    },
  );
  expect(files.map((file) => file.path)).toEqual(["target/", "target/a.o"]);
  expect(isUntrackedDirectoryExpanded(repo, "later/")).toBe(true);
});
