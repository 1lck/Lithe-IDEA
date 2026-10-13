import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
import type { GitReference } from "../../types/git.types";
import { GitReferenceTree } from "./git-reference-tree";

const REPO_A = "C:/repo-a";
const REPO_B = "C:/repo-b";

const localReference = (shortName: string, repositoryPath: string): GitReference => ({
  fullName: `refs/heads/${shortName}`,
  shortName,
  kind: "local",
  peelsToCommit: true,
  isCurrent: shortName === "main",
  repositoryPath,
});

const referencesByRepository = new Map([
  [REPO_A, [localReference("main", REPO_A)]],
  [REPO_B, [localReference("develop", REPO_B)]],
]);

// Happy DOM has no ResizeObserver; the reference toolbar observes its height.
class ResizeObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}

let restoreDom: () => void;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let previousResizeObserver: PropertyDescriptor | undefined;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousResizeObserver = Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver");
  Object.defineProperty(globalThis, "ResizeObserver", {
    configurable: true,
    writable: true,
    value: ResizeObserverStub,
  });
  useGitLogPreferencesStore.setState({ collapsedReferenceGroups: [] });
  const container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  document.body.replaceChildren();
  if (previousResizeObserver) {
    Object.defineProperty(globalThis, "ResizeObserver", previousResizeObserver);
  } else {
    Reflect.deleteProperty(globalThis, "ResizeObserver");
  }
  restoreDom();
  actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

async function renderTree(onEnsureRepository: (repositoryPath: string) => void) {
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <GitReferenceTree
          repoPath={REPO_A}
          references={referencesByRepository.get(REPO_A) ?? []}
          selectedReference={null}
          onSelect={() => {}}
          onReferenceAction={() => {}}
          onSetUpstream={() => {}}
          onManageRemotes={() => {}}
          onFetch={() => {}}
          onNavigateToHead={() => {}}
          repositoryPaths={[REPO_A, REPO_B]}
          activeRepoPath={REPO_A}
          referencesByRepository={referencesByRepository}
          onEnsureRepository={onEnsureRepository}
        />
      </LocaleProvider>,
    );
  });
}

test("requests the visible non-active repository group", async () => {
  const requested: string[] = [];
  await renderTree((repositoryPath) => requested.push(repositoryPath));

  expect(requested).toEqual([REPO_A, REPO_B]);
});

test("does not request a collapsed repository group until it is expanded", async () => {
  useGitLogPreferencesStore.setState({ collapsedReferenceGroups: [`repo:${REPO_B}`] });
  const requested: string[] = [];
  await renderTree((repositoryPath) => requested.push(repositoryPath));

  expect(requested).toEqual([REPO_A]);

  requested.length = 0;
  await act(async () => {
    useGitLogPreferencesStore.getState().actions.toggleReferenceGroup(`repo:${REPO_B}`);
  });

  expect(requested).toEqual([REPO_A, REPO_B]);
});
