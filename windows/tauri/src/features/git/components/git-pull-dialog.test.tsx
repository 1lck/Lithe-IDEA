import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { GitPullPreflight, GitPullResult, GitReference } from "../types/git.types";
import type { GitPullWorkflowOptions } from "../hooks/git-pull-workflow";

let restoreDom: () => void;
let originalCustomEvent: typeof globalThis.CustomEvent;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let originalActEnvironment: boolean | undefined;
const spies: Array<{ mockRestore: () => void }> = [];

const preflight: GitPullPreflight = {
  upstream: "origin/main",
  ahead: 1,
  behind: 2,
  diverged: true,
  hasLocalChanges: false,
};

const reference = (shortName: string): GitReference => ({
  fullName: `refs/remotes/${shortName}`,
  shortName,
  kind: "remote",
  peelsToCommit: true,
  isCurrent: false,
});

const remotesApi = await import("../api/git-remotes-api");
const commitsApi = await import("../api/git-commits-api");

const run = mock(
  async (_repoPath: string, _options: GitPullWorkflowOptions): Promise<GitPullResult> => ({
    status: "pulled",
    strategy: "merge",
  }),
);

let container: HTMLDivElement;
let root: Root;

const findButton = (label: string): HTMLButtonElement => {
  const button = [...document.querySelectorAll("button")].find(
    (candidate) => candidate.textContent?.trim() === label,
  );
  if (!button) throw new Error(`Button "${label}" not found`);
  return button;
};

beforeEach(() => {
  restoreDom = installHappyDom();
  originalCustomEvent = globalThis.CustomEvent;
  originalActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  Object.defineProperty(globalThis, "CustomEvent", {
    configurable: true,
    writable: true,
    value: window.CustomEvent,
  });
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  run.mockClear();
  spies.push(
    spyOn(remotesApi, "getPullPreflight").mockResolvedValue(preflight),
    spyOn(commitsApi, "getGitReferencesAtRoot").mockResolvedValue({
      references: [reference("origin/main"), reference("origin/release")],
      recentReferences: [],
    }),
    spyOn(remotesApi, "getGitPullWorkflow").mockImplementation(
      () => ({ run } as unknown as ReturnType<typeof remotesApi.getGitPullWorkflow>),
    ),
  );
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  for (const spy of spies.splice(0)) spy.mockRestore();
  await act(async () => {
    root.unmount();
    // Flush React's scheduler before the happy-dom globals are torn down.
    await Promise.resolve();
  });
  if (originalActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = originalActEnvironment;
  container.remove();
  if (originalCustomEvent) {
    Object.defineProperty(globalThis, "CustomEvent", {
      configurable: true,
      writable: true,
      value: originalCustomEvent,
    });
  } else {
    Reflect.deleteProperty(globalThis, "CustomEvent");
  }
  restoreDom();
});

const renderHost = async (): Promise<void> => {
  const { GitPullDialogHost } = await import("./git-pull-dialog");
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <GitPullDialogHost />
      </LocaleProvider> as ReactNode,
    );
  });
};

const openDialog = async (repoPath: string) => {
  const { showGitPullDialog } = await import("../services/git-pull-dialog-service");
  let promise: Promise<unknown> | null = null;
  await act(async () => {
    promise = showGitPullDialog(repoPath);
    // Let the dialog load preflight and references before assertions.
    await Promise.resolve();
    await Promise.resolve();
  });
  return () => promise as Promise<{ status: string }>;
};

describe("Pull dialog", () => {
  test("preselects the upstream and shows the collapsed merge default", async () => {
    await renderHost();
    await openDialog("C:/repo");

    expect(document.body.textContent).toContain("Pull from");
    expect(document.body.textContent).toContain("origin/main");
    expect(document.body.textContent).toContain("Strategy: Merge");
    // The advanced choices stay collapsed until the user expands the section.
    expect(document.body.textContent).not.toContain("Fast-forward only");
    expect(document.body.textContent).not.toContain("Rebase");
    expect(document.body.textContent).toContain("Local ahead");
    expect(document.body.textContent).toContain("Remote ahead");
  });

  test("reveals the strategy choices only after expanding the section", async () => {
    await renderHost();
    await openDialog("C:/repo");

    await act(async () => {
      findButton("Strategy: Merge").click();
    });

    expect(document.body.textContent).toContain("Fast-forward only");
    expect(document.body.textContent).toContain("Rebase");
  });

  test("pulls the configured upstream through the shared workflow with the chosen strategy", async () => {
    await renderHost();
    const result = await openDialog("C:/repo");

    await act(async () => {
      findButton("Pull").click();
      await Promise.resolve();
    });

    expect(run).toHaveBeenCalledWith("C:/repo", {
      refresh: expect.any(Function),
      strategy: "merge",
    });
    await expect(result()).resolves.toEqual({ status: "pulled" });
  });

  test("resolves as cancelled when the user dismisses the dialog", async () => {
    await renderHost();
    const result = await openDialog("C:/repo");

    await act(async () => {
      findButton("Cancel").click();
    });

    await expect(result()).resolves.toEqual({ status: "cancelled" });
    expect(run).not.toHaveBeenCalled();
  });
});
