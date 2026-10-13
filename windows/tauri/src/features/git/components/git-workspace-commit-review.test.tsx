import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import fixture from "../../../../../../shared/fixtures/git/workspace-commit-workflow-v1.json";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove(); restoreDom();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});
test("review renders Core child-first order, file paths, parent references and changed-plan notice", async () => {
  const { GitWorkspaceCommitReview } = await import("./git-workspace-commit-review");
  let confirmed = false;
  await act(async () => root.render(<LocaleProvider language="en-US">
    <GitWorkspaceCommitReview preparation={{ ...fixture.preparation, reviewChanged: true }} busy={false} error={null}
      onConfirm={() => { confirmed = true; }} onClose={() => {}} onIncludeParents={() => {}} />
  </LocaleProvider>));
  const text = document.body.textContent ?? "";
  expect(text.indexOf("1. A/B")).toBeLessThan(text.indexOf("2. A"));
  expect(text).toContain("hello.ts");
  expect(text).toContain("Update reference: B → A/B");
  expect(text).toContain("The plan changed.");
  expect(text).toContain("refs/heads/main");
  const button = [...document.querySelectorAll("button")].find((button) => button.textContent === "Commit and Push");
  expect(button).toBeDefined();
  await act(async () => button!.click());
  expect(confirmed).toBe(true);
});
