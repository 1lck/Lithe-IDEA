import { describe, expect, test } from "bun:test";
import { isGitRepositoryRoot } from "./git-repository-root";

describe("isGitRepositoryRoot", () => {
  const repositoryPaths = ["C:/work/monorepo", "D:/other/service"];

  test("accepts an exact normalized repository root", () => {
    expect(isGitRepositoryRoot("C:/work/monorepo", repositoryPaths)).toBe(true);
    expect(isGitRepositoryRoot("D:/other/service", repositoryPaths)).toBe(true);
  });

  test("normalizes separators and trailing slashes before comparing", () => {
    expect(isGitRepositoryRoot("C:\\work\\monorepo\\", repositoryPaths)).toBe(true);
    expect(isGitRepositoryRoot("C:/work/monorepo/", repositoryPaths)).toBe(true);
  });

  test("accepts the workspace root when discovery reports it as a repository", () => {
    expect(isGitRepositoryRoot("C:/work", ["C:/work"])).toBe(true);
  });

  test("rejects non-root directories inside a repository", () => {
    expect(isGitRepositoryRoot("C:/work/monorepo/packages/app", repositoryPaths)).toBe(false);
  });

  test("rejects directories that are not repositories", () => {
    expect(isGitRepositoryRoot("C:/work/plain-folder", repositoryPaths)).toBe(false);
  });

  test("rejects missing or empty paths", () => {
    expect(isGitRepositoryRoot(null, repositoryPaths)).toBe(false);
    expect(isGitRepositoryRoot(undefined, repositoryPaths)).toBe(false);
    expect(isGitRepositoryRoot("", repositoryPaths)).toBe(false);
    expect(isGitRepositoryRoot("C:/work/monorepo", [])).toBe(false);
  });
});
