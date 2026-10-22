import { afterAll, afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "../src/test-utils/happy-dom";
import { createConversation, upsertToolMessage } from "../src/features/agent/types/agent.types";

const restoreDom = installHappyDom();
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
let bufferPath = "";
let resolvedPath = "";
let diskReads = 0;
let acknowledgements = 0;
const commands: string[] = [];
let bufferState: Record<string, unknown> = { type: "editor", path: "", isDirty: true };
let diskContent = "after";
mock.module("@/features/editor/stores/buffer.store", () => ({ useBufferStore: { getState: () => ({
  buffers: [{ ...bufferState, path: bufferPath }],
}) } }));
mock.module("@/features/agent/stores/agent-connection-service", () => ({
  agentWorkspacePath: () => "C:/workspace",
  agentConnection: () => ({ acknowledgeEdits: () => { acknowledgements++; } }),
}));
mock.module("@/platform/tauri-core", () => ({
  HostCommandError: class extends Error {},
  invoke: async (command: string) => { commands.push(command); return resolvedPath; },
}));
mock.module("@/platform/document-files", () => ({ readDocumentFileDetails: async () => {
  diskReads++;
  return { content: diskContent, encoding: "UTF-8", identity: "fixture-identity" };
} }));
mock.module("@/i18n/locale-provider", () => ({ useTranslation: () => ({ t: (key: string) => key }) }));
mock.module("@/ui/button", () => ({ Button: ({ children, size: _size, variant: _variant, ...props }: any) => <button {...props}>{children}</button> }));
const { createRoot } = await import("react-dom/client");
const { AgentEditReview } = await import("../src/features/agent/components/agent-edit-review");
let root: Root;
let container: HTMLDivElement;
beforeEach(() => {
  commands.length = 0;
  diskReads = 0;
  acknowledgements = 0;
  bufferState = { type: "editor", path: "", isDirty: true };
  diskContent = "after";
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
afterAll(() => { restoreDom(); if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT; else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct; });

for (const [name, ordinary, verbatim] of [
  ["drive", "C:/workspace/sample.txt", "\\\\?\\C:\\WORKSPACE\\sample.txt"],
  ["UNC", "//server/share/workspace/sample.txt", "\\\\?\\UNC\\SERVER\\SHARE\\workspace\\sample.txt"],
]) test(`Revert refuses a dirty ${name} buffer when the native resolver returns a verbatim path`, async () => {
  bufferPath = ordinary;
  resolvedPath = verbatim;
  const conversation = upsertToolMessage(createConversation(), "edit", {
    kind: "edit", status: "completed", content: [{ type: "diff", path: ordinary, oldText: "before", newText: "after" }],
  });
  await act(async () => root.render(<AgentEditReview conversation={conversation} sessionID="fixture" onOpenLocation={() => {}} />));
  const revert = [...container.querySelectorAll("button")].find((button) => button.textContent === "agent.edits.revert")!;
  await act(async () => { revert.click(); });
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("agent.edits.dirty");
  expect(commands).toEqual(["resolve_agent_document_path"]);
  expect(diskReads).toBe(0);
  expect(acknowledgements).toBe(0);
});

test("allows the watcher conflict raised by native recovery removal", async () => {
  bufferPath = "C:/workspace/created.txt";
  resolvedPath = "C:/workspace/created.txt";
  bufferState = {
    type: "editor",
    isDirty: true,
    content: "created\n",
    savedContent: "created\n",
    documentLifecycle: { status: "conflict", revision: 1, savedRevision: 0 },
  };
  diskContent = "created\n";
  const conversation = upsertToolMessage(createConversation(), "create", {
    kind: "edit", status: "completed", content: [{ type: "diff", path: bufferPath, oldText: null, newText: "created\n", _meta: { kind: "add" } }],
  });
  await act(async () => root.render(<AgentEditReview conversation={conversation} sessionID="fixture" onOpenLocation={() => {}} />));
  const revert = [...container.querySelectorAll("button")].find((button) => button.textContent === "agent.edits.revert")!;
  await act(async () => { revert.click(); });
  expect(commands).toEqual(["resolve_agent_document_path", "resolve_agent_document_path", "trash_agent_document"]);
  expect(acknowledgements).toBe(1);
  expect(container.querySelector('[role="alert"]')).toBeNull();
});

test("still refuses a user edit made while the conflict is visible", async () => {
  bufferPath = "C:/workspace/sample.txt";
  resolvedPath = "C:/workspace/sample.txt";
  bufferState = {
    type: "editor",
    isDirty: true,
    content: "user edit",
    savedContent: "after",
    documentLifecycle: { status: "conflict", revision: 2, savedRevision: 1 },
  };
  const conversation = upsertToolMessage(createConversation(), "edit", {
    kind: "edit", status: "completed", content: [{ type: "diff", path: bufferPath, oldText: "before", newText: "after" }],
  });
  await act(async () => root.render(<AgentEditReview conversation={conversation} sessionID="fixture" onOpenLocation={() => {}} />));
  const revert = [...container.querySelectorAll("button")].find((button) => button.textContent === "agent.edits.revert")!;
  await act(async () => { revert.click(); });
  expect(container.querySelector('[role="alert"]')?.textContent).toBe("agent.edits.dirty");
  expect(commands).toEqual(["resolve_agent_document_path"]);
  expect(diskReads).toBe(0);
  expect(acknowledgements).toBe(0);
});
