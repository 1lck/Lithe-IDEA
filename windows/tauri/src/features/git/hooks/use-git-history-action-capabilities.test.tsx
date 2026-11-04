import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as historyApi from "../api/git-history-rewrite-api";
import * as commitsApi from "../api/git-commits-api";
import { useGitHistoryActionCapabilities, type GitHistoryActionRequest } from "./use-git-history-action-capabilities";

let restoreDom: () => void;
let host: HTMLDivElement;
let reactRoot: Root;
let oldAct: boolean | undefined;
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const spies: Array<{mockRestore(): void}> = [];
const pending: Array<{resolve: (value: historyApi.GitHistoryActionCapabilities) => void; operationId: string}> = [];
const cancelled: string[] = [];
const result = (head: string): historyApi.GitHistoryActionCapabilities => ({head, canCherryPick: true, canUndo: false, canSquash: false});

beforeEach(() => {
  restoreDom = installHappyDom(); oldAct = globals.IS_REACT_ACT_ENVIRONMENT; globals.IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div"); document.body.append(host); reactRoot = createRoot(host);
  spies.push(spyOn(historyApi, "getGitHistoryActionCapabilities").mockImplementation((_root, _revisions, operationId) =>
    new Promise((resolve) => pending.push({resolve, operationId}))));
  spies.push(spyOn(commitsApi, "cancelGitHistoryOperation").mockImplementation(async (id) => { cancelled.push(id); }));
});
afterEach(async () => {
  try { await act(async () => { for (const item of pending.splice(0)) item.resolve(result("cleanup")); reactRoot.unmount(); }); }
  finally { spies.splice(0).forEach((spy) => spy.mockRestore()); cancelled.length = 0; host.remove();
    if (oldAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT; else globals.IS_REACT_ACT_ENVIRONMENT = oldAct;
    restoreDom(); }
});
function Harness({root, request}: {root: string; request: GitHistoryActionRequest | null}) {
  const value = useGitHistoryActionCapabilities(root, request);
  return <span>{value?.head ?? "pending"}</span>;
}
test("a late result from a replaced selection cannot update the new menu", async () => {
  const a = {owner: "a", root: "C:/one", session: "a", revisions: ["a"]};
  const b = {owner: "b", root: "C:/two", session: "b", revisions: ["b"]};
  await act(async () => reactRoot.render(<Harness root="C:/one" request={a} />));
  await act(async () => reactRoot.render(<Harness root="C:/two" request={b} />));
  expect(cancelled).toContain(pending[0]!.operationId);
  await act(async () => pending[0]!.resolve(result("old")));
  expect(host.textContent).toBe("pending");
  await act(async () => pending[1]!.resolve(result("new")));
  expect(host.textContent).toBe("new");
});
test("reopening the same selection never reuses an earlier menu result", async () => {
  const a = {owner: "a", root: "C:/one", session: "first", revisions: ["a"]};
  await act(async () => reactRoot.render(<Harness root="C:/one" request={a} />));
  await act(async () => pending[0]!.resolve(result("old")));
  expect(host.textContent).toBe("old");
  await act(async () => reactRoot.render(<Harness root="C:/one" request={{...a, session: "second"}} />));
  expect(host.textContent).toBe("pending");
  await act(async () => pending[1]!.resolve(result("new")));
  expect(host.textContent).toBe("new");
});
test("a relevant HEAD change invalidates the open menu and cancels its old read", async () => {
  const request = {owner: "a", root: "C:/one", session: "menu", revisions: ["a"]};
  await act(async () => reactRoot.render(<Harness root="C:/one" request={request} />));
  await act(async () => window.dispatchEvent(new window.CustomEvent("lithe:git-changed", {detail: {repoPath: "C:/one", scopes: ["refs"]}})));
  expect(cancelled).toContain(pending[0]!.operationId);
  expect(pending).toHaveLength(2);
  await act(async () => pending[0]!.resolve(result("old")));
  expect(host.textContent).toBe("pending");
  await act(async () => pending[1]!.resolve(result("new")));
  expect(host.textContent).toBe("new");
});


test("an open menu from another repository never queries the new repository", async () => {
  const request = {owner: "a", root: "C:/one", session: "old", revisions: ["a"]};
  await act(async () => reactRoot.render(<Harness root="C:/one" request={request} />));
  await act(async () => reactRoot.render(<Harness root="C:/two" request={request} />));
  expect(host.textContent).toBe("pending");
  expect(pending).toHaveLength(1);
  expect(cancelled).toContain(pending[0]!.operationId);
});
test("no history process is started while the menu is closed", async () => {
  await act(async () => reactRoot.render(<Harness root="C:/one" request={null} />));
  expect(pending).toHaveLength(0);
  expect(host.textContent).toBe("pending");
});
