import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import * as tauriCore from "@/platform/tauri-core";
import { installHappyDom } from "@/test-utils/happy-dom";
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

// Stands in for `git.referenceTree`; the grouping rules are tested in Core.
let restoreDom: (() => void) | undefined;
let invokeSpy: ReturnType<typeof spyOn> | undefined;
beforeEach(() => {
  restoreDom = installHappyDom();
  globalThis.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  invokeSpy = spyOn(tauriCore, "invoke").mockImplementation((async (
    command: string,
    args: { references?: { name: string }[] },
  ) => {
    // Other commands (repository colors) stay unresolved.
    if (command !== "git.referenceTree") return new Promise(() => {});
    return {
      nodes: (args.references ?? []).map((item, index) => ({
        name: item.name,
        path: item.name,
        reference: index,
        children: [],
      })),
    };
  }) as never);
});
afterEach(() => {
  invokeSpy?.mockRestore();
  restoreDom?.();
});

const renderTree = async (
  props: Partial<Parameters<typeof GitReferenceTree>[0]> &
    Pick<Parameters<typeof GitReferenceTree>[0], "repoPath" | "references">,
) => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
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
    ),
  );
  const markup = host.innerHTML;
  await act(async () => root.unmount());
  host.remove();
  return markup;
};

test("single repository keeps the flat reference sections", async () => {
  const markup = await renderTree({
    repoPath: "C:/repo-a",
    references: [localReference("main", true)],
    repositoryPaths: ["C:/repo-a"],
  });

  expect(markup).toContain("Local");
  expect(markup).toContain("main");
  expect(markup).not.toContain("repo-a");
  expect(markup).not.toContain("background-color");
});

test("multi-repository workspaces render neutral dots while Core loads", async () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = await renderTree({
    repoPath: "C:/repo-a",
    references: [repoA],
    repositoryPaths: ["C:/repo-a", "C:/repo-b"],
    activeRepoPath: "C:/repo-a",
    referencesByRepository: new Map([
      ["C:/repo-a", [repoA]],
      ["C:/repo-b", [repoB]],
    ]),
  });

  expect(markup).not.toContain("background-color:");
  expect(markup.match(/git-repository-color-dot/g)).toHaveLength(2);
  // The old card header used an 8-digit alpha tint, a left border and colored text.
  expect(markup).not.toContain("#55d68b14");
  expect(markup).not.toContain("border-left");
  expect(markup).not.toMatch(/(?<!background-)color:#55d68b/);
});

test("multiple repositories group each section set under a repository header", async () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = await renderTree({
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

test("exposes reference actions only for the active repository group", async () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = await renderTree({
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

test("shows linked worktree repositories and the toggle by default", async () => {
  const markup = await renderWorktreeWorkspace();

  expect(markup).toContain("op-platform");
  expect(markup).toContain("apps-sealed");
  expect(markup).toContain("sealed-feature");
  expect(markup).toContain('aria-label="Hide Worktree Repositories"');
  expect(markup).toContain('aria-pressed="true"');
});

test("disables the worktree toggle when no repository is nested", async () => {
  const repoA = { ...localReference("main", true), repositoryPath: "C:/repo-a" };
  const repoB = { ...localReference("develop"), repositoryPath: "C:/repo-b" };
  const markup = await renderTree({
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
