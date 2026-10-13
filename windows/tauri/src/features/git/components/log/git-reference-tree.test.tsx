import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LocaleProvider } from "@/i18n/locale-provider";
import type { GitReference } from "../../types/git.types";
import { GitReferenceTree } from "./git-reference-tree";

const localReference = (shortName: string, isCurrent = false): GitReference => ({
  fullName: `refs/heads/${shortName}`,
  shortName,
  kind: "local",
  peelsToCommit: true,
  isCurrent,
});

const renderTree = (
  props: Partial<Parameters<typeof GitReferenceTree>[0]> &
    Pick<Parameters<typeof GitReferenceTree>[0], "repoPath" | "references">,
) =>
  renderToStaticMarkup(
    <LocaleProvider language="en-US">
      <GitReferenceTree
        selectedReference={null}
        onSelect={() => {}}
        onReferenceAction={() => {}}
        onSetUpstream={() => {}}
        onManageRemotes={() => {}}
        onFetch={() => {}}
        onNavigateToHead={() => {}}
        {...props}
      />
    </LocaleProvider>,
  );

test("single repository keeps the flat reference sections", () => {
  const markup = renderTree({
    repoPath: "C:/repo-a",
    references: [localReference("main", true)],
    repositoryPaths: ["C:/repo-a"],
  });

  expect(markup).toContain("Local");
  expect(markup).toContain("main");
  expect(markup).not.toContain("repo-a");
  expect(markup).not.toContain("background-color");
});

test("multi-repository workspaces tint each repository group with its palette color", () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = renderTree({
    repoPath: "C:/repo-a",
    references: [repoA],
    repositoryPaths: ["C:/repo-a", "C:/repo-b"],
    activeRepoPath: "C:/repo-a",
    referencesByRepository: new Map([
      ["C:/repo-a", [repoA]],
      ["C:/repo-b", [repoB]],
    ]),
  });

  expect(markup).toContain("background-color:#55d68b14");
  expect(markup).toContain("background-color:#65a9ff14");
});

test("multiple repositories group each section set under a repository header", () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = renderTree({
    repoPath: "C:/repo-a",
    references: [repoA],
    repositoryPaths: ["C:/repo-a", "C:/repo-b"],
    activeRepoPath: "C:/repo-a",
    referencesByRepository: new Map([
      ["C:/repo-a", [repoA]],
      ["C:/repo-b", [repoB]],
    ]),
  });

  expect(markup).toContain("repo-a");
  expect(markup).toContain("repo-b");
  expect(markup).toContain("main");
  expect(markup).toContain("develop");
});

test("exposes reference actions only for the active repository group", () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = renderTree({
    repoPath: "C:/repo-a",
    references: [repoA],
    repositoryPaths: ["C:/repo-a", "C:/repo-b"],
    activeRepoPath: "C:/repo-a",
    referencesByRepository: new Map([
      ["C:/repo-a", [repoA]],
      ["C:/repo-b", [repoB]],
    ]),
  });

  const activeSection = markup.slice(0, markup.indexOf("C:/repo-b"));
  const inactiveSection = markup.slice(markup.indexOf("C:/repo-b"));

  expect(activeSection).toContain('data-reference-actions="enabled"');
  expect(inactiveSection).toContain('data-reference-actions="disabled"');
  expect(inactiveSection).not.toContain('data-reference-actions="enabled"');
});

const PRIMARY_REPO_PATH = "C:/root/op-platform";
const WORKTREE_REPO_PATH = "C:/root/op-platform/.worktrees/apps-sealed";

const renderWorktreeWorkspace = () => {
  const primaryReference = {
    ...localReference("main", true),
    repositoryPath: PRIMARY_REPO_PATH,
  };
  const worktreeReference = {
    ...localReference("sealed-feature"),
    repositoryPath: WORKTREE_REPO_PATH,
  };
  return renderTree({
    repoPath: PRIMARY_REPO_PATH,
    references: [primaryReference],
    repositoryPaths: [PRIMARY_REPO_PATH, WORKTREE_REPO_PATH],
    activeRepoPath: PRIMARY_REPO_PATH,
    referencesByRepository: new Map([
      [PRIMARY_REPO_PATH, [primaryReference]],
      [WORKTREE_REPO_PATH, [worktreeReference]],
    ]),
  });
};

test("shows linked worktree repositories and the toggle by default", () => {
  const markup = renderWorktreeWorkspace();

  expect(markup).toContain("op-platform");
  expect(markup).toContain("apps-sealed");
  expect(markup).toContain("sealed-feature");
  expect(markup).toContain('aria-label="Hide Worktree Repositories"');
  expect(markup).toContain('aria-pressed="true"');
});

test("disables the worktree toggle when no repository is nested", () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = renderTree({
    repoPath: "C:/repo-a",
    references: [repoA],
    repositoryPaths: ["C:/repo-a", "C:/repo-b"],
    activeRepoPath: "C:/repo-a",
    referencesByRepository: new Map([
      ["C:/repo-a", [repoA]],
      ["C:/repo-b", [repoB]],
    ]),
  });

  expect(markup).toContain('aria-label="Hide Worktree Repositories" aria-pressed="true" disabled=""');
});
