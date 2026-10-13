import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { GitCommit } from "../../types/git.types";

const commitsApi = await import("../../api/git-commits-api");
const { GitCommitDetails } = await import("./git-commit-details");

const commit = (hash: string, message: string): GitCommit => ({
  hash,
  shortHash: hash.slice(0, 7),
  parentHashes: [],
  message,
  author: "Developer",
  email: "developer@example.invalid",
  date: "2026/08/16 10:00",
  decorations: "",
});

const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let originalActEnvironment: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const spies: Array<{ mockRestore: () => void }> = [];
const descriptionResolvers = new Map<string, (description: string | null) => void>();

beforeEach(() => {
  restoreDom = installHappyDom();
  originalActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  descriptionResolvers.clear();
  spies.push(
    // Each lookup stays pending until the test releases it, so the order in
    // which answers arrive is explicit.
    spyOn(commitsApi, "getCommitDescription").mockImplementation(
      (_repoPath: string, hash: string) =>
        new Promise<string | null>((resolve) => descriptionResolvers.set(hash, resolve)),
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
    for (const resolve of descriptionResolvers.values()) resolve(null);
    descriptionResolvers.clear();
    await Promise.resolve();
  });
  container.remove();
  if (originalActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = originalActEnvironment;
  restoreDom();
});

const renderDetails = async (selected: GitCommit) => {
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <GitCommitDetails repoPath="C:/repo" commit={selected} />
      </LocaleProvider>,
    );
  });
};

const resolveDescription = async (hash: string, description: string | null) => {
  const resolve = descriptionResolvers.get(hash);
  if (!resolve) throw new Error(`No pending description lookup for ${hash}`);
  await act(async () => {
    resolve(description);
    await Promise.resolve();
  });
};

describe("Git commit details message", () => {
  // Regression for #771: the details pane showed only the subject line.
  test("shows the full multi-line message body for the selected commit", async () => {
    await renderDetails(commit("aaaaaaa1", "Fix commit details"));
    expect(container.textContent).toContain("Fix commit details");

    await resolveDescription("aaaaaaa1", "First body line\n\nSecond paragraph");

    const body = [...container.querySelectorAll("div")].find(
      (element) => element.textContent === "First body line\n\nSecond paragraph",
    );
    expect(body).toBeDefined();
    expect(body?.className).toContain("whitespace-pre-wrap");
  });

  test("ignores a late body for a commit that is no longer selected", async () => {
    await renderDetails(commit("aaaaaaa1", "First subject"));
    await renderDetails(commit("bbbbbbb2", "Second subject"));

    await resolveDescription("aaaaaaa1", "Stale body from the first commit");
    expect(container.textContent).not.toContain("Stale body from the first commit");

    await resolveDescription("bbbbbbb2", "Body of the second commit");
    expect(container.textContent).toContain("Second subject");
    expect(container.textContent).toContain("Body of the second commit");
  });

  test("keeps the subject when the body cannot be read", async () => {
    await renderDetails(commit("ccccccc3", "Subject survives"));
    await resolveDescription("ccccccc3", null);

    expect(container.textContent).toContain("Subject survives");
    expect(container.textContent).toContain("ccccccc3");
  });
});
